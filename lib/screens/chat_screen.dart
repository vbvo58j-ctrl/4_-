import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_filex/open_filex.dart';

import '../models/blousab_message.dart';
import '../services/message_store.dart';
import '../services/pending_message_store.dart';
import '../services/relay_queue_store.dart';
import '../services/relay_route_planner.dart';
import '../services/mesh_route_directory.dart';
import '../services/mesh_runtime_service.dart';
import '../services/community_store.dart';
import '../services/local_network_service.dart';
import '../services/wifi_aware_service.dart';
import '../services/notification_service.dart';
import '../services/bluetooth_classic_service.dart';
import '../services/nearby_peer_directory.dart';
import '../services/blousab_crypto_identity.dart';
import '../services/group_e2e_crypto_service.dart';
import '../services/pairwise_chain_ratchet_service.dart';

class ChatScreen extends StatefulWidget {
final String conversationId;
final String title;
final String currentUserId;
final String currentUserName;
final String? initialPeerAddress;
final bool connectionAlreadyEstablished;
final Future<void> Function(BlousabMessage message)? onSendMessage;

const ChatScreen({
super.key,
required this.conversationId,
required this.title,
required this.currentUserId,
required this.currentUserName,
this.initialPeerAddress,
this.connectionAlreadyEstablished = false,
this.onSendMessage,
});

@override
State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
final MessageStore _store = MessageStore();
final CommunityStore _communityStore = CommunityStore();
final BluetoothClassicService _bluetooth =
BluetoothClassicService.instance;

final TextEditingController _textController =
TextEditingController();
final ScrollController _scrollController = ScrollController();

final Set<String> _receivedIds = <String>{};
final Set<String> _ratchetPacketIds = <String>{};
final Map<String, Completer<void>> _pendingAcks = <String, Completer<void>>{};
final Map<String, Completer<void>> _ratchetWaiters = <String, Completer<void>>{};
// Only peers that passed the native reciprocal Blousab handshake are eligible
// for Bluetooth mesh forwarding. Address is transport metadata, never identity.
final Map<String, String> _verifiedBluetoothPeers = <String, String>{};
static const int _fileChunkBytes = 24 * 1024;
static const int _maxChatFileBytes = 4 * 1024 * 1024;

List<BlousabMessage> _messages = [];
List<BlousabDevice> _devices = [];

StreamSubscription<BlousabEvent>? _subscription;
StreamSubscription<String>? _messageStoreSubscription;
StreamSubscription<BlousabEvent>? _lanSubscription;
StreamSubscription<WifiAwareEvent>? _awareProfileSubscription;
StreamSubscription<BlousabEvent>? _bluetoothIdentitySubscription;
Timer? _relayRetryTimer;

String? _selectedAddress;
String? _selectedWifiAddress;
String _connectionStatus = 'غير متصل';
String _profileCoverPath = '';
String _myProfilePhotoPath = '';
String _peerProfilePhotoPath = '';
String _peerDisplayName = '';
String _connectionMode = 'bluetooth';

bool _loading = true;
bool _sending = false;
bool _working = false;
bool _isCommunityConversation = false;
bool _peerBlocked = false;
double _messageFontSize = 16;
bool _showMessageTime = true;
bool _vibrateOnSend = true;
bool _compactBubbles = false;
String _chatWallpaper = 'mint';

@override
void initState() {
super.initState();
NotificationService.activeConversationId = widget.conversationId;
SharedPreferences.getInstance().then((prefs) {
  if (!mounted) return;
  setState(() {
    _profileCoverPath = prefs.getString('wasl_profile_cover') ?? '';
    _myProfilePhotoPath = prefs.getString('wasl_profile_photo') ?? '';
    _connectionMode = prefs.getString('blousab_connection_mode') ?? 'bluetooth';
    final chatKey = 'blousab_chat_${widget.conversationId}_';
    final peerId = _peerIdFromConversation();
    _peerBlocked = peerId != null && (prefs.getBool('blousab_blocked_peer_$peerId') ?? false);
    _messageFontSize = (prefs.getDouble('${chatKey}font_size') ?? prefs.getDouble('blousab_message_font_size') ?? 16).clamp(14, 22).toDouble();
    _showMessageTime = prefs.getBool('${chatKey}show_time') ?? prefs.getBool('blousab_show_message_time') ?? true;
    _vibrateOnSend = prefs.getBool('${chatKey}vibrate') ?? prefs.getBool('blousab_vibrate_on_send') ?? true;
    _compactBubbles = prefs.getBool('${chatKey}compact') ?? prefs.getBool('blousab_compact_bubbles') ?? false;
    _chatWallpaper = prefs.getString('${chatKey}wallpaper') ?? prefs.getString('wasl_chat_wallpaper') ?? 'mint';
  });
  _loadPeerProfile();
});
_selectedAddress = widget.initialPeerAddress;
_communityStore.findById(widget.conversationId).then((c) { if (mounted) setState(() => _isCommunityConversation = c != null); });
_loadMessages();
_messageStoreSubscription = MessageStore.updates.listen((conversationId) async {
  if (!mounted || conversationId != widget.conversationId) return;
  final refreshed = await _store.getMessages(widget.conversationId);
  if (mounted) setState(() => _messages = refreshed);
});
_listenToBluetooth();
_lanSubscription = LocalNetworkService.instance.events.listen(_handleBluetoothEvent);
_awareProfileSubscription = WifiAwareService.instance.events.listen(_handleWifiAwareProfileEvent);
_bluetoothIdentitySubscription = BluetoothClassicService.instance.events.listen(_handleBluetoothIdentityEvent);
_restoreLastConnection();
Future<void>.delayed(const Duration(seconds: 2), _retryPendingOutbox);
Future<void>.delayed(const Duration(seconds: 3), _retryRelayQueue);
_relayRetryTimer = Timer.periodic(const Duration(seconds: 20), (_) {
  if (mounted) {
    _retryRelayQueue();
  }
});
}

Future<void> _clearConversationMessages() async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('مسح محتوى الدردشة؟'),
      content: const Text('سيتم حذف الرسائل المحفوظة في هذه المحادثة من هذا الهاتف فقط. لن تُحذف من هاتف الطرف الآخر.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('مسح الدردشة')),
      ],
    ),
  );
  if (confirmed != true) return;
  await _store.clearMessages(widget.conversationId);
  if (!mounted) return;
  setState(() {
    _messages.clear();
    _receivedIds.clear();
  });
  _showNotice('تم مسح محتوى هذه الدردشة من هذا الهاتف.');
}

Future<void> _togglePeerBlock() async {
  final peerId = _peerIdFromConversation();
  if (peerId == null) {
    _showNotice('الحظر متاح للمحادثات الخاصة التي لها معرّف مستخدم.');
    return;
  }
  final nextBlocked = !_peerBlocked;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(nextBlocked ? 'حظر جهة الاتصال؟' : 'فك حظر جهة الاتصال؟'),
      content: Text(nextBlocked
          ? 'سيتم تجاهل الرسائل الواردة من هذا المستخدم على هذا الجهاز.'
          : 'سيُسمح باستقبال الرسائل من هذا المستخدم مجددًا.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(nextBlocked ? 'حظر' : 'فك الحظر')),
      ],
    ),
  );
  if (confirmed != true) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('blousab_blocked_peer_$peerId', nextBlocked);
  if (!mounted) return;
  setState(() => _peerBlocked = nextBlocked);
  _showNotice(nextBlocked ? 'تم حظر جهة الاتصال على هذا الجهاز.' : 'تم فك الحظر.');
}

Widget _wifiPeerAvatar(Map<String, String> peer) {
  final encoded = peer['photo'];
  if (encoded != null && encoded.isNotEmpty) {
    try {
      return CircleAvatar(
        radius: 25,
        backgroundImage: MemoryImage(base64Decode(encoded)),
        onBackgroundImageError: (_, __) {},
      );
    } catch (_) {}
  }
  final name = (peer['name'] ?? '').trim();
  return CircleAvatar(
    radius: 25,
    child: Text(name.isEmpty ? '؟' : name.characters.first),
  );
}

void _handleBluetoothIdentityEvent(BlousabEvent event) {
  if (event.type != 'blousabVerified' || event.userId == null || event.userId!.isEmpty) return;
  final address = event.address;
  if (address != null && address.isNotEmpty) {
    _verifiedBluetoothPeers[address] = event.userId!;
  }
  // The native layer emits this event only after a reciprocal signed Bluetooth
  // nonce handshake. Cache the verified profile; never use the Android device name.
  SharedPreferences.getInstance().then((prefs) async {
    await prefs.setString('blousab_peer_name_id_${event.userId}', event.userName ?? 'مستخدم بلوساب');
    if (event.profilePhoto != null && event.profilePhoto!.isNotEmpty) {
      await prefs.setString('blousab_peer_photo_uri_${event.userId}', event.profilePhoto!);
    }
  });
}

