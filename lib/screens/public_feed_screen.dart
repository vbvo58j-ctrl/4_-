import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../services/local_network_service.dart';
import '../services/wifi_aware_service.dart';
import '../services/bluetooth_classic_service.dart';
import 'chat_screen.dart';

/// Nearby public feed. Media is compressed and chunked; delivery uses direct
/// Wi-Fi Aware data paths when supported, with LAN as a compatible fallback.
class PublicFeedScreen extends StatefulWidget {
  final String userName;
  final String profilePhotoPath;
  const PublicFeedScreen({super.key, required this.userName, required this.profilePhotoPath});

  @override
  State<PublicFeedScreen> createState() => _PublicFeedScreenState();
}

class _PublicFeedScreenState extends State<PublicFeedScreen> {
  static const _key = 'blousab_public_feed_v1';
  static const _friendsKey = 'blousab_accepted_friends_v1';
  static const _requestsKey = 'blousab_friend_requests_v1';
  final _picker = ImagePicker();
  final _scroll = ScrollController();
  List<Map<String, dynamic>> _posts = [];
  StreamSubscription? _subscription;
  StreamSubscription? _awareSubscription;
  Timer? _feedSyncTimer;
  bool _busy = false;
  bool _loading = true;
  bool _loaded = false;
  final List<dynamic> _pendingFeedEvents = <dynamic>[];
  String? _loadError;
  bool _randomOrder = false;
  int _shuffleSeed = DateTime.now().millisecondsSinceEpoch;
  String _myId = 'blousab-user';
  Set<String> _friends = <String>{};
  List<Map<String, dynamic>> _friendRequests = <Map<String, dynamic>>[];
  final Map<String, _IncomingFeedMedia> _incomingMedia = <String, _IncomingFeedMedia>{};
  static const int _mediaChunkBytes = 256 * 1024;
  static const int _maxPostMediaBytes = 32 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    _load().then((_) async {
      _loaded = true;
      final pending = List<dynamic>.from(_pendingFeedEvents);
      _pendingFeedEvents.clear();
      for (final event in pending) { await _onLanEvent(event); }
      await _requestFeedSync();
    }).catchError((_) { if (mounted) setState(() { _loading = false; _loadError = 'تعذر تحميل الخلاصة المحفوظة.'; }); });
    _subscription = LocalNetworkService.instance.events.listen(_onLanEvent);
    _awareSubscription = WifiAwareService.instance.events.listen((event) {
      if (event.type == 'dataConnected') {
        _requestFeedSync();
      } else if (event.type == 'dataPacket' && event.payload != null) {
        _onLanEvent(BlousabEvent(type: 'message', message: event.payload));
      }
    });
    // Periodic lightweight reconciliation catches missed broadcasts and
    // retries media that was incomplete during a temporary disconnect.
    _feedSyncTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (LocalNetworkService.instance.isRunning || WifiAwareService.instance.connectedPeerIds.isNotEmpty) _requestFeedSync();
    });
  }

  @override
  void dispose() { _feedSyncTimer?.cancel(); _subscription?.cancel(); _awareSubscription?.cancel(); _incomingMedia.clear(); _pendingFeedEvents.clear(); _scroll.dispose(); super.dispose(); }

  Future<Directory> _feedDir() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/blousab_public_feed');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _myId = prefs.getString('wasl_user_id') ?? '';
    if (_myId.trim().isEmpty || _myId == 'blousab-user') {
      _myId = 'blousab-${DateTime.now().microsecondsSinceEpoch}-${DateTime.now().millisecondsSinceEpoch.remainder(100000)}';
      await prefs.setString('wasl_user_id', _myId);
    }
    _friends = (prefs.getStringList(_friendsKey) ?? <String>[]).toSet();
    _friendRequests = (prefs.getStringList(_requestsKey) ?? <String>[])
        .map((item) { try { return Map<String, dynamic>.from(jsonDecode(item) as Map); } catch (_) { return <String, dynamic>{}; } })
        .where((item) => item.isNotEmpty).toList();
    final raw = prefs.getStringList(_key) ?? <String>[];
    final byId = <String, Map<String, dynamic>>{};
    for (final item in raw) {
      try {
        final post = Map<String, dynamic>.from(jsonDecode(item) as Map);
        final id = post['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        // One canonical entry per post ID; retain the newest copy if storage
        // contains a replayed duplicate.
        final existing = byId[id];
        final incomingUpdated = (post['updatedAt'] as num?)?.toInt() ?? (post['createdAt'] as num?)?.toInt() ?? 0;
        final existingUpdated = (existing?['updatedAt'] as num?)?.toInt() ?? (existing?['createdAt'] as num?)?.toInt() ?? 0;
        if (existing == null || incomingUpdated >= existingUpdated) byId[id] = post;
      } catch (_) {}
    }
    final posts = byId.values.toList();
    _sortPosts(posts);
    if (mounted) setState(() { _posts = posts; _loading = false; _loadError = null; });
  }

  void _sortPosts(List<Map<String, dynamic>> posts) {
    if (_randomOrder) {
      // Stable shuffle for the current view; tapping shuffle changes the seed.
      posts.sort((a, b) => _shuffleKey(a['id']?.toString() ?? '').compareTo(_shuffleKey(b['id']?.toString() ?? '')));
    } else {
      posts.sort((a, b) => ((b['createdAt'] as num?)?.toInt() ?? 0).compareTo((a['createdAt'] as num?)?.toInt() ?? 0));
    }
  }

  int _shuffleKey(String id) {
    var hash = _shuffleSeed;
    for (final unit in id.codeUnits) { hash = ((hash * 31) ^ unit) & 0x7fffffff; }
    return hash;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    // Persist canonical unique posts in chronological order, independent of
    // the currently selected display ordering.
    final unique = <String, Map<String, dynamic>>{};
    for (final post in _posts) {
      final id = post['id']?.toString() ?? '';
      if (id.isNotEmpty) unique[id] = post;
    }
    final stored = unique.values.toList()..sort((a, b) => ((b['createdAt'] as num?)?.toInt() ?? 0).compareTo((a['createdAt'] as num?)?.toInt() ?? 0));
    await prefs.setStringList(_key, stored.map(jsonEncode).toList());
  }

  Future<void> _refreshFeed() async {
    if (mounted) setState(() { _loading = true; _loadError = null; });
    try {
      await _load();
      await _requestFeedSync();
    } catch (_) {
      if (mounted) setState(() { _loading = false; _loadError = 'تعذر تحديث الخلاصة. حاول مرة أخرى.'; });
    }
  }

  void _toggleOrder() {
    setState(() {
      _randomOrder = !_randomOrder;
      _shuffleSeed = DateTime.now().microsecondsSinceEpoch;
      _sortPosts(_posts);
    });
  }

  bool get _hasFeedTransport => LocalNetworkService.instance.isRunning || WifiAwareService.instance.connectedPeerIds.isNotEmpty;

  Future<void> _broadcastFeedPacket(String payload) async {
    var sent = false;
    Object? lastError;
    final lanPeerIds = LocalNetworkService.instance.discoveredPeers
        .map((peer) => peer['id'] ?? '').where((id) => id.isNotEmpty).toSet();
    if (LocalNetworkService.instance.isRunning) {
      try { await LocalNetworkService.instance.broadcastMessage(payload); sent = true; }
      catch (error) { lastError = error; }
    }
    try { await WifiAwareService.instance.broadcastPacket(payload, excludePeerIds: lanPeerIds); sent = true; }
    catch (error) { lastError = error; }
    if (!sent) throw StateError('لا يوجد مسار مباشر متاح لإرسال المنشور: $lastError');
  }

  Future<void> _broadcastFeedFrames(Iterable<String> frames) async {
    var sent = false;
    Object? lastError;
    final lanPeerIds = LocalNetworkService.instance.discoveredPeers
        .map((peer) => peer['id'] ?? '').where((id) => id.isNotEmpty).toSet();
    if (LocalNetworkService.instance.isRunning) {
      try { await LocalNetworkService.instance.broadcastMessages(frames); sent = true; }
      catch (error) { lastError = error; }
    }
    try { await WifiAwareService.instance.broadcastPackets(frames, excludePeerIds: lanPeerIds); sent = true; }
    catch (error) { lastError = error; }
    if (!sent) throw StateError('تعذر نقل وسائط المنشور عبر أي اتصال مباشر: $lastError');
  }

  Future<void> _requestFeedSync() async {
    try {
      if (!_hasFeedTransport) return;
      final knownPosts = _posts.take(1000).map((post) {
        final path = post['mediaPath']?.toString() ?? '';
        final hasMedia = path.isNotEmpty && File(path).existsSync();
        return <String, dynamic>{
          'id': post['id']?.toString() ?? '',
          'updatedAt': (post['updatedAt'] as num?)?.toInt() ?? 0,
          'hasMedia': hasMedia,
        };
      }).where((item) => (item['id'] as String).isNotEmpty).toList();
      await _broadcastFeedPacket(jsonEncode({
        'type': 'public_feed_sync_request', 'requesterId': _myId,
        'knownPosts': knownPosts,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      }));
    } catch (_) {}
  }

  Future<void> _broadcastPost(Map<String, dynamic> post, {int hops = 0}) async {
    if (!_hasFeedTransport) return;
    final outgoing = Map<String, dynamic>.from(post);
    outgoing.remove('mediaPath');
    outgoing.remove('profilePhotoPath');
    final profilePath = post['profilePhotoPath']?.toString().isNotEmpty == true
        ? post['profilePhotoPath'].toString() : widget.profilePhotoPath;
    if (profilePath.isNotEmpty) {
      try {
        final file = File(profilePath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty && bytes.length <= 80 * 1024) {
            outgoing['profilePhotoBase64'] = base64Encode(bytes);
          }
        }
      } catch (_) {}
    }

    final mediaPath = post['mediaPath']?.toString() ?? '';
    if (mediaPath.isEmpty || post['mediaType'] == 'text') {
      await _broadcastFeedPacket(jsonEncode({
        'type': 'public_feed_post', 'post': outgoing, 'hops': hops,
      }));
      return;
    }

    final mediaFile = File(mediaPath);
    if (!await mediaFile.exists()) throw StateError('ملف وسائط المنشور غير موجود');
    final source = await mediaFile.readAsBytes();
    if (source.isEmpty || source.length > _maxPostMediaBytes) {
      throw StateError('حجم الوسائط يتجاوز الحد المسموح لمزامنة المنشورات (32 ميجابايت)');
    }

    // A compressed binary asset is transferred as ordered, independently
    // bounded chunks. JPEG/MP4 are already compressed, but gzip still gives
    // one consistent, verifiable transport container for every media type.
    final compressed = gzip.encode(source);
    final transferId = '${post['id']}_${DateTime.now().microsecondsSinceEpoch}';
    final chunkCount = (compressed.length / _mediaChunkBytes).ceil();
    await _broadcastFeedFrames(_feedMediaFrames(
      transferId: transferId, post: outgoing, hops: hops,
      originalBytes: source.length, compressed: compressed, chunkCount: chunkCount,
    ));
  }

  Iterable<String> _feedMediaFrames({required String transferId,
      required Map<String, dynamic> post, required int hops,
      required int originalBytes, required List<int> compressed,
      required int chunkCount}) sync* {
    yield jsonEncode({
      'type': 'public_feed_media_start', 'transferId': transferId,
      'post': post, 'hops': hops,
      'originalBytes': originalBytes, 'compressedBytes': compressed.length,
      'chunkCount': chunkCount,
    });
    for (var index = 0; index < chunkCount; index++) {
      final from = index * _mediaChunkBytes;
      final to = (from + _mediaChunkBytes).clamp(0, compressed.length).toInt();
      yield jsonEncode({
        'type': 'public_feed_media_chunk', 'transferId': transferId,
        'index': index, 'data': base64Encode(compressed.sublist(from, to)),
      });
    }
    yield jsonEncode({'type': 'public_feed_media_end', 'transferId': transferId});
  }

  Future<void> _broadcastPostUpdate(Map<String, dynamic> post, {int hops = 0}) async {
    try {
      if (!_hasFeedTransport) return;
      await _broadcastFeedPacket(jsonEncode({
        'type': 'public_feed_update', 'postId': post['id'],
        'likes': post['likes'] ?? <String>[],
        'comments': post['comments'] ?? <Map<String, dynamic>>[],
        'updatedAt': (post['updatedAt'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
        'hops': hops,
      }));
    } catch (_) {}
  }

  Future<void> _persistFriends() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_friendsKey, _friends.toList());
  }

  Future<void> _persistFriendRequests() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_requestsKey, _friendRequests.map(jsonEncode).toList());
  }

  Future<void> _acceptFriendRequest(Map<String, dynamic> request) async {
    final peerId = request['senderId']?.toString() ?? '';
    if (peerId.isEmpty || peerId == _myId) return;
    _friends.add(peerId);
    _friendRequests.removeWhere((r) => r['requestId'] == request['requestId']);
    await _persistFriends(); await _persistFriendRequests();
    try { if (LocalNetworkService.instance.isRunning) {
      await LocalNetworkService.instance.broadcastMessage(jsonEncode({'type':'friend_request_response','requestId':request['requestId'],'recipientId':peerId,'senderId':_myId,'senderName':widget.userName,'accepted':true}));
    }} catch (_) {}
    if (mounted) setState(() {});
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم قبول الطلب وحفظ الصداقة على هذا الجهاز.')));
  }

  Future<void> _rejectFriendRequest(Map<String, dynamic> request) async {
    final peerId = request['senderId']?.toString() ?? '';
    _friendRequests.removeWhere((r) => r['requestId'] == request['requestId']);
    await _persistFriendRequests();
    try { if (LocalNetworkService.instance.isRunning && peerId.isNotEmpty) {
      await LocalNetworkService.instance.broadcastMessage(jsonEncode({'type':'friend_request_response','requestId':request['requestId'],'recipientId':peerId,'senderId':_myId,'senderName':widget.userName,'accepted':false}));
    }} catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _showNotifications() async {
    await showModalBottomSheet<void>(context: context, showDragHandle: true, isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final requests = List<Map<String, dynamic>>.from(_friendRequests);
        return SafeArea(child: SizedBox(height: MediaQuery.of(ctx).size.height * .65, child: Column(children: [
          const Padding(padding: EdgeInsets.all(16), child: Text('الإشعارات وطلبات الصداقة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          Expanded(child: requests.isEmpty ? const Center(child: Text('لا توجد طلبات صداقة جديدة')) : ListView(children: requests.map((r) => ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person_add_alt_1)), title: Text('طلب صداقة من ${r['senderName'] ?? 'مستخدم'}'), subtitle: Text(_time(r['createdAt'])),
            trailing: Wrap(spacing: 0, children: [IconButton(tooltip:'قبول', onPressed: () async { await _acceptFriendRequest(r); setSheet(() {}); }, icon: const Icon(Icons.check_circle_outline, color: Colors.green)), IconButton(tooltip:'رفض', onPressed: () async { await _rejectFriendRequest(r); setSheet(() {}); }, icon: const Icon(Icons.close))]),
          )).toList())),
        ])));
      }));
  }

  Future<void> _onLanEvent(dynamic event) async {
    if (!_loaded) {
      // Keep startup packets until local storage has been loaded, otherwise
      // an early peer post could be overwritten by the initial disk read.
      if (_pendingFeedEvents.length < 512) _pendingFeedEvents.add(event);
      return;
    }
    if (event.type == 'lanStarted' || event.type == 'peerDiscovered') {
      // A newly reachable peer automatically triggers reconciliation. No
      // manual refresh or device selection is required for the public feed.
      await _requestFeedSync();
      return;
    }
    if (event.type != 'message' || event.message == null) return;
    try {
      final packet = jsonDecode(event.message!);
      if (packet is! Map) return;
      final packetType = packet['type']?.toString();

      if (packetType == 'public_feed_media_start') {
        final id = packet['transferId']?.toString() ?? '';
        final postRaw = packet['post'];
        final chunks = (packet['chunkCount'] as num?)?.toInt() ?? 0;
        final compressedBytes = (packet['compressedBytes'] as num?)?.toInt() ?? -1;
        final originalBytes = (packet['originalBytes'] as num?)?.toInt() ?? -1;
        if (id.isEmpty || postRaw is! Map || chunks < 1 || chunks > 160 ||
            compressedBytes < 1 || compressedBytes > _maxPostMediaBytes + 256 * 1024 ||
            originalBytes < 1 || originalBytes > _maxPostMediaBytes) return;
        _incomingMedia.removeWhere((_, value) => DateTime.now().difference(value.createdAt) > const Duration(minutes: 3));
        int pendingBytes() => _incomingMedia.values.fold<int>(0, (sum, item) => sum + item.compressedBytes);
        while (!_incomingMedia.containsKey(id) && _incomingMedia.isNotEmpty &&
            (_incomingMedia.length >= 2 || pendingBytes() + compressedBytes > 40 * 1024 * 1024)) {
          final oldest = _incomingMedia.entries.reduce((a, b) =>
              a.value.createdAt.isBefore(b.value.createdAt) ? a : b).key;
          _incomingMedia.remove(oldest);
        }
        _incomingMedia[id] = _IncomingFeedMedia(
          post: Map<String, dynamic>.from(postRaw), chunkCount: chunks,
          compressedBytes: compressedBytes, originalBytes: originalBytes,
          hops: (packet['hops'] as num?)?.toInt() ?? 0,
        );
        return;
      }
      if (packetType == 'public_feed_media_chunk') {
        final id = packet['transferId']?.toString() ?? '';
        final transfer = _incomingMedia[id];
        final index = (packet['index'] as num?)?.toInt() ?? -1;
        final encoded = packet['data']?.toString() ?? '';
        if (transfer == null || index < 0 || index >= transfer.chunkCount || encoded.isEmpty || encoded.length > 400 * 1024) return;
        if (!transfer.chunks.containsKey(index)) {
          final bytes = base64Decode(encoded);
          transfer.receivedBytes += bytes.length;
          if (transfer.receivedBytes > transfer.compressedBytes) {
            _incomingMedia.remove(id);
            return;
          }
          transfer.chunks[index] = bytes;
        }
        return;
      }
      if (packetType == 'public_feed_media_end') {
        final id = packet['transferId']?.toString() ?? '';
        final transfer = _incomingMedia.remove(id);
        if (transfer != null) await _completeIncomingMedia(transfer);
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      _myId = prefs.getString('wasl_user_id') ?? 'blousab-user';
      if (packetType == 'friend_request' && packet['recipientId']?.toString() == _myId) {
        final senderId = packet['senderId']?.toString() ?? '';
        if (senderId.isEmpty || senderId == _myId || _friends.contains(senderId)) return;
        final requestId = packet['requestId']?.toString() ?? '${senderId}_${packet['createdAt']}';
        if (!_friendRequests.any((r) => r['senderId']?.toString() == senderId)) {
          _friendRequests.add({'requestId':requestId,'senderId':senderId,'senderName':packet['senderName']?.toString() ?? 'مستخدم','createdAt':packet['createdAt'] ?? DateTime.now().millisecondsSinceEpoch});
          await _persistFriendRequests(); if (mounted) setState(() {});
        }
        return;
      }
      if (packetType == 'friend_request_response' && packet['recipientId']?.toString() == _myId) {
        final peerId = packet['senderId']?.toString() ?? '';
        if (peerId.isNotEmpty && peerId != _myId && packet['accepted'] == true) {
          _friends.add(peerId); await _persistFriends();
          if (mounted) { setState(() {}); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('وافق ${packet['senderName'] ?? 'المستخدم'} على طلب الصداقة. تم حفظ الصداقة.'))); }
        } else if (mounted && peerId.isNotEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم رفض طلب الصداقة.'))); }
        return;
      }
      if (packetType == 'public_feed_sync_request') {
        final known = <String, Map<String, dynamic>>{};
        for (final item in (packet['knownPosts'] as List? ?? const [])) {
          if (item is! Map) continue;
          final id = item['id']?.toString() ?? '';
          if (id.isNotEmpty) known[id] = Map<String, dynamic>.from(item);
        }
        for (final savedPost in List<Map<String, dynamic>>.from(_posts)) {
          final id = savedPost['id']?.toString() ?? '';
          final remote = known[id];
          final localUpdated = (savedPost['updatedAt'] as num?)?.toInt() ?? 0;
          final remoteUpdated = (remote?['updatedAt'] as num?)?.toInt() ?? -1;
          final mediaPath = savedPost['mediaPath']?.toString() ?? '';
          final senderHasMedia = savedPost['mediaType'] != 'text' &&
              mediaPath.isNotEmpty && File(mediaPath).existsSync();
          final receiverHasMedia = remote?['hasMedia'] == true;
          final mediaAlreadyThere = !senderHasMedia || receiverHasMedia;
          if (remote != null && remoteUpdated >= localUpdated && mediaAlreadyThere) continue;
          try { await _broadcastPost(savedPost); } catch (_) {}
        }
        return;
      }
      if (packetType == 'public_feed_update') {
        final postId = packet['postId']?.toString() ?? '';
        final index = _posts.indexWhere((p) => p['id']?.toString() == postId);
        if (index < 0) return;
        final updated = Map<String, dynamic>.from(_posts[index]);
        final packetUpdatedAt = (packet['updatedAt'] as num?)?.toInt() ?? 0;
        final currentUpdatedAt = (updated['updatedAt'] as num?)?.toInt() ?? 0;
        if (packetUpdatedAt <= currentUpdatedAt) return;
        updated['likes'] = List<String>.from(packet['likes'] as List? ?? const []);
        updated['comments'] = List<Map<String, dynamic>>.from(
          (packet['comments'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)),
        );
        updated['updatedAt'] = packetUpdatedAt;
        if (mounted) setState(() { _posts[index] = updated; _sortPosts(_posts); });
        await _save();
        final hops = (packet['hops'] as num?)?.toInt() ?? 0;
        await _broadcastPostUpdate(updated, hops: hops + 1);
        return;
      }
      if (packetType != 'public_feed_post') return;
      final post = Map<String, dynamic>.from(packet['post'] as Map);
      final hops = (packet['hops'] as num?)?.toInt() ?? 0;
      if (post['mediaBase64'] != null) {
        try {
          final bytes = base64Decode(post['mediaBase64'].toString());
          if (bytes.length > _maxPostMediaBytes) return;
          final dir = await _feedDir();
          final ext = post['mediaType'] == 'video' ? 'mp4' : 'jpg';
          final safeId = (post['id']?.toString() ?? 'post').replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
          final file = File('${dir.path}/received_$safeId.$ext');
          await file.writeAsBytes(bytes, flush: true);
          post['mediaPath'] = file.path;
        } catch (_) { return; }
        post.remove('mediaBase64');
      }
      await _mergeIncomingPost(post, hops: hops);
    } catch (_) { /* Ignore malformed, incomplete, or oversized peer packets. */ }
  }

  Future<void> _completeIncomingMedia(_IncomingFeedMedia transfer) async {
    try {
      if (transfer.chunks.length != transfer.chunkCount ||
          transfer.receivedBytes != transfer.compressedBytes) return;
      final compressed = BytesBuilder(copy: false);
      for (var i = 0; i < transfer.chunkCount; i++) {
        final chunk = transfer.chunks[i];
        if (chunk == null) return;
        compressed.add(chunk);
      }
      final media = gzip.decode(compressed.takeBytes());
      if (media.length != transfer.originalBytes || media.length > _maxPostMediaBytes) return;
      final post = transfer.post;
      final dir = await _feedDir();
      final ext = post['mediaType'] == 'video' ? 'mp4' : 'jpg';
      final safeId = (post['id']?.toString() ?? 'post').replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final file = File('${dir.path}/received_$safeId.$ext');
      await file.writeAsBytes(media, flush: true);
      post['mediaPath'] = file.path;
      post.remove('mediaBase64');
      await _mergeIncomingPost(post, hops: transfer.hops);
    } catch (_) {
      // A truncated/corrupt transfer is discarded; the next peer reconciliation retries it.
    }
  }

  Future<void> _mergeIncomingPost(Map<String, dynamic> post, {int hops = 0}) async {
    if (post['authorId']?.toString() == _myId) return;
    final profileData = post['profilePhotoBase64']?.toString();
    if (profileData != null && profileData.isNotEmpty) {
      try {
        final bytes = base64Decode(profileData);
        if (bytes.length <= 80 * 1024) {
          final dir = await _feedDir();
          final safeAuthor = (post['authorId']?.toString() ?? 'user').replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
          final photoFile = File('${dir.path}/profile_$safeAuthor.jpg');
          await photoFile.writeAsBytes(bytes, flush: true);
          post['profilePhotoPath'] = photoFile.path;
        }
      } catch (_) {}
      post.remove('profilePhotoBase64');
    }

    final duplicateIndex = _posts.indexWhere((p) => p['id']?.toString() == post['id']?.toString());
    if (duplicateIndex >= 0) {
      final current = _posts[duplicateIndex];
      final incomingUpdated = (post['updatedAt'] as num?)?.toInt() ?? (post['createdAt'] as num?)?.toInt() ?? 0;
      final currentUpdated = (current['updatedAt'] as num?)?.toInt() ?? (current['createdAt'] as num?)?.toInt() ?? 0;
      final currentMediaPath = current['mediaPath']?.toString() ?? '';
      final incomingMediaPath = post['mediaPath']?.toString() ?? '';
      final currentHasMedia = current['mediaType'] == 'text' ||
          (currentMediaPath.isNotEmpty && File(currentMediaPath).existsSync());
      final hasMissingMedia = !currentHasMedia && incomingMediaPath.isNotEmpty &&
          File(incomingMediaPath).existsSync();
      if (incomingUpdated <= currentUpdated && !hasMissingMedia) return;
      final merged = Map<String, dynamic>.from(current);
      if (incomingUpdated > currentUpdated) {
        merged['likes'] = List<String>.from(post['likes'] as List? ?? const []);
        merged['comments'] = List<Map<String, dynamic>>.from((post['comments'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
        merged['updatedAt'] = incomingUpdated;
      }
      if (hasMissingMedia) merged['mediaPath'] = post['mediaPath'];
      if (mounted) setState(() { _posts[duplicateIndex] = merged; _sortPosts(_posts); });
      await _save();
      if (incomingUpdated > currentUpdated) {
        await _broadcastPostUpdate(merged, hops: hops + 1);
      } else if (hasMissingMedia) {
        try { await _broadcastPost(merged, hops: hops + 1); } catch (_) {}
      }
      return;
    }
    if (post['mediaPath'] == null && post['mediaType'] != 'text') return;
    if (!mounted) return;
    setState(() { _posts.add(post); _sortPosts(_posts); });
    await _save();
    try { await _broadcastPost(post, hops: hops + 1); } catch (_) {}
  }

  Future<void> _createPost() async {
    final kind = await showModalBottomSheet<String>(context: context, showDragHandle: true, builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.photo_outlined), title: const Text('نشر صورة'), onTap: () => Navigator.pop(ctx, 'image')),
      ListTile(leading: const Icon(Icons.video_library_outlined), title: const Text('نشر فيديو'), onTap: () => Navigator.pop(ctx, 'video')),
      ListTile(leading: const Icon(Icons.notes_outlined), title: const Text('نشر نص فقط'), onTap: () => Navigator.pop(ctx, 'text')),
      const SizedBox(height: 8),
    ])));
    if (kind == null || !mounted || _busy) return;
    setState(() => _busy = true);
    String? mediaPath;
    try {
      if (kind == 'image') {
        final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 68, maxWidth: 1280, maxHeight: 1280);
        if (picked == null) return;
        final dir = await _feedDir(); mediaPath = '${dir.path}/post_${DateTime.now().microsecondsSinceEpoch}.jpg';
        await File(picked.path).copy(mediaPath);
      } else if (kind == 'video') {
        final picked = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(seconds: 60));
        if (picked == null) return;
        final compressed = await VideoCompress.compressVideo(picked.path, quality: VideoQuality.LowQuality, deleteOrigin: false, includeAudio: true);
        final file = compressed?.file ?? File(picked.path);
        final dir = await _feedDir(); mediaPath = '${dir.path}/post_${DateTime.now().microsecondsSinceEpoch}.mp4';
        await file.copy(mediaPath);
      }
      if (!mounted) return;
      final textController = TextEditingController();
      final tagsController = TextEditingController();
      final content = await showDialog<Map<String,String>?>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('منشور جديد'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (mediaPath != null) Container(width: double.infinity, padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Theme.of(ctx).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)), child: Row(children: [Icon(kind == 'video' ? Icons.play_circle_outline : Icons.image_outlined), const SizedBox(width: 8), Expanded(child: Text(kind == 'video' ? 'فيديو مضغوط' : 'صورة مضغوطة'))])),
          TextField(controller: textController, maxLines: 4, maxLength: 1200, decoration: const InputDecoration(labelText: 'ماذا تريد أن تنشر؟', border: OutlineInputBorder())),
          const SizedBox(height: 10), TextField(controller: tagsController, decoration: const InputDecoration(labelText: 'هاشتاجات (مثال #بلوساب #أصدقاء)', border: OutlineInputBorder())),
          const SizedBox(height: 8), const Text('يُحفظ المنشور على جهازك ويُزامن تلقائيًا مع أجهزة بلوساب القريبة عند توفر الاتصال.', style: TextStyle(fontSize: 12)),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')), FilledButton(onPressed: () { if (kind == 'text' && textController.text.trim().isEmpty) return; Navigator.pop(ctx, {'text':textController.text.trim(),'tags':tagsController.text.trim()}); }, child: const Text('نشر'))],
      ));
      textController.dispose(); tagsController.dispose();
      if (content == null) return;
      final prefs = await SharedPreferences.getInstance();
      _myId = prefs.getString('wasl_user_id') ?? 'blousab-user';
      final post = <String,dynamic>{
        'id': '${_myId}_${DateTime.now().microsecondsSinceEpoch}', 'authorId': _myId,
        'authorName': widget.userName.isEmpty ? 'مستخدم بلوساب' : widget.userName,
        'profilePhotoPath': widget.profilePhotoPath, 'mediaType': kind, 'mediaPath': mediaPath,
        'text': content['text'] ?? '', 'hashtags': content['tags'] ?? '',
        'createdAt': DateTime.now().millisecondsSinceEpoch, 'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'likes': <String>[], 'comments': <Map<String,dynamic>>[],
      };
      setState(() => _posts.insert(0, post));
      await _save();
      try {
        if (LocalNetworkService.instance.isRunning) {
          await _broadcastPost(post);
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('نُشر المنشور وأُرسل إلى أجهزة بلوساب المتاحة.')));
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('حُفظ المنشور على جهازك، وستتم مزامنته تلقائيًا عند توفر اتصال مباشر بالأجهزة القريبة.')));
        }
      } catch (_) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('حُفظ المنشور على جهازك، لكن تعذّر إرساله للأجهزة القريبة حاليًا.')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر تجهيز المنشور: $e')));
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _toggleLike(Map<String,dynamic> post) async {
    final likes = List<String>.from(post['likes'] as List? ?? const []);
    if (likes.contains(_myId)) { likes.remove(_myId); } else { likes.add(_myId); }
    setState(() { post['likes'] = likes; post['updatedAt'] = DateTime.now().millisecondsSinceEpoch; }); await _save(); await _broadcastPostUpdate(post);
  }

  Future<void> _comments(Map<String,dynamic> post) async {
    final controller = TextEditingController();
    await showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, builder: (ctx) => StatefulBuilder(builder: (ctx,setSheet) {
      final comments = List<Map<String,dynamic>>.from((post['comments'] as List? ?? const []).map((e) => Map<String,dynamic>.from(e as Map)));
      return Padding(padding: EdgeInsets.only(left: 16,right: 16,top: 8,bottom: MediaQuery.of(ctx).viewInsets.bottom+16), child: SizedBox(height: MediaQuery.of(ctx).size.height*0.55, child: Column(children: [
        const Text('التعليقات',style: TextStyle(fontSize: 18,fontWeight: FontWeight.bold)), const SizedBox(height: 12),
        Expanded(
          child: comments.isEmpty
              ? const Center(child: Text('لا توجد تعليقات بعد.'))
              : ListView(
                  children: comments.map((c) => ListTile(
                    dense: true,
                    leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                    title: Text(c['name']?.toString() ?? 'مستخدم'),
                    subtitle: Text(c['text']?.toString() ?? ''),
                  )).toList(),
                ),
        ),
        Row(children: [Expanded(child: TextField(controller: controller, maxLength: 500, decoration: const InputDecoration(hintText:'اكتب تعليقًا', counterText:'', border: OutlineInputBorder()))), const SizedBox(width:8), IconButton.filled(onPressed: () async { final text = controller.text.trim(); if (text.isEmpty) return; comments.add({'id':'${_myId}_${DateTime.now().microsecondsSinceEpoch}','name':widget.userName,'userId':_myId,'text':text,'createdAt':DateTime.now().millisecondsSinceEpoch}); post['comments'] = comments; post['updatedAt'] = DateTime.now().millisecondsSinceEpoch; controller.clear(); setSheet((){}); setState((){}); await _save(); await _broadcastPostUpdate(post); }, icon: const Icon(Icons.send))]),
      ])));
    }));
    controller.dispose();
  }

  Future<void> _requestChat(Map<String,dynamic> post) async {
    final authorId = post['authorId']?.toString() ?? '';
    if (authorId.isEmpty || authorId == _myId) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('هذا منشورك أنت.'))); return; }
    if (_friends.contains(authorId)) {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(conversationId: 'peer_$authorId', title: post['authorName']?.toString() ?? 'صديق', currentUserId: _myId, currentUserName: widget.userName, initialPeerAddress: null, connectionAlreadyEstablished: false)));
      return;
    }
    final accepted = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('طلب صداقة قبل المحادثة'), content: Text('سيتم إرسال طلب صداقة إلى ${post['authorName'] ?? 'المستخدم'}. لن تُفتح المحادثة مباشرة.'), actions: [TextButton(onPressed: () => Navigator.pop(ctx,false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(ctx,true), child: const Text('إرسال الطلب'))]));
    if (accepted != true) return;
    final packet = jsonEncode({'type':'friend_request','requestId':'${_myId}_${DateTime.now().microsecondsSinceEpoch}','senderId':_myId,'senderName':widget.userName,'recipientId':authorId,'createdAt':DateTime.now().millisecondsSinceEpoch});
    try {
      if (!LocalNetworkService.instance.isRunning) throw StateError('no network');
      await LocalNetworkService.instance.broadcastMessage(packet);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('أُرسل طلب الصداقة عبر الشبكة المحلية إن كان الجهاز متاحًا. لن تفتح المحادثة قبل الموافقة.')));
    } catch (_) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر إرسال الطلب الآن. يجب توفر قناة اتصال مباشرة بين الجهازين.'))); }
  }

  String _time(dynamic value) { final ms = (value as num?)?.toInt() ?? 0; final d = DateTime.fromMillisecondsSinceEpoch(ms); final delta = DateTime.now().difference(d); if (delta.inMinutes < 1) return 'الآن'; if (delta.inHours < 1) return 'منذ ${delta.inMinutes} د'; if (delta.inDays < 1) return 'منذ ${delta.inHours} س'; return '${d.day}/${d.month}/${d.year}'; }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('الخلاصة العامة'), actions:[IconButton(tooltip:'ترتيب عشوائي / الأحدث',onPressed:_toggleOrder,icon:Icon(_randomOrder?Icons.shuffle:Icons.sort)),IconButton(tooltip:'تحديث',onPressed:_refreshFeed,icon:const Icon(Icons.refresh))]),
    body: _loading ? const Center(child:CircularProgressIndicator()) : _loadError != null ? Center(child:Padding(padding:const EdgeInsets.all(24),child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.cloud_off_outlined,size:52),const SizedBox(height:12),Text(_loadError!,textAlign:TextAlign.center),const SizedBox(height:12),FilledButton.icon(onPressed:_refreshFeed,icon:const Icon(Icons.refresh),label:const Text('إعادة المحاولة'))]))) : _posts.isEmpty ? Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize:MainAxisSize.min,children:[Icon(Icons.dynamic_feed_outlined,size:64,color:Theme.of(context).colorScheme.primary),const SizedBox(height:12),const Text('لا توجد منشورات بعد',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold)),const SizedBox(height:8),const Text('انشر صورة أو فيديو أو نص. ستظهر تلقائيًا المنشورات التي تصل من أجهزة بلوساب القريبة عند توفر قناة اتصال مباشرة.',textAlign:TextAlign.center)]))) : ListView.builder(controller:_scroll,padding:const EdgeInsets.only(bottom:90),itemCount:_posts.length,itemBuilder:(context,index){
      final post = _posts[index]; final author = post['authorName']?.toString() ?? 'مستخدم بلوساب'; final photo = post['profilePhotoPath']?.toString() ?? ''; final media = post['mediaPath']?.toString() ?? ''; final type = post['mediaType']?.toString() ?? 'text'; final likes = List<String>.from(post['likes'] as List? ?? const []); final comments = post['comments'] as List? ?? const []; final hashtags = post['hashtags']?.toString() ?? '';
      return Card(margin:const EdgeInsets.fromLTRB(10,8,10,4),clipBehavior:Clip.antiAlias, child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        ListTile(leading:CircleAvatar(backgroundImage:photo.isNotEmpty && File(photo).existsSync()?FileImage(File(photo)):null,child:photo.isEmpty || !File(photo).existsSync()?const Icon(Icons.person_outline):null),title:Text(author,style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text(_time(post['createdAt'])),trailing:PopupMenuButton<String>(onSelected:(v) async { if(v=='delete' && post['authorId']==_myId){setState(()=>_posts.remove(post));await _save();} else if(v=='report'){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تم تسجيل البلاغ محليًا.')));}},itemBuilder:(_)=>[if(post['authorId']==_myId) const PopupMenuItem(value:'delete',child:Text('حذف المنشور')),const PopupMenuItem(value:'report',child:Text('إبلاغ'))])),
        if(type=='image' && media.isNotEmpty) Container(width:double.infinity,constraints:const BoxConstraints(maxHeight:520),color:Theme.of(context).colorScheme.surfaceContainerHighest,child:Image.file(File(media),width:double.infinity,fit:BoxFit.contain,errorBuilder:(_,__,___)=>const SizedBox(height:180,child:Center(child:Icon(Icons.broken_image_outlined))))),
        if(type=='video' && media.isNotEmpty) _FeedVideo(path:media),
        if((post['text']?.toString() ?? '').isNotEmpty) Padding(padding:const EdgeInsets.fromLTRB(14,12,14,4),child:Text(post['text'].toString(),style:const TextStyle(fontSize:15))),
        if(hashtags.isNotEmpty) Padding(padding:const EdgeInsets.fromLTRB(14,4,14,8),child:Text(hashtags.split(RegExp(r'\s+')).map((tag)=>tag.startsWith('#')?tag:'#${tag}').join(' '),style:TextStyle(color:Theme.of(context).colorScheme.primary,fontWeight:FontWeight.w500))),
        Row(children:[IconButton(onPressed:()=>_toggleLike(post),icon:Icon(likes.contains(_myId)?Icons.favorite:Icons.favorite_border,color:likes.contains(_myId)?Colors.red:null)),Text('${likes.length}'),IconButton(onPressed:()=>_comments(post),icon:const Icon(Icons.mode_comment_outlined)),Text('${comments.length}'),const Spacer(),IconButton(tooltip:'طلب صداقة قبل المحادثة',onPressed:()=>_requestChat(post),icon:const Icon(Icons.chat_bubble_outline)),const SizedBox(width:8)]),
      ]));
    }),
    floatingActionButton:FloatingActionButton.extended(onPressed:_busy?null:_createPost,icon:_busy?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.add),label:Text(_busy?'جارٍ التجهيز':'إنشاء منشور')),
  );
}