Future<void> _changeConnectionFlow() async {
  final directory = NearbyPeerDirectory.instance;
  directory.start(selfUserId: widget.currentUserId);
  StateSetter? updateDialog;
  late final StreamSubscription<void> directorySubscription;
  var starting = true;
  String? startupError;

  directorySubscription = directory.changes.listen((_) {
    updateDialog?.call(() {});
  });

  try {
    await Future.wait<void>([
      WifiAwareService.instance.start(
        userId: widget.currentUserId,
        userName: widget.currentUserName,
      ),
      BluetoothClassicService.instance.startServer(),
      BluetoothClassicService.instance.startDiscovery(),
    ]);
  } catch (error) {
    startupError = error.toString();
  } finally {
    starting = false;
  }

  if (!mounted) {
    await directorySubscription.cancel();
    return;
  }

  final chosen = await showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setDialogState) {
      updateDialog = setDialogState;
      final entries = directory.peers
        ..sort((a, b) => a.userName.toLowerCase().compareTo(b.userName.toLowerCase()));
      return Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 560),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                const Icon(Icons.radar, color: Color(0xFF159B83), size: 26),
                const SizedBox(width: 10),
                const Expanded(child: Text('مستخدمو بلوساب القريبون', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
              ]),
              const Align(
                alignment: Alignment.centerRight,
                child: Text('بحث متزامن عبر Bluetooth وWi-Fi Aware', style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
              const SizedBox(height: 12),
              Flexible(child: entries.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 12),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(startupError == null ? Icons.wifi_find : Icons.info_outline, size: 42, color: Colors.grey),
                      const SizedBox(height: 12),
                      Text(startupError == null
                        ? (starting ? 'جارٍ بدء البحث عن مستخدمي بلوساب...' : 'لم يظهر مستخدم موثّق قريب بعد')
                        : 'تعذر تشغيل إحدى وسائل الاكتشاف: $startupError',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'لا تظهر إلا هويات بلوساب التي اجتازت المصافحة التشفيرية. لا تظهر أسماء أجهزة Android العامة.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ]),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, index) {
                      final peer = entries[index];
                      return FutureBuilder<SharedPreferences>(
                        future: SharedPreferences.getInstance(),
                        builder: (ctx, snapshot) {
                          final prefs = snapshot.data;
                          final photoPath = prefs?.getString('blousab_peer_photo_${peer.userId}') ?? prefs?.getString('blousab_peer_photo_uri_${peer.userId}') ?? '';
                          final photo = photoPath.isNotEmpty ? File(photoPath) : null;
                          final validPhoto = photo != null && photo.existsSync();
                          final cachedName = prefs?.getString('blousab_peer_name_id_${peer.userId}') ?? '';
                          final name = cachedName.trim().isNotEmpty ? cachedName.trim() : peer.userName;
                          return ListTile(
                            leading: CircleAvatar(
                              radius: 24,
                              backgroundImage: validPhoto ? FileImage(photo!) : null,
                              child: validPhoto ? null : Text(name.isEmpty ? '؟' : name.characters.first),
                            ),
                            title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(peer.wifiAwareVerified && peer.bluetoothAvailable
                                ? 'تم التحقق عبر Bluetooth وWi-Fi Aware'
                                : peer.wifiAwareVerified
                                    ? 'تم التحقق عبر Wi-Fi Aware'
                                    : peer.wifiAwareCandidate
                                        ? 'تم التحقق عبر Bluetooth • إشارة Wi-Fi قيد المطابقة'
                                        : 'تم التحقق من الهوية عبر Bluetooth'),
                            trailing: Icon(
                              peer.wifiAwareVerified && peer.bluetoothAvailable
                                  ? Icons.wifi_tethering
                                  : peer.wifiAwareVerified
                                      ? Icons.wifi
                                      : Icons.bluetooth,
                              color: const Color(0xFF159B83),
                            ),
                            onTap: () {
                              if (peer.bluetoothAvailable) {
                                Navigator.pop(ctx, peer.userId);
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('تم توثيق الهوية عبر Wi-Fi Aware؛ ربط نقل الرسائل بهذه القناة سيكون في المرحلة التالية.')),
                                );
                              }
                            },
                          );
                        },
                      );
                    },
                  ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: Text(
                  'مستخدمون اجتازوا المصافحة فقط • إشارات Wi-Fi بانتظار التحقق: ${directory.pendingWifiCandidateCount}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                )),
                TextButton(onPressed: () => setDialogState(() {}), child: const Text('تحديث')),
              ]),
            ]),
          ),
        ),
      );
    }),
  );
  await directorySubscription.cancel();

  if (chosen != null && mounted) {
    NearbyPeer? selectedPeer;
    for (final peer in directory.peers) {
      if (peer.userId == chosen) { selectedPeer = peer; break; }
    }
    if (selectedPeer == null) {
      _showNotice('اختفى المستخدم قبل اختياره؛ أعد البحث عنه.');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('blousab_last_wifi_peer_${widget.conversationId}', chosen);
    if (selectedPeer.bluetoothAddresses.isNotEmpty) {
      final address = selectedPeer.bluetoothAddresses.first;
      await prefs.setString('blousab_last_bluetooth_address_${widget.conversationId}', address);
      await prefs.setString('blousab_connection_mode', 'bluetooth');
      setState(() {
        _selectedAddress = address;
        _selectedWifiAddress = null;
        _connectionMode = 'bluetooth';
        _connectionStatus = 'تم اختيار مستخدم بلوساب موثّق: $chosen';
      });
      _showNotice('تم اختيار هوية موثّقة. لم يبدأ الاتصال أو إرسال الرسائل تلقائيًا.');
    } else {
      _showNotice('تم توثيق المستخدم عبر Wi-Fi Aware، لكن ربط نقل الرسائل بهذه القناة لم يكتمل بعد.');
    }
  }
}

Future<void> _openConversationSettings() async {
  double fontSize = _messageFontSize;
  bool showTime = _showMessageTime;
  bool compact = _compactBubbles;
  bool vibrate = _vibrateOnSend;
  String wallpaper = _chatWallpaper;
  final result = await showDialog<Map<String, Object?>>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setDialogState) => AlertDialog(
    title: const Text('إعدادات هذه المحادثة'),
    content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(title: const Text('حجم الخط'), subtitle: Slider(value: fontSize, min: 14, max: 22, divisions: 4, label: fontSize.round().toString(), onChanged: (v) => setDialogState(() => fontSize = v))),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('إظهار وقت الرسالة'), value: showTime, onChanged: (v) => setDialogState(() => showTime = v)),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('فقاعات مضغوطة'), subtitle: const Text('تقليل المسافات حول الرسائل'), value: compact, onChanged: (v) => setDialogState(() => compact = v)),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('اهتزاز عند الإرسال'), value: vibrate, onChanged: (v) => setDialogState(() => vibrate = v)),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(value: wallpaper, decoration: const InputDecoration(labelText: 'خلفية المحادثة'), items: const [DropdownMenuItem(value: 'mint', child: Text('أخضر فاتح')), DropdownMenuItem(value: 'plain', child: Text('أبيض بسيط')), DropdownMenuItem(value: 'dark', child: Text('داكن'))], onChanged: (v) { if (v != null) setDialogState(() => wallpaper = v); }),
      const Divider(height: 24),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.delete_sweep_outlined, color: Colors.red),
        title: const Text('مسح محتوى الدردشة'),
        subtitle: const Text('حذف الرسائل من هذا الهاتف فقط'),
        onTap: () { Navigator.pop(ctx); _clearConversationMessages(); },
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(_peerBlocked ? Icons.person_add_alt_1 : Icons.block, color: _peerBlocked ? Colors.teal : Colors.red),
        title: Text(_peerBlocked ? 'فك الحظر' : 'حظر جهة الاتصال'),
        subtitle: Text(_peerBlocked ? 'السماح باستقبال الرسائل مجددًا' : 'تجاهل الرسائل الواردة من هذا المستخدم'),
        onTap: () { Navigator.pop(ctx); _togglePeerBlock(); },
      ),
      const SizedBox(height: 8), const Text('تُحفظ هذه الخيارات لهذه المحادثة فقط ولا تغيّر إعدادات المحادثات الأخرى.', style: TextStyle(fontSize: 12)),
    ])),
    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(ctx, {'fontSize': fontSize, 'showTime': showTime, 'compact': compact, 'vibrate': vibrate, 'wallpaper': wallpaper}), child: const Text('حفظ'))],
  )));
  if (result == null) return;
  final prefs = await SharedPreferences.getInstance();
  final prefix = 'blousab_chat_${widget.conversationId}_';
  await prefs.setDouble('${prefix}font_size', result['fontSize'] as double);
  await prefs.setBool('${prefix}show_time', result['showTime'] as bool);
  await prefs.setBool('${prefix}compact', result['compact'] as bool);
  await prefs.setBool('${prefix}vibrate', result['vibrate'] as bool);
  await prefs.setString('${prefix}wallpaper', result['wallpaper'] as String);
  if (!mounted) return;
  setState(() { _messageFontSize = result['fontSize'] as double; _showMessageTime = result['showTime'] as bool; _compactBubbles = result['compact'] as bool; _vibrateOnSend = result['vibrate'] as bool; _chatWallpaper = result['wallpaper'] as String; });
}

Future<String?> _profilePhotoPayload() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString('wasl_profile_photo') ?? _myProfilePhotoPath;
    if (path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    // Keep profile cards small enough for Bluetooth text packets.
    if (bytes.isEmpty || bytes.length > 100 * 1024) return null;
    return base64Encode(bytes);
  } catch (_) { return null; }
}

String? _peerIdFromConversation() {
  if (!widget.conversationId.startsWith('dm_')) return null;
  // Blousab IDs themselves contain underscores (for example bs_...). Never
  // split on '_' to recover a peer ID; remove our exact ID from either edge.
  final pair = widget.conversationId.substring(3);
  final localPrefix = '${widget.currentUserId}_';
  final localSuffix = '_${widget.currentUserId}';
  if (pair.startsWith(localPrefix)) {
    final peer = pair.substring(localPrefix.length);
    return peer.isEmpty ? null : peer;
  }
  if (pair.endsWith(localSuffix)) {
    final peer = pair.substring(0, pair.length - localSuffix.length);
    return peer.isEmpty ? null : peer;
  }
  return null;
}

Future<void> _loadPeerProfile() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final peerId = _peerIdFromConversation();
    final address = widget.initialPeerAddress;
    final cachedName = peerId == null ? null : prefs.getString('blousab_peer_name_id_$peerId');
    final addressName = address == null ? null : prefs.getString('blousab_peer_name_$address');
    final photoPath = peerId == null ? null : prefs.getString('blousab_peer_photo_$peerId');
    if (!mounted) return;
    setState(() {
      _peerDisplayName = (cachedName?.isNotEmpty == true ? cachedName : addressName) ?? widget.title;
      _peerProfilePhotoPath = photoPath ?? '';
    });
  } catch (_) {}
}

Future<void> _handleWifiAwareProfileEvent(WifiAwareEvent event) async {
  final peer = event.peer;
  if (peer == null || peer.userId == widget.currentUserId) return;
  if (event.type == 'dataConnected') {
    try {
      // Mesh route exchange is owned by the application-scoped MeshRuntimeService.
      final prefs = await SharedPreferences.getInstance();
      final photoPath = prefs.getString('wasl_profile_photo') ?? _myProfilePhotoPath;
      String? photo;
      if (photoPath.isNotEmpty) {
        final file = File(photoPath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          // Keep the profile card bounded; oversized originals are not sent here.
          if (bytes.length <= 90 * 1024) photo = base64Encode(bytes);
        }
      }
      await WifiAwareService.instance.sendPacket(
        peerId: peer.userId,
        payload: jsonEncode({
          'type': 'profile_card',
          'protocol': 'blousab-nearby-v1',
          'senderId': widget.currentUserId,
          'senderName': widget.currentUserName,
          if (photo != null) 'senderPhoto': photo,
        }),
      );
    } catch (_) {
      // Profile discovery remains available even if the optional photo transfer fails.
    }
  } else if (event.type == 'dataPacket' && event.payload != null) {
    try {
      final decoded = jsonDecode(event.payload!);
      if (decoded is Map && (decoded['type'] == 'profile_card' || decoded['type'] == 'profile_update')) {
        await _cachePeerProfile(decoded);
      }
    } catch (_) {}
    if (event.payload != null) {
      try {
        final packet = jsonDecode(event.payload!);
        if (packet is Map && (packet['type'] == 'blousab_ratchet_offer' ||
            packet['type'] == 'blousab_ratchet_answer' ||
            packet['type'] == 'blousab_pair_chain_message')) {
          await _handleIncomingMessage(event.payload!, null);
        }
      } catch (_) {}
    }
  }
}

Future<void> _cachePeerProfile(Map packet) async {
  try {
    final senderId = packet['senderId']?.toString() ?? '';
    if (senderId.isEmpty || senderId == widget.currentUserId) return;
    final prefs = await SharedPreferences.getInstance();
    final senderName = packet['senderName']?.toString();
    if (senderName != null && senderName.trim().isNotEmpty) {
      await prefs.setString('blousab_peer_name_id_$senderId', senderName.trim());
    }
    final encoded = packet['senderPhoto']?.toString() ?? '';
    if (encoded.isNotEmpty && encoded.length <= 140000) {
      final bytes = base64Decode(encoded);
      final dir = await getApplicationDocumentsDirectory();
      final profileDir = Directory('${dir.path}/peer_profiles');
      if (!await profileDir.exists()) await profileDir.create(recursive: true);
      final file = File('${profileDir.path}/${senderId.replaceAll(RegExp(r"[^a-zA-Z0-9_-]"), "_")}.jpg');
      await file.writeAsBytes(bytes, flush: true);
      await prefs.setString('blousab_peer_photo_$senderId', file.path);
    }
    if (!mounted) return;
    if (senderId == _peerIdFromConversation()) {
      setState(() {
        if (senderName != null && senderName.trim().isNotEmpty) _peerDisplayName = senderName.trim();
        final path = prefs.getString('blousab_peer_photo_$senderId');
        if (path != null) _peerProfilePhotoPath = path;
      });
    }
  } catch (_) {}
}

Future<void> _restoreLastConnection() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (widget.initialPeerAddress != null && widget.initialPeerAddress!.isNotEmpty) {
      await prefs.setString('blousab_last_device_${widget.conversationId}', widget.initialPeerAddress!);
      if (widget.connectionAlreadyEstablished) {
        if (mounted) setState(() {
          _selectedAddress = widget.initialPeerAddress;
          _connectionStatus = 'جاهز للمحادثة عبر البلوتوث';
        });
        final photo = await _profilePhotoPayload();
        await _bluetooth.sendMessage(address: widget.initialPeerAddress!, message: jsonEncode({'type': 'profile_card', 'protocol': 'blousab-nearby-v1', 'senderId': widget.currentUserId, 'senderName': widget.currentUserName, if (photo != null) 'senderPhoto': photo}));
        return; // The invitation flow already established the RFCOMM connection.
      }
      try {
        await _bluetooth.connect(widget.initialPeerAddress!);
        if (mounted) setState(() { _selectedAddress = widget.initialPeerAddress; _connectionStatus = 'متصل عبر البلوتوث'; });
      } catch (_) {
        if (mounted) setState(() => _connectionStatus = 'تعذر الاتصال؛ استخدم زر البلوتوث لإعادة المحاولة');
      }
      return;
    }
    final address = prefs.getString('blousab_last_device_${widget.conversationId}');
    if (address == null || address.isEmpty) return;
    if (!await _bluetooth.isSupported() || !await _bluetooth.requestPermissions()) return;
    if (!await _bluetooth.isEnabled()) return;
    if (mounted) setState(() => _connectionStatus = 'جارٍ إعادة الاتصال بالجهاز المحفوظ...');
    await _bluetooth.connect(address);
    if (mounted) setState(() => _selectedAddress = address);
  } catch (_) {
    if (mounted) setState(() => _connectionStatus = 'غير متصل؛ يمكنك إعادة الاتصال من زر البلوتوث');
  }
}

Future<void> _loadMessages() async {
try {
final messages =
await _store.getMessages(widget.conversationId);

  if (!mounted) return;

  setState(() {
    _messages = messages;
    _receivedIds.addAll(messages.map((m) => m.id));
    _loading = false;
  });

  _scrollToBottom();
} catch (_) {
  if (!mounted) return;
  setState(() => _loading = false);
  _showNotice('تعذر تحميل سجل الرسائل.');
}

}

void _listenToBluetooth() {
_subscription = _bluetooth.events.listen(
_handleBluetoothEvent,
onError: (Object error) {
if (!mounted) return;
setState(() {
_connectionStatus = 'خطأ في أحداث البلوتوث';
});
},
);
}

void _handleBluetoothEvent(BlousabEvent event) {
if (!mounted) return;
if (event.type == 'lanStarted' || event.type == 'peerDiscovered') { _retryPendingOutbox(); _retryRelayQueue(); return; }

switch (event.type) {
  case 'connected':
    final address = event.address;
    if (address != null) {
      final peerId = _verifiedBluetoothPeers[address];
    }
    setState(() {
      _selectedAddress = event.address ?? _selectedAddress;
      _connectionStatus =
          'متصل: ${event.name ?? 'جهاز'}';
    });
    if (event.address != null) { SharedPreferences.getInstance().then((p) => p.setString('blousab_last_device_${widget.conversationId}', event.address!)); }
    _showNotice('تم الاتصال بجهاز ${event.name ?? ''}');
    _retryPendingOutbox();
    _retryRelayQueue();
    break;

  case 'disconnected':
    final lostAddress = event.address;
    if (lostAddress != null) {
      final lostPeer = _verifiedBluetoothPeers.remove(lostAddress);
    }
    if (_selectedAddress == event.address) {
      setState(() {
        _selectedAddress = null;
        _connectionStatus = 'انقطع الاتصال';
      });
    }
    break;

  case 'message':
    final raw = event.message;
    if (raw != null) {
      _handleIncomingMessage(raw, event.address);
    }
    break;

  case 'connectionError':
  case 'serverError':
    setState(() => _connectionStatus = 'حدث خطأ في الاتصال');
    _showNotice(event.message ?? 'تعذر الاتصال بالبلوتوث.');
    break;

  case 'serverStarted':
    setState(() {
      _connectionStatus = 'جاهز لاستقبال الاتصالات';
    });
    _retryPendingOutbox();
    _retryRelayQueue();
    break;

  case 'serverStopped':
    setState(() {
      _connectionStatus = 'الاستقبال متوقف';
    });
    break;
}

}

Future<void> _sendEncryptedReceipt({
  required String messageId,
  required String conversationId,
  required String recipientId,
  required String type,
}) async {
  if (recipientId.isEmpty || messageId.isEmpty) return;
  final now = DateTime.now().toIso8601String();
  final receiptId = 'ack_${type}_${messageId}_${widget.currentUserId}';
  final clearPacket = <String, Object?>{
    'type': type,
    'id': receiptId,
    'ackFor': messageId,
    'conversationId': conversationId,
    'senderId': widget.currentUserId,
    'recipientId': recipientId,
    'senderName': widget.currentUserName,
    'relay': true,
    'relayEnabled': true,
    'hopCount': 0,
    'hops': 0,
    'relayPath': <String>[],
    'sentAt': now,
    'createdAt': now,
  };
  try {
    final community = await _communityStore.findById(conversationId);
    if (community != null) {
      // Group receipts use the current group epoch; the intended sender ID is
      // inside the encrypted payload while the outer envelope remains routable.
      final groupEnvelope = await GroupE2eCryptoService.instance.sealGroupPayload(
        groupId: conversationId,
        senderId: widget.currentUserId,
        payload: jsonEncode(clearPacket),
        messageId: receiptId,
        routingFields: <String, Object?>{
          'conversationId': conversationId, 'sentAt': now, 'createdAt': now,
          'relay': true, 'relayEnabled': true, 'hopCount': 0,
          'hops': 0, 'relayPath': <String>[],
        },
      );
      await _broadcastGroupPayload(jsonEncode(groupEnvelope));
      return;
    }
    // A direct receipt uses the same pairwise ratchet as direct chat payloads.
    // Relays see routing metadata and ciphertext only.
    if (!await PairwiseChainRatchetService.instance.hasActiveSession(recipientId)) {
      throw StateError('لا توجد جلسة تشفير نشطة لإرسال إيصال آمن.');
    }
    final routing = <String, Object?>{
      'id': receiptId,
      'conversationId': conversationId,
      'senderId': widget.currentUserId,
      'recipientId': recipientId,
      'relay': true,
      'relayEnabled': true,
      'hopCount': 0,
      'hops': 0,
      'relayPath': <String>[],
      'sentAt': now,
      'createdAt': now,
    };
    final encrypted = await PairwiseChainRatchetService.instance.encrypt(
      peerId: recipientId,
      plaintext: jsonEncode(clearPacket),
      routingFields: routing,
    );
    await _sendRatchetControlPacket(encrypted, recipientId);
  } catch (error) {
    debugPrint('Encrypted $type could not be sent: $error');
  }
}

Future<void> _sendControlAck(String messageId, String conversationId, String? address, String recipientId, {String type = 'delivery_ack'}) async {
  await _sendEncryptedReceipt(
    messageId: messageId,
    conversationId: conversationId,
    recipientId: recipientId,
    type: type,
  );
}

Future<void> _sendReadAck(String messageId, String conversationId, String? address, String recipientId) async {
  await _sendEncryptedReceipt(
    messageId: messageId,
    conversationId: conversationId,
    recipientId: recipientId,
    type: 'read_ack',
  );
}