class _IncomingFeedMedia {
  final Map<String, dynamic> post;
  final int chunkCount;
  final int compressedBytes;
  final int originalBytes;
  final int hops;
  final DateTime createdAt = DateTime.now();
  final Map<int, List<int>> chunks = <int, List<int>>{};
  int receivedBytes = 0;
  _IncomingFeedMedia({required this.post, required this.chunkCount,
    required this.compressedBytes, required this.originalBytes, required this.hops});
}

class _FeedVideo extends StatefulWidget { final String path; const _FeedVideo({required this.path}); @override State<_FeedVideo> createState()=>_FeedVideoState(); }
class _FeedVideoState extends State<_FeedVideo> {
  late final VideoPlayerController _controller;
  bool _ready=false;
  @override void initState(){super.initState();_controller=VideoPlayerController.file(File(widget.path))..initialize().then((_){if(mounted)setState(()=>_ready=true);}).catchError((_){ });}
  @override void dispose(){_controller.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>_ready?GestureDetector(onTap:(){setState(()=>_controller.value.isPlaying?_controller.pause():_controller.play());},child:Stack(alignment:Alignment.center,children:[AspectRatio(aspectRatio:_controller.value.aspectRatio,child:VideoPlayer(_controller)),if(!_controller.value.isPlaying)const CircleAvatar(backgroundColor:Colors.black54,child:Icon(Icons.play_arrow,color:Colors.white))])):const SizedBox(height:200,child:Center(child:CircularProgressIndicator()));
}