Future<void> _retryPendingOutbox() async {
  if (!mounted) return;
  List<Map<String, dynamic>> entries;
  try {
    entries = await PendingMessageStore.instance.list();
  } catch (error) {
    debugPrint('Pending outbox is preserved but could not be read: $error');
    return;
  }
  for (final entry in entries) {
    if (!mounted) return;
    if (entry['conversationId']?.toString() != widget.conversationId) continue;
    final messageId = entry['messageId']?.toString() ?? '';
    final payload = entry['payload']?.toString() ?? '';
    if (messageId.isEmpty || payload.isEmpty) continue;
    if (entry['kind'] == 'file_chunk_transfer') {
      final localPath = entry['localPath']?.toString() ?? '';
      final file = localPath.isEmpty ? null : File(localPath);
      if (file == null || !await file.exists()) continue;
      final attempts = (entry['attempts'] as num? ?? 0).toInt();
      if (attempts >= 12) continue;
      await PendingMessageStore.instance.noteAttempt(messageId);
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty || bytes.length > _maxChatFileBytes) continue;
        final isCommunity = entry['isCommunity'] == true;
        final peerId = _peerIdFromConversation();
        final photo = await _profilePhotoPayload();
        await _sendFileChunks(bytes: Uint8List.fromList(bytes), transferId: messageId,
          fileName: entry['fileName']?.toString() ?? 'ملف', senderPhoto: photo ?? '',
          recipientId: isCommunity ? '*' : (peerId ?? ''),
          relayEnabled: isCommunity || peerId != null, isCommunity: isCommunity,
          wifiMode: entry['wifiMode'] == true,
          bluetoothAddress: entry['bluetoothAddress']?.toString(),
          wifiAddress: entry['wifiAddress']?.toString(), sentAt: DateTime.now());
        // A successful socket write is not end-to-end delivery. Keep the
        // transfer record and source file until the authenticated delivery_ack
        // is consumed by MeshRuntimeService.
      } catch (_) { /* Keep the file transfer durable for a later retry. */ }
      continue;
    }
    final attempts = (entry['attempts'] as num? ?? 0).toInt();
    // Bounded automatic attempts per app launch; the durable entry remains for
    // the next launch/manual retry if no receiver ACK arrives.
    if (attempts >= 12) continue;
    await PendingMessageStore.instance.noteAttempt(messageId);
    try {
      await _transmitWithRetry(
        payload: payload,
        messageId: messageId,
        wifiMode: entry['wifiMode'] == true,
        isCommunity: entry['isCommunity'] == true,
        bluetoothAddress: entry['bluetoothAddress']?.toString(),
        wifiAddress: entry['wifiAddress']?.toString(),
      );
      await PendingMessageStore.instance.remove(messageId);
      await _store.markDelivered(widget.conversationId, messageId);
      if (mounted) {
        final refreshed = await _store.getMessages(widget.conversationId);
        setState(() => _messages = refreshed);
      }
    } catch (_) {
      // Keep it durable. A future app launch or explicit retry can try again.
    }
  }
}

Future<void> _retryRelayQueue() async {
  await MeshRuntimeService.instance.retryQueuedRelays();
}

Future<bool> _queueAndRelayIfNeeded(Map<dynamic, dynamic> decoded, String raw) async {
  final relay = decoded['relayEnabled'] == true || decoded['relay'] == true;
  if (!relay) return false;
  final id = decoded['id']?.toString() ?? decoded['messageId']?.toString() ?? '';
  final senderId = decoded['senderId']?.toString() ?? '';
  final recipientId = decoded['recipientId']?.toString() ?? '*';
  if (id.isEmpty || senderId.isEmpty || senderId == widget.currentUserId) return false;
  final created = DateTime.tryParse(decoded['sentAt']?.toString() ?? decoded['createdAt']?.toString() ?? '');
  if (created == null || DateTime.now().difference(created) > RelayQueueStore.maxAge || created.isAfter(DateTime.now().add(const Duration(minutes: 5)))) return false;
  final hops = int.tryParse('${decoded['hopCount'] ?? decoded['hops'] ?? 0}') ?? 0;
  if (hops < 0 || hops >= 5) return false;
  final path = decoded['relayPath'] is List ? List<String>.from((decoded['relayPath'] as List).map((e)=>e.toString())) : <String>[];
  if (path.contains(widget.currentUserId)) return false;
  final firstSeen = await RelayQueueStore.instance.markSeen(id);
  if (!firstSeen) return false;
  // The final recipient (or group recipient marker) processes the packet normally.
  if (recipientId == widget.currentUserId || recipientId == '*') {
    // Group packets are still relayed after local processing; the caller does not return early.
    if (recipientId == widget.currentUserId) return false;
  }
  final forwarded = Map<String,dynamic>.from(decoded.map((k,v)=>MapEntry(k.toString(),v)));
  forwarded['relayEnabled'] = true;
  forwarded['hopCount'] = hops + 1;
  forwarded['hops'] = hops + 1;
  forwarded['relayPath'] = [...path, widget.currentUserId];
  await RelayQueueStore.instance.enqueue(forwarded);
  // Try immediately; queue remains until TTL/limit so an intermediary never
  // mistakes a successful socket write for final recipient delivery.
  await _retryRelayQueue();
  return recipientId != '*' && recipientId != widget.currentUserId;
}

Future<void> _transmitWithRetry({
  required String payload,
  required String messageId,
  required bool wifiMode,
  required bool isCommunity,
  required String? bluetoothAddress,
  required String? wifiAddress,
}) async {
  final completer = Completer<void>();
  _pendingAcks[messageId] = completer;
  Object? lastError;
  var transportWriteSucceeded = false;
  try {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (wifiMode) {
          if (isCommunity) {
            await LocalNetworkService.instance.broadcastMessage(payload);
            transportWriteSucceeded = true;
            try { await WifiAwareService.instance.broadcastPacket(payload); } catch (_) {}
          } else {
            await LocalNetworkService.instance.sendMessageToPeer(address: wifiAddress!, payload: payload);
            transportWriteSucceeded = true;
          }
        } else if (isCommunity) {
          await _bluetooth.broadcastMessage(payload);
          transportWriteSucceeded = true;
          try { await WifiAwareService.instance.broadcastPacket(payload); } catch (_) {}
        } else {
          await _bluetooth.sendMessage(address: bluetoothAddress!, message: payload);
            transportWriteSucceeded = true;
        }
        await _store.markSent(widget.conversationId, messageId);
        if (mounted) {
          final refreshed = await _store.getMessages(widget.conversationId);
          setState(() => _messages = refreshed);
        }
      } catch (e) {
        lastError = e;
      }
      if (transportWriteSucceeded) await _store.markSent(widget.conversationId, messageId);
      // If a second path is configured, send the exact same message ID over it.
      // Receiver-side deduplication makes this safe when both paths arrive.
      try {
        if (wifiMode) {
          if (isCommunity) {
            await _bluetooth.broadcastMessage(payload);
            transportWriteSucceeded = true;
            try { await WifiAwareService.instance.broadcastPacket(payload); } catch (_) {}
          } else if (bluetoothAddress != null && bluetoothAddress.isNotEmpty) {
            await _bluetooth.sendMessage(address: bluetoothAddress, message: payload);
            transportWriteSucceeded = true;
          }
        } else {
          if (isCommunity) {
            await LocalNetworkService.instance.broadcastMessage(payload);
            try { await WifiAwareService.instance.broadcastPacket(payload); } catch (_) {}
          } else if (wifiAddress != null && wifiAddress.isNotEmpty) {
            await LocalNetworkService.instance.sendMessageToPeer(address: wifiAddress, payload: payload);
            transportWriteSucceeded = true;
          }
        }
      } catch (e) {
        lastError = e;
      }
      if (transportWriteSucceeded) await _store.markSent(widget.conversationId, messageId);
      try {
        await completer.future.timeout(const Duration(seconds: 4));
        return;
      } on TimeoutException {
        lastError ??= TimeoutException('لم يصل تأكيد استلام');
      }
    }
    throw StateError('لم يصل تأكيد استلام بعد 3 محاولات. آخر خطأ: $lastError');
  } finally {
    _pendingAcks.remove(messageId);
  }
}

Future<void> _handleIncomingMessage(
String raw,
String? address,
) async {
try {
dynamic decoded = jsonDecode(raw);

  if (decoded is! Map) return;
  var incomingType = decoded['type']?.toString() ?? '';
  String? ratchetPacketId;
  if (incomingType == 'blousab_pair_chain_message' && decoded['transferId'] != null) return;
  if (incomingType == 'file_chunk_end' || incomingType == 'file_chunk' || incomingType == 'file_chunk_missing') return;
  // File E2E envelopes are consumed by the app-scoped Mesh file receiver.
  if (incomingType == 'blousab_e2e_envelope' && decoded['transferId'] != null) return;
  // A returning end-to-end receipt proves that this relay's copy of the
  // original message is no longer needed. Remove it before forwarding the
  // receipt, including on intermediate devices that do not own the chat.
  if (incomingType == 'delivery_ack' || incomingType == 'read_ack') {
    final acknowledgedId = decoded['ackFor']?.toString() ?? '';
    if (acknowledgedId.isNotEmpty) {
      await RelayQueueStore.instance.remove(acknowledgedId);
    }
  }
  // mesh_route_advert packets are consumed by MeshRuntimeService, whose
  // Bluetooth/Wi-Fi subscriptions remain active across screen navigation.
  // Do not learn the same advertisement again from this screen listener.
  if (incomingType == 'mesh_route_advert') return;
  // Unicast relay packets are owned by MeshRuntimeService. Do not let an
  // intermediate device render another user's message or file chunk merely
  // because this conversation screen happens to be open.
  final relayRecipient = decoded['recipientId']?.toString() ?? '*';
  final relayEnabled = decoded['relayEnabled'] == true || decoded['relay'] == true;
  if (relayEnabled && relayRecipient != '*' && relayRecipient != widget.currentUserId) return;
  final shouldStopForRelay = await _queueAndRelayIfNeeded(decoded, raw);
  if (shouldStopForRelay) return;
  if (incomingType == 'blousab_ratchet_offer' || incomingType == 'blousab_ratchet_answer') {
    await _handleRatchetControl(Map.from(decoded), address);
    return;
  }
  if (incomingType == 'blousab_pair_chain_message') {
    final outerSender = decoded['senderId']?.toString() ?? '';
    final outerRecipient = decoded['recipientId']?.toString() ?? '';
    final outerId = decoded['id']?.toString() ?? '';
    if (outerRecipient != widget.currentUserId || outerSender.isEmpty ||
        outerSender != _peerIdFromConversation()) return;
    if (outerId.isNotEmpty && _ratchetPacketIds.contains(outerId)) {
      await _sendControlAck(outerId, widget.conversationId, address, outerSender);
      await _sendControlAck(outerId, widget.conversationId, address, outerSender, type: 'read_ack');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (outerId.isNotEmpty && (prefs.getBool('blousab_ratchet_seen_$outerId') ?? false)) {
      // MeshRuntimeService has already authenticated, decrypted and persisted
      // this packet while the app was running; the store stream refreshes UI.
      _ratchetPacketIds.add(outerId);
      final refreshed = await _store.getMessages(widget.conversationId);
      if (mounted) setState(() => _messages = refreshed);
      await _sendControlAck(outerId, widget.conversationId, address, outerSender, type: 'read_ack');
      return;
    }
    final clear = await PairwiseChainRatchetService.instance.decrypt(
      peerId: outerSender, packet: Map.from(decoded),
    );
    final inner = jsonDecode(clear);
    if (inner is! Map || inner['senderId']?.toString() != outerSender ||
        inner['recipientId']?.toString() != widget.currentUserId ||
        inner['id']?.toString() != decoded['id']?.toString() ||
        inner['conversationId']?.toString() != decoded['conversationId']?.toString()) return;
    decoded = inner;
    if (outerId.isNotEmpty) {
      _ratchetPacketIds.add(outerId);
      ratchetPacketId = outerId;
    }
    incomingType = decoded['type']?.toString() ?? '';
  }
  if (incomingType == 'blousab_e2e_envelope') {
    final outerPacketId = decoded['id']?.toString() ?? '';
    if (outerPacketId.isNotEmpty && _receivedIds.contains(outerPacketId)) return;
    final outerSender = decoded['senderId']?.toString() ?? '';
    final outerRecipient = decoded['recipientId']?.toString() ?? '';
    if (outerRecipient != widget.currentUserId || outerSender.isEmpty) return;
    final clear = await BlousabCryptoIdentity.instance.openE2ePayload(
      Map.from(decoded), localUserId: widget.currentUserId,
    );
    final inner = jsonDecode(clear);
    if (inner is! Map || inner['senderId']?.toString() != outerSender ||
        inner['recipientId']?.toString() != widget.currentUserId ||
        inner['id']?.toString() != decoded['id']?.toString() ||
        inner['conversationId']?.toString() != decoded['conversationId']?.toString()) return;
    decoded = inner;
    incomingType = decoded['type']?.toString() ?? '';
  }
  if (incomingType == 'blousab_group_e2e_envelope') {
    final groupId = decoded['groupId']?.toString() ?? '';
    final senderId = decoded['senderId']?.toString() ?? '';
    if (groupId != widget.conversationId || senderId.isEmpty ||
        decoded['recipientId']?.toString() != '*') return;
    final community = await _communityStore.findById(groupId);
    if (community == null) return;
    final approved = community.members.any((m) => m.id == senderId && m.status.name == 'approved');
    if (!approved) return;
    final clear = await GroupE2eCryptoService.instance.openGroupPayload(
      Map.from(decoded), localUserId: widget.currentUserId,
      isApprovedMember: (id) => community.members.any((m) => m.id == id && m.status.name == 'approved'),
    );
    final inner = jsonDecode(clear);
    if (inner is! Map || inner['senderId']?.toString() != senderId ||
        inner['conversationId']?.toString() != groupId || inner['id']?.toString() != decoded['id']?.toString()) return;
    decoded = inner;
    incomingType = decoded['type']?.toString() ?? '';
  }
  if (incomingType == 'delivery_ack' || incomingType == 'read_ack') {
    final ackFor = decoded['ackFor']?.toString() ?? '';
    // The original sender has now consumed this receipt; discard the receipt
    // packet itself as well as the original pending relay copy.
    final receiptPacketId = decoded['id']?.toString() ?? '';
    if (receiptPacketId.isNotEmpty) {
      await RelayQueueStore.instance.remove(receiptPacketId);
    }
    final recipientId = decoded['recipientId']?.toString() ?? '';
    final ackSender = decoded['senderId']?.toString() ?? '';
    final ackConversation = decoded['conversationId']?.toString() ?? '';
    final storedMessages = await _store.getMessages(widget.conversationId);
    final original = storedMessages.where((m) => m.id == ackFor && m.isMine && m.conversationId == widget.conversationId).toList();
    if (ackFor.isNotEmpty && recipientId == widget.currentUserId && ackConversation == widget.conversationId && ackSender.isNotEmpty && ackSender != widget.currentUserId && original.isNotEmpty) {
      if (incomingType == 'delivery_ack') {
        final pending = _pendingAcks[ackFor];
        if (pending != null && !pending.isCompleted) pending.complete();
        await _store.markDelivered(widget.conversationId, ackFor);
        await PendingMessageStore.instance.remove(ackFor);
      } else {
        await _store.markRead(widget.conversationId, ackFor);
      }
      if (mounted) {
        final refreshed = await _store.getMessages(widget.conversationId);
        setState(() => _messages = refreshed);
      }
    }
    return;
  }
  await _cachePeerProfile(decoded);
  if (incomingType == 'profile_card' || incomingType == 'profile_update' || incomingType == 'hello' || incomingType == 'hello_ack') return;

  final senderId = decoded['senderId']?.toString() ?? '';
  final senderName =
      decoded['senderName']?.toString() ?? 'مستخدم';
  final earlyMessageId = decoded['id']?.toString() ?? '';
  final earlyConversation = decoded['conversationId']?.toString() ?? '';
  if (earlyMessageId.isNotEmpty && _receivedIds.contains(earlyMessageId)) {
    await _sendControlAck(earlyMessageId, earlyConversation, address, senderId);
    await _sendControlAck(earlyMessageId, earlyConversation, address, senderId, type: 'read_ack');
    return;
  }
  final packetType = decoded['type']?.toString() ?? 'text';
  String text = decoded['text']?.toString() ?? '';
  String? attachmentPath;
  String? attachmentName;
  if (packetType == 'file') {
    attachmentName = decoded['fileName']?.toString() ?? 'ملف مستلم';
    final encoded = decoded['data']?.toString() ?? '';
    if (encoded.isEmpty || encoded.length > 6000000) return;
    final bytes = base64Decode(encoded);
    final dir = await getApplicationDocumentsDirectory();
    final safeName = attachmentName.replaceAll(RegExp(r'[^\w.\- ()\u0600-\u06FF]'), '_');
    final file = File('${dir.path}/received_${DateTime.now().millisecondsSinceEpoch}_$safeName');
    await file.writeAsBytes(bytes, flush: true);
    attachmentPath = file.path;
    text = '📎 $attachmentName';
  }
  final messageId = decoded['id']?.toString() ??
      '${DateTime.now().microsecondsSinceEpoch}_$senderId';

  final incomingConversation =
      decoded['conversationId']?.toString() ?? '';

  if ((text.trim().isEmpty && packetType != 'file') ||
      senderId.isEmpty ||
      senderId == widget.currentUserId) {
    return;
  }

  // تجاهل رسائل جهة الاتصال المحظورة على هذا الجهاز.
  final prefsForBlock = await SharedPreferences.getInstance();
  if (prefsForBlock.getBool('blousab_blocked_peer_$senderId') ?? false) return;

  // لا تعرض رسائل محادثة مختلفة في هذه المحادثة.
  if (incomingConversation.isNotEmpty &&
      incomingConversation != widget.conversationId) {
    return;
  }

  final localCommunity = await _communityStore.findById(widget.conversationId);
  if (localCommunity != null) {
    final sender = localCommunity.members.where((member) => member.id == senderId).toList();
    if (sender.isEmpty || sender.first.status.name != 'approved') return;
  }

  if (_receivedIds.contains(messageId)) { await _sendControlAck(messageId, widget.conversationId, address, senderId); await _sendControlAck(messageId, widget.conversationId, address, senderId, type: 'read_ack'); return; }

  final message = BlousabMessage(
    id: messageId,
    conversationId: widget.conversationId,
    senderId: senderId,
    senderName: senderName,
    text: text,
    sentAt: DateTime.tryParse(
          decoded['sentAt']?.toString() ?? '',
        )?.toLocal() ??
        DateTime.now(),
    isMine: false,
    attachmentPath: attachmentPath,
    attachmentName: attachmentName,
  );

  _receivedIds.add(messageId);

  await _store.saveMessage(message);
  if (ratchetPacketId != null) {
    final ratchetPrefs = await SharedPreferences.getInstance();
    await ratchetPrefs.setBool('blousab_ratchet_seen_$ratchetPacketId', true);
  }
  await _sendControlAck(message.id, message.conversationId, address, senderId);
  await _sendControlAck(message.id, message.conversationId, address, senderId, type: 'read_ack');

  if (!mounted) return;

  setState(() {
    if (!_messages.any((item) => item.id == message.id)) _messages.add(message);
    _selectedAddress ??= address;
  });

  _scrollToBottom();
} catch (_) {
  _showNotice('تعذر قراءة الرسالة المستلمة.');
}

}

Future<void> _prepareBluetooth() async {
  // لا نعرض نتائج فحص Bluetooth العامة؛ فهي لا تثبت أن الجهاز يشغّل بلوساب.
  // نافذة البحث المعتمدة تعرض فقط إعلانات خدمة بلوساب عبر Wi-Fi Aware
  // أو رسائل اكتشاف LAN التي يصدرها تطبيق بلوساب نفسه.
  await _changeConnectionFlow();
}

Future<void> _showDevicePicker() async {
if (!mounted) return;

final device = await showModalBottomSheet<BlousabDevice>(
  context: context,
  builder: (sheetContext) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _devices.isEmpty
            ? const Text(
                'لم يُعثر على أجهزة Bluetooth قريبة.\n'
                'تنبيه: هذه القائمة تعرض أجهزة بلوتوث عامة، ولا تثبت أن أصحابها يستخدمون بلوساب. استخدم بحث مستخدمي بلوساب عبر Wi-Fi للشبكة المحلية.',
                textAlign: TextAlign.center,
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  const Text(
                    'أجهزة Bluetooth القريبة (غير مؤكدة)',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ..._devices.map(
                    (d) => ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(d.name),
                      subtitle: const Text('جهاز Bluetooth — هوية بلوساب غير متحققة'),
                      onTap: () =>
                          Navigator.pop(sheetContext, d),
                    ),
                  ),
                ],
              ),
      ),
    );
  },
);

if (device == null || !mounted) return;

setState(() {
  _selectedAddress = device.address;
  _connectionStatus = 'جارٍ الاتصال بـ ${device.name}...';
});
final prefs = await SharedPreferences.getInstance();
await prefs.setString('blousab_last_device_${widget.conversationId}', device.address);

try {
  await _bluetooth.connect(device.address);
} on PlatformException catch (e) {
  if (mounted) {
    setState(() => _connectionStatus = 'فشل الاتصال');
  }
  _showNotice(e.message ?? 'تعذر الاتصال بالجهاز.');
} catch (_) {
  _showNotice('تعذر الاتصال بالجهاز.');
}

}

Future<void> _startListening() async {
if (_working) return;

setState(() => _working = true);

try {
  final supported = await _bluetooth.isSupported();

  if (!supported) {
    _showNotice('هذا الهاتف لا يدعم البلوتوث.');
    return;
  }

  final granted = await _bluetooth.requestPermissions();

  if (!granted) {
    _showNotice('امنح صلاحيات البلوتوث للتطبيق.');
    return;
  }

  if (!await _bluetooth.isEnabled()) {
    await _bluetooth.requestEnable();
    _showNotice('فعّل البلوتوث ثم حاول تشغيل الاستقبال.');
    return;
  }

  await _bluetooth.startServer();

  if (mounted) {
    setState(() {
      _connectionStatus = 'جارٍ تشغيل استقبال الرسائل...';
    });
  }
} on PlatformException catch (e) {
  _showNotice(e.message ?? 'تعذر تشغيل استقبال الرسائل.');
} catch (_) {
  _showNotice('حدث خطأ أثناء تشغيل الاستقبال.');
} finally {
  if (mounted) setState(() => _working = false);
}

}

Future<bool> _maySendToCurrentConversation() async {
  final community = await _communityStore.findById(widget.conversationId);
  if (community == null) return true;
  final member = community.members.where((item) => item.id == widget.currentUserId).toList();
  return member.isNotEmpty && member.first.status.name == 'approved';
}

Future<void> _broadcastGroupPayload(String payload) async {
  var sent = false;
  try {
    await _bluetooth.broadcastMessage(payload);
    sent = true;
  } catch (_) {}
  try {
    await LocalNetworkService.instance.broadcastMessage(payload);
    sent = true;
  } catch (_) {}
  try {
    await WifiAwareService.instance.broadcastPacket(payload);
    sent = true;
  } catch (_) {}
  if (!sent) {
    throw PlatformException(
      code: 'BROADCAST_FAILED',
      message: 'لا توجد أجهزة متصلة عبر البلوتوث أو الشبكة المحلية.',
    );
  }
}

Future<void> _sendRatchetControlPacket(Map<String, Object> packet, String peerId) async {
  final raw = jsonEncode(packet);
  var sent = false;
  final bluetooth = _selectedAddress;
  final wifi = _selectedWifiAddress;
  if (bluetooth != null && bluetooth.isNotEmpty) {
    try {
      await _bluetooth.sendMessage(address: bluetooth, message: raw);
      sent = true;
    } catch (_) {}
  }
  if (wifi != null && wifi.isNotEmpty) {
    try {
      await LocalNetworkService.instance.sendControlPacket(address: wifi, payload: raw);
      sent = true;
    } catch (_) {}
  }
  // Wi-Fi Aware is independent of the classic Bluetooth/LAN socket.
  try {
    await WifiAwareService.instance.sendPacket(peerId: peerId, payload: raw);
    sent = true;
  } catch (_) {}
  if (!sent) throw StateError('تعذر إرسال مصافحة التشفير؛ لا يوجد مسار نقل مباشر متاح.');
}

Future<void> _ensurePairwiseRatchetSession(String peerId) async {
  final ratchet = PairwiseChainRatchetService.instance;
  if (await ratchet.hasActiveSession(peerId)) return;
  final existing = _ratchetWaiters[peerId];
  if (existing != null) {
    await existing.future.timeout(const Duration(seconds: 25));
    if (!await ratchet.hasActiveSession(peerId)) throw StateError('لم تكتمل مصافحة التشفير مع الطرف الآخر.');
    return;
  }
  final waiter = Completer<void>();
  _ratchetWaiters[peerId] = waiter;
  try {
    final offer = await ratchet.createOffer(
      localUserId: widget.currentUserId,
      peerId: peerId,
      conversationId: widget.conversationId,
    );
    await _sendRatchetControlPacket(offer, peerId);
    await waiter.future.timeout(const Duration(seconds: 25));
    if (!await ratchet.hasActiveSession(peerId)) throw StateError('لم تُنشأ جلسة تشفير صالحة.');
  } finally {
    if (identical(_ratchetWaiters[peerId], waiter)) _ratchetWaiters.remove(peerId);
  }
}

Future<void> _handleRatchetControl(Map packet, String? address) async {
  final peerId = packet['senderId']?.toString() ?? '';
  final recipient = packet['recipientId']?.toString() ?? '';
  final conversation = packet['conversationId']?.toString() ?? '';
  if (peerId.isEmpty || recipient != widget.currentUserId ||
      (conversation.isNotEmpty && conversation != widget.conversationId)) return;
  final trusted = await BlousabCryptoIdentity.instance.trustedPeerE2ePublicKey(peerId);
  if (trusted == null) return;
  if (packet['type'] == 'blousab_ratchet_answer' &&
      await PairwiseChainRatchetService.instance.hasActiveSession(peerId)) {
    final waiter = _ratchetWaiters[peerId];
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    return;
  }
  final response = await PairwiseChainRatchetService.instance.handleHandshakePacket(
    packet: packet, localUserId: widget.currentUserId,
  );
  if (response != null) {
    var sent = false;
    if (address != null && address.isNotEmpty) {
      if (address.startsWith('lan:')) {
        try { await LocalNetworkService.instance.sendControlPacket(address: address, payload: jsonEncode(response)); sent = true; } catch (_) {}
      } else {
        try { await _bluetooth.sendMessage(address: address, message: jsonEncode(response)); sent = true; } catch (_) {}
      }
    }
    if (!sent) await _sendRatchetControlPacket(response, peerId);
    final waiter = _ratchetWaiters[peerId];
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  } else if (packet['type'] == 'blousab_ratchet_answer') {
    final waiter = _ratchetWaiters[peerId];
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }
}

Future<String> _sealDirectE2ePacket(String raw, String recipientId) async {
  final trustedKey = await BlousabCryptoIdentity.instance.trustedPeerE2ePublicKey(recipientId);
  if (trustedKey == null) {
    throw StateError('يلزم توثيق المستخدم عبر QR ومقارنة بصمة الهوية قبل إرسال رسالة أو ملف مشفر.');
  }
  await _ensurePairwiseRatchetSession(recipientId);
  final decoded = jsonDecode(raw);
  if (decoded is! Map) throw const FormatException('حزمة التطبيق غير صالحة');
  final packet = Map<String, dynamic>.from(decoded.map((k, v) => MapEntry(k.toString(), v)));
  final routing = <String, Object?>{};
  for (final key in const ['id','conversationId','sentAt','createdAt','relay','relayEnabled','hopCount','hops','relayPath','transferId','index','chunkCount','totalBytes','checksum']) {
    routing[key] = packet[key];
  }
  final envelope = await PairwiseChainRatchetService.instance.encrypt(
    peerId: recipientId, plaintext: raw, routingFields: routing,
  );
  return jsonEncode(envelope);
}

Future<void> _sendMessage() async {
final text = _textController.text.trim();

if (text.isEmpty || _sending) return;
if (!await _maySendToCurrentConversation()) {
  _showNotice('لا يمكنك الإرسال لأن عضويتك غير مقبولة أو محظورة.');
  return;
}

final isCommunity = await _communityStore.findById(widget.conversationId) != null;
final prefs = await SharedPreferences.getInstance();
final wifiMode = prefs.getString('blousab_connection_mode') == 'wifi';
final address = _selectedAddress;
final wifiAddress = _selectedWifiAddress;

if (!isCommunity && wifiMode && (wifiAddress == null || wifiAddress.isEmpty)) {
  _showNotice('اختر جهازًا من قائمة أجهزة Wi-Fi أولًا.');
  return;
}
if (!isCommunity && !wifiMode && (address == null || address.isEmpty)) {
  _showNotice('اتصل بهاتف مقترن أولًا لإرسال الرسائل.');
  return;
}
if (!isCommunity) {
  final recipientId = _peerIdFromConversation();
  if (recipientId == null || await BlousabCryptoIdentity.instance.trustedPeerE2ePublicKey(recipientId) == null) {
    _showNotice('وثّق المستخدم عبر QR وقارن بصمة الهوية أولاً لإرسال رسالة مشفرة.');
    return;
  }
}

setState(() => _sending = true);

final message = BlousabMessage(
  id: '${DateTime.now().microsecondsSinceEpoch}_${widget.currentUserId}',
  conversationId: widget.conversationId,
  senderId: widget.currentUserId,
  senderName: widget.currentUserName,
  text: text,
  sentAt: DateTime.now(),
  isMine: true,
  deliveryStatus: 'pending',
);

try {
  final senderPhoto = await _profilePhotoPayload();
  final payload = jsonEncode({
    'type': 'chat',
    'hops': 0,
    'hopCount': 0,
    'relay': true,
    'relayEnabled': isCommunity || _peerIdFromConversation() != null,
    'relayPath': <String>[],
    'recipientId': isCommunity ? '*' : (_peerIdFromConversation() ?? ''),
    'id': message.id,
    'conversationId': message.conversationId,
    'senderId': message.senderId,
    'senderName': message.senderName,
    if (senderPhoto != null) 'senderPhoto': senderPhoto,
    'text': message.text,
    'sentAt': message.sentAt.toIso8601String(),
    'createdAt': message.sentAt.toIso8601String(),
  });
  var outgoingPayload = payload;
  if (isCommunity) {
    final groupEnvelope = await GroupE2eCryptoService.instance.sealGroupPayload(
      groupId: widget.conversationId, senderId: widget.currentUserId,
      payload: payload, messageId: message.id,
      routingFields: <String, Object?>{'conversationId': widget.conversationId,
        'sentAt': message.sentAt.toIso8601String(), 'relay': true, 'relayEnabled': true,
        'hopCount': 0, 'hops': 0, 'relayPath': <String>[]},
    );
    outgoingPayload = jsonEncode(groupEnvelope);
  } else {
    final recipientId = _peerIdFromConversation();
    if (recipientId == null || recipientId.isEmpty) {
      throw StateError('تعذر تحديد هوية المستلم لتشفير الرسالة.');
    }
    outgoingPayload = await _sealDirectE2ePacket(payload, recipientId);
  }

  await _store.saveMessage(message);
  await PendingMessageStore.instance.enqueue({
    'messageId': message.id, 'conversationId': message.conversationId,
    'payload': outgoingPayload, 'wifiMode': wifiMode, 'isCommunity': isCommunity,
    'bluetoothAddress': address, 'wifiAddress': wifiAddress,
  });
  await _transmitWithRetry(payload: outgoingPayload, messageId: message.id,
    wifiMode: wifiMode, isCommunity: isCommunity,
    bluetoothAddress: address, wifiAddress: wifiAddress);

  if (widget.onSendMessage != null) {
    await widget.onSendMessage!(message);
  }

  if (!mounted) return;

  _receivedIds.add(message.id);
  final refreshedMessages = await _store.getMessages(widget.conversationId);
  setState(() { _messages = refreshedMessages; _textController.clear(); });

  _scrollToBottom();
  if (_vibrateOnSend) HapticFeedback.lightImpact();
} on PlatformException catch (e) {
  if (mounted) { final refreshed = await _store.getMessages(widget.conversationId); setState(() { _messages = refreshed; _textController.clear(); }); }
  _showNotice(e.message ?? 'حُفظت الرسالة محليًا لكن لم يتأكد استلامها.');
} catch (e) {
  if (mounted) { final refreshed = await _store.getMessages(widget.conversationId); setState(() { _messages = refreshed; _textController.clear(); }); }
  _showNotice('حُفظت الرسالة محليًا، لكن لم يصل تأكيد الاستلام. $e');
} finally {
  if (mounted) setState(() => _sending = false);
}

}

int _fileCrc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? ((crc >> 1) ^ 0xEDB88320) : (crc >> 1);
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

Future<void> _sendFileChunks({required Uint8List bytes, required String transferId,
  required String fileName, required String senderPhoto, required String recipientId,
  required bool relayEnabled, required bool isCommunity, required bool wifiMode,
  required String? bluetoothAddress, required String? wifiAddress,
  required DateTime sentAt}) async {
  final count = (bytes.length / _fileChunkBytes).ceil();
  final checksum = _fileCrc32(bytes);
  final ack = Completer<void>();
  _pendingAcks[transferId] = ack;
  try {
    for (var index = 0; index < count; index++) {
      final start = index * _fileChunkBytes;
      final end = (start + _fileChunkBytes).clamp(0, bytes.length).toInt();
      final clearPacket = jsonEncode({
        'type': 'file_chunk', 'id': '${transferId}_part_$index',
        'transferId': transferId, 'index': index, 'chunkCount': count,
        'totalBytes': bytes.length, 'checksum': checksum, 'fileName': fileName,
        'conversationId': widget.conversationId, 'senderId': widget.currentUserId,
        'senderName': widget.currentUserName, if (senderPhoto.isNotEmpty) 'senderPhoto': senderPhoto,
        'recipientId': recipientId, 'relay': relayEnabled, 'relayEnabled': relayEnabled,
        'hopCount': 0, 'hops': 0, 'relayPath': <String>[],
        'sentAt': sentAt.toIso8601String(), 'createdAt': sentAt.toIso8601String(),
        'data': base64Encode(bytes.sublist(start, end)),
      });
      final packet = isCommunity
          ? jsonEncode(await GroupE2eCryptoService.instance.sealGroupPayload(
              groupId: widget.conversationId, senderId: widget.currentUserId,
              payload: clearPacket, messageId: '${transferId}_part_$index',
              routingFields: <String, Object?>{'conversationId': widget.conversationId,
                'transferId': transferId, 'index': index, 'chunkCount': count,
                'totalBytes': bytes.length, 'checksum': checksum,
                'relay': relayEnabled, 'relayEnabled': relayEnabled,
                'hopCount': 0, 'hops': 0, 'relayPath': <String>[]},
            ))
          : await _sealDirectE2ePacket(clearPacket, recipientId);
      Object? lastError;
      var deliveredToTransport = false;
      for (var attempt = 0; attempt < 2 && !deliveredToTransport; attempt++) {
        try {
          if (wifiMode) {
            if (isCommunity) {
              await LocalNetworkService.instance.broadcastMessage(packet);
              try { await WifiAwareService.instance.broadcastPacket(packet); } catch (_) {}
            }
            else if (wifiAddress != null && wifiAddress.isNotEmpty) { await LocalNetworkService.instance.sendMessageToPeer(address: wifiAddress, payload: packet); }
            else { throw StateError('لا يوجد مسار Wi-Fi متاح'); }
          } else {
            if (isCommunity) {
              await _bluetooth.broadcastMessage(packet);
              try { await WifiAwareService.instance.broadcastPacket(packet); } catch (_) {}
            }
            else if (bluetoothAddress != null && bluetoothAddress.isNotEmpty) { await _bluetooth.sendMessage(address: bluetoothAddress, message: packet); }
            else { throw StateError('لا يوجد مسار Bluetooth متاح'); }
          }
          deliveredToTransport = true;
        } catch (e) { lastError = e; }
      }
      if (!deliveredToTransport) throw StateError('تعذر إرسال الجزء ${index + 1}: $lastError');
      // Use the second available transport as opportunistic redundancy. Every
      // chunk has a unique packet ID, so relay de-duplication stays per chunk.
      try {
        if (wifiMode && bluetoothAddress != null && bluetoothAddress.isNotEmpty) {
          if (isCommunity) {
            await _bluetooth.broadcastMessage(packet);
            try { await WifiAwareService.instance.broadcastPacket(packet); } catch (_) {}
          }
          else { await _bluetooth.sendMessage(address: bluetoothAddress, message: packet); }
        } else if (!wifiMode && wifiAddress != null && wifiAddress.isNotEmpty) {
          if (isCommunity) {
            await LocalNetworkService.instance.broadcastMessage(packet);
            try { await WifiAwareService.instance.broadcastPacket(packet); } catch (_) {}
          }
          else { await LocalNetworkService.instance.sendMessageToPeer(address: wifiAddress, payload: packet); }
        }
      } catch (_) {}
    }
    final clearEndPacket = jsonEncode({'type':'file_chunk_end','id':'${transferId}_end','transferId':transferId,'chunkCount':count,'totalBytes':bytes.length,'checksum':checksum,'fileName':fileName,'senderName':widget.currentUserName,'conversationId':widget.conversationId,'senderId':widget.currentUserId,'recipientId':recipientId,'relay':relayEnabled,'relayEnabled':relayEnabled,'hopCount':0,'hops':0,'relayPath':<String>[],'sentAt':sentAt.toIso8601String(),'createdAt':sentAt.toIso8601String()});
    final endPacket = isCommunity
        ? jsonEncode(await GroupE2eCryptoService.instance.sealGroupPayload(
            groupId: widget.conversationId, senderId: widget.currentUserId,
            payload: clearEndPacket, messageId: '${transferId}_end',
            routingFields: <String, Object?>{'conversationId': widget.conversationId,
              'transferId': transferId, 'chunkCount': count, 'totalBytes': bytes.length,
              'checksum': checksum, 'relay': relayEnabled, 'relayEnabled': relayEnabled,
              'hopCount': 0, 'hops': 0, 'relayPath': <String>[]},
          ))
        : await _sealDirectE2ePacket(clearEndPacket, recipientId);
    try {
      if (isCommunity) {
        await _broadcastGroupPayload(endPacket);
      } else if (wifiMode && wifiAddress != null && wifiAddress.isNotEmpty) {
        await LocalNetworkService.instance.sendMessageToPeer(address: wifiAddress, payload: endPacket);
      } else if (bluetoothAddress != null && bluetoothAddress.isNotEmpty) {
        await _bluetooth.sendMessage(address: bluetoothAddress, message: endPacket);
      }
    } catch (_) {}
    await ack.future.timeout(const Duration(seconds: 20));
  } finally { _pendingAcks.remove(transferId); }
}

Future<void> _sendFile() async {
  if (_sending) return;
  if (!await _maySendToCurrentConversation()) {
    _showNotice('لا يمكنك إرسال الملفات لأن عضويتك غير مقبولة أو محظورة.');
    return;
  }
  final isCommunity = await _communityStore.findById(widget.conversationId) != null;
  final prefs = await SharedPreferences.getInstance();
  final wifiMode = prefs.getString('blousab_connection_mode') == 'wifi';
  final address = _selectedAddress;
  final wifiAddress = _selectedWifiAddress;
  if (!isCommunity && wifiMode && (wifiAddress == null || wifiAddress.isEmpty)) {
    _showNotice('اختر جهازًا من قائمة أجهزة Wi-Fi أولًا لإرسال الملف.');
    return;
  }
  if (!isCommunity && !wifiMode && (address == null || address.isEmpty)) {
    _showNotice('اتصل بجهاز مقترن أولًا لإرسال ملف.');
    return;
  }
  final directRecipient = isCommunity ? null : _peerIdFromConversation();
  if (!isCommunity && (directRecipient == null ||
      await BlousabCryptoIdentity.instance.trustedPeerE2ePublicKey(directRecipient) == null)) {
    _showNotice('وثّق المستخدم عبر QR وقارن بصمة الهوية أولاً لتفعيل تشفير الملفات.');
    return;
  }
  try {
    final result = await FilePicker.platform.pickFiles(withData: true, allowMultiple: false);
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    final bytes = picked.bytes ?? (picked.path != null ? await File(picked.path!).readAsBytes() : null);
    if (bytes == null || bytes.isEmpty) {
      _showNotice('تعذر قراءة الملف المحدد.');
      return;
    }
    if (bytes.length > _maxChatFileBytes) {
      _showNotice('حجم الملف أكبر من 4 ميغابايت حاليًا.');
      return;
    }
    setState(() => _sending = true);
    final id = '${DateTime.now().microsecondsSinceEpoch}_${widget.currentUserId}';
    final dir = await getApplicationDocumentsDirectory();
    final safeName = picked.name.replaceAll(RegExp(r'[^\w.\- ()\u0600-\u06FF]'), '_');
    final localFile = File('${dir.path}/sent_${DateTime.now().millisecondsSinceEpoch}_$safeName');
    await localFile.writeAsBytes(bytes, flush: true);
    final message = BlousabMessage(
      id: id,
      conversationId: widget.conversationId,
      senderId: widget.currentUserId,
      senderName: widget.currentUserName,
      text: '📎 ${picked.name}',
      sentAt: DateTime.now(),
      isMine: true,
      deliveryStatus: 'pending',
      attachmentPath: localFile.path,
      attachmentName: picked.name,
    );
    final peerId = _peerIdFromConversation();
    final payload = jsonEncode({
      'type': 'file', 'id': id, 'conversationId': message.conversationId,
      'senderId': message.senderId, 'senderName': message.senderName,
      'recipientId': isCommunity ? '*' : (peerId ?? ''),
      'relay': isCommunity || peerId != null, 'relayEnabled': isCommunity || peerId != null,
      'hopCount': 0, 'hops': 0, 'relayPath': <String>[],
      'sentAt': message.sentAt.toIso8601String(), 'createdAt': message.sentAt.toIso8601String(),
      'fileName': picked.name, 'data': '',
    });
    await _store.saveMessage(message);
    await PendingMessageStore.instance.enqueue({
      'messageId': id, 'conversationId': message.conversationId,
      'payload': payload, 'kind': 'file_chunk_transfer', 'localPath': localFile.path,
      'fileName': picked.name, 'wifiMode': wifiMode, 'isCommunity': isCommunity,
      'bluetoothAddress': address, 'wifiAddress': wifiAddress,
    });
    final photo = await _profilePhotoPayload();
    await _sendFileChunks(bytes: Uint8List.fromList(bytes), transferId: id,
      fileName: picked.name, senderPhoto: photo ?? '', recipientId: isCommunity ? '*' : (peerId ?? ''),
      relayEnabled: isCommunity || peerId != null, isCommunity: isCommunity,
      wifiMode: wifiMode, bluetoothAddress: address, wifiAddress: wifiAddress,
      sentAt: message.sentAt);
    // Keep the source file and transfer metadata in the durable outbox until
    // an end-to-end delivery acknowledgement retires it. MeshRuntimeService
    // needs this copy to resend only chunks requested after a reconnect.
    if (!mounted) return;
    _receivedIds.add(id);
    final refreshedMessages = await _store.getMessages(widget.conversationId);
    setState(() => _messages = refreshedMessages);
    _scrollToBottom();
    _showNotice('تم إرسال الملف عبر البلوتوث.');
  } on PlatformException catch (e) {
    _showNotice(e.message ?? 'تعذر إرسال الملف.');
  } catch (e) {
    _showNotice('تعذر إرسال الملف: $e');
  } finally {
    if (mounted) setState(() => _sending = false);
  }
}

Future<void> _openAttachment(BlousabMessage message) async {
  final path = message.attachmentPath;
  if (path == null || !File(path).existsSync()) {
    _showNotice('الملف غير موجود على هذا الجهاز.');
    return;
  }
  final result = await OpenFilex.open(path);
  if (result.type != ResultType.done) _showNotice('تعذر فتح الملف: ${result.message}');
}

void _scrollToBottom() {
WidgetsBinding.instance.addPostFrameCallback((_) {
  if (!_scrollController.hasClients) return;

  _scrollController.animateTo(
    _scrollController.position.maxScrollExtent,
    duration: const Duration(milliseconds: 250),
    curve: Curves.easeOut,
  );
});

}

void _showNotice(String text) {
if (!mounted) return;

ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(text)));

}

@override
void dispose() {
for (final waiter in _ratchetWaiters.values) {
  if (!waiter.isCompleted) waiter.completeError(StateError('أُغلقت شاشة المحادثة قبل اكتمال المصافحة.'));
}
_ratchetWaiters.clear();
if (NotificationService.activeConversationId == widget.conversationId) {
  NotificationService.activeConversationId = null;
}
_subscription?.cancel();
_messageStoreSubscription?.cancel();
_lanSubscription?.cancel();
_awareProfileSubscription?.cancel();
_bluetoothIdentitySubscription?.cancel();
_relayRetryTimer?.cancel();
_textController.dispose();
_scrollController.dispose();
super.dispose();
}

@override
Widget build(BuildContext context) {
final isDarkTheme = Theme.of(context).brightness == Brightness.dark;
return Scaffold(
backgroundColor: _chatWallpaper == 'dark' ? const Color(0xFF172321) : _chatWallpaper == 'plain' ? (isDarkTheme ? const Color(0xFF101414) : Colors.white) : (isDarkTheme ? const Color(0xFF131D1B) : const Color(0xFFEAF7F3)),
appBar: AppBar(
leadingWidth: 56,
leading: Padding(
  padding: const EdgeInsetsDirectional.only(start: 8),
  child: CircleAvatar(
    radius: 22,
    backgroundImage: _peerProfilePhotoPath.isNotEmpty && File(_peerProfilePhotoPath).existsSync() ? FileImage(File(_peerProfilePhotoPath)) : null,
    child: _peerProfilePhotoPath.isEmpty || !File(_peerProfilePhotoPath).existsSync() ? const Icon(Icons.person_outline) : null,
  ),
),
title: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
Text(_peerDisplayName.isNotEmpty ? _peerDisplayName : widget.title),
Text(
_connectionStatus,
style: const TextStyle(fontSize: 12),
),
],
),
actions: [
IconButton(tooltip: 'إعدادات المحادثة', onPressed: _openConversationSettings, icon: const Icon(Icons.tune)),
IconButton(
  tooltip: 'مكالمة فيديو',
  onPressed: () => _showNotice('مكالمات الفيديو تحتاج إلى تنفيذ قناة صوت وصورة واختبارها بين هاتفين. الزر لا يبدأ بثًا حيًا في هذه النسخة.'),
  icon: const Icon(Icons.videocam_outlined),
),
IconButton(
tooltip: 'تشغيل استقبال الرسائل',
onPressed: _working ? null : _startListening,
icon: Icon(_connectionMode == 'wifi' ? Icons.wifi : Icons.bluetooth_searching),
),
IconButton(
tooltip: 'الاتصال بجهاز مقترن',
onPressed: _working ? null : _prepareBluetooth,
icon: Icon(_connectionMode == 'wifi' ? Icons.wifi : Icons.bluetooth_connected),
),
],
),
body: Column(
children: [
Expanded(
child: _loading
? const Center(child: CircularProgressIndicator())
: _messages.isEmpty
? const Center(
child: Text('لا توجد رسائل بعد. ابدأ المحادثة.'),
)
: ListView.builder(
controller: _scrollController,
padding: const EdgeInsets.all(12),
itemCount: _messages.length,
itemBuilder: (context, index) {
final message = _messages[index];
final mine = message.isMine;

                      return Align(
                        alignment: mine
                            ? AlignmentDirectional.centerEnd
                            : AlignmentDirectional.centerStart,
                        child: Container(
                          constraints: BoxConstraints(
                            maxWidth:
                                MediaQuery.of(context).size.width * 0.8,
                          ),
                          margin: const EdgeInsets.symmetric(
                            vertical: 4,
                          ),
                          padding: EdgeInsets.all(_compactBubbles ? 8 : 12),
                          decoration: BoxDecoration(
                            color: mine
                                ? Theme.of(context)
                                    .colorScheme
                                    .primaryContainer
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              if (!mine && _isCommunityConversation)
                                Padding(
                                  padding:
                                      const EdgeInsets.only(bottom: 4),
                                  child: Text(
                                    message.senderName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              if (message.attachmentPath != null &&
                                  RegExp(r'.*\.(png|jpe?g|gif|webp|bmp)$', caseSensitive: false).hasMatch(message.attachmentName ?? ''))
                                GestureDetector(
                                  onTap: () => _openAttachment(message),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.file(File(message.attachmentPath!), width: 220, fit: BoxFit.contain,
                                      errorBuilder: (_, __, ___) => Text(message.attachmentName ?? 'صورة')),
                                  ),
                                )
                              else if (message.attachmentPath != null)
                                InkWell(
                                  onTap: () => _openAttachment(message),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    const Icon(Icons.attach_file),
                                    const SizedBox(width: 6),
                                    Flexible(child: Text(message.attachmentName ?? message.text)),
                                    const SizedBox(width: 6),
                                    const Icon(Icons.open_in_new, size: 16),
                                  ]),
                                )
                              else Text(message.text, style: TextStyle(fontSize: _messageFontSize)),
                              if (_showMessageTime) const SizedBox(height: 4),
                              if (_showMessageTime) Text(
                                '${message.sentAt.toLocal().hour.toString().padLeft(2, '0')}:'
                                '${message.sentAt.toLocal().minute.toString().padLeft(2, '0')}',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall,
                              ),
                              if (message.isMine) Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(message.isRead ? '✓✓' : (message.isDelivered ? '✓✓' : (message.isSent ? '✓' : '◷')),
                                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                      color: message.isRead ? Colors.blue : (message.isDelivered || message.isSent ? Colors.grey : Theme.of(context).colorScheme.onSurfaceVariant),
                                      fontWeight: FontWeight.w700)),
                                  const SizedBox(width: 4),
                                  Text(message.isRead ? 'مقروءة' : (message.isDelivered ? 'تم الاستلام' : (message.isSent ? 'تم الإرسال · بانتظار الاستلام' : 'بانتظار الإرسال')),
                                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                      color: message.isRead ? Colors.blue : (message.isDelivered ? Colors.grey : Theme.of(context).colorScheme.onSurfaceVariant))),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: 'إرسال ملف أو صورة',
                onPressed: _sending ? null : _sendFile,
                icon: const Icon(Icons.attach_file),
              ),
              Expanded(
                child: TextField(
                  controller: _textController,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendMessage(),
                  decoration: const InputDecoration(
                    hintText: 'اكتب رسالتك...',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'إرسال',
                onPressed: _sending ? null : _sendMessage,
                icon: _sending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ),
    ],
  ),
);

}
}