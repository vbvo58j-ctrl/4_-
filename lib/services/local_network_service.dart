import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:cryptography/cryptography.dart';

import 'bluetooth_classic_service.dart';
import 'blousab_crypto_identity.dart';

/// Local Wi-Fi/LAN transport. It discovers peers on the same broadcast
/// domain and transfers newline-delimited JSON packets over TCP.
/// This is a transport path, not an Internet relay or end-to-end encryption.
class LocalNetworkService {
  LocalNetworkService._();
  static final LocalNetworkService instance = LocalNetworkService._();

  static const int _discoveryPort = 39772;
  static const int _tcpPort = 39771;
  // Hard cap for newline-delimited JSON frames. Disconnect oversized peers
  // before buffering unbounded input in LineSplitter.
  static const int maxFrameBytes = 1024 * 1024;
  final StreamController<BlousabEvent> _events =
      StreamController<BlousabEvent>.broadcast();
  final Map<String, _LanPeer> _peers = <String, _LanPeer>{};
  final Set<String> _verifiedPeerIds = <String>{};
  final Set<String> _verifyingPeerIds = <String>{};

  RawDatagramSocket? _udp;
  ServerSocket? _server;
  Timer? _discoveryTimer;
  String _userId = '';
  String _userName = 'مستخدم بلوساب';
  bool _running = false;
  String? _profilePhotoBase64;

  Stream<BlousabEvent> get events => _events.stream;
  bool get isRunning => _running;
  // Only peers that completed the Blousab TCP handshake are exposed to UI
  // and app-level routing. UDP announcements are untrusted candidates only.
  int get peerCount => _verifiedPeerIds.length;
  List<Map<String, String>> get discoveredPeers => _peers.values
      .where((p) => _verifiedPeerIds.contains(p.id))
      .map((p) => <String, String>{
    'id': p.id, 'name': p.name, 'address': p.address,
    if (p.photoBase64 != null && p.photoBase64!.isNotEmpty) 'photo': p.photoBase64!,
  }).toList(growable: false);

  Future<void> start({required String userId, required String userName}) async {
    _userId = userId;
    _userName = userName;
    await BlousabCryptoIdentity.instance.initialize();
    await _loadProfilePhoto();
    if (_running) {
      _sendDiscovery();
      return;
    }
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, _tcpPort,
          shared: true);
      _server!.listen(_acceptClient, onError: (Object error) {
        _emitError('تعذر استقبال اتصال الشبكة المحلية: $error');
      });
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4,
          _discoveryPort,
          reuseAddress: true, reusePort: true);
      _udp!.broadcastEnabled = true;
      _udp!.listen(_onUdpEvent, onError: (Object error) {
        _emitError('تعذر اكتشاف أجهزة الشبكة المحلية: $error');
      });
      _running = true;
      _sendDiscovery();
      _discoveryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _sendDiscovery();
        _prunePeers();
      });
      _events.add(const BlousabEvent(type: 'lanStarted'));
    } catch (e) {
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    _running = false;
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _udp?.close();
    _udp = null;
    await _server?.close();
    _server = null;
    _peers.clear();
    _verifiedPeerIds.clear();
    _verifyingPeerIds.clear();
    _events.add(const BlousabEvent(type: 'lanStopped'));
  }

  Future<void> _loadProfilePhoto() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final path = prefs.getString('wasl_profile_photo') ?? '';
      if (path.isEmpty) { _profilePhotoBase64 = null; return; }
      final file = File(path);
      if (!await file.exists()) { _profilePhotoBase64 = null; return; }
      final bytes = await file.readAsBytes();
      // Keep UDP discovery packets small to avoid IP fragmentation.
      _profilePhotoBase64 = bytes.isNotEmpty && bytes.length <= 20 * 1024
          ? base64Encode(bytes) : null;
    } catch (_) {
      _profilePhotoBase64 = null;
    }
  }

  void _sendDiscovery() {
    final udp = _udp;
    if (!_running || udp == null) return;
    final bytes = utf8.encode(jsonEncode({
      'kind': 'blousab_discovery',
      'peerId': _userId,
      'name': _userName,
      'photo': _profilePhotoBase64,
      'port': _tcpPort,
    }));
    try {
      udp.send(bytes, InternetAddress('255.255.255.255'), _discoveryPort);
    } catch (_) {}
  }

  void _onUdpEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final udp = _udp;
    if (udp == null) return;
    Datagram? datagram;
    while ((datagram = udp.receive()) != null) {
      try {
        final packet = jsonDecode(utf8.decode(datagram!.data));
        if (packet is! Map || packet['peerId']?.toString() == _userId) continue;
        final kind = packet['kind']?.toString();
        final address = datagram!.address.address;
        if (kind == 'blousab_discovery') {
          final peerId = packet['peerId']?.toString() ?? '';
          if (peerId.isEmpty) continue;
          final previous = _peers[peerId];
          // A peer ID appearing from a different IP must pass verification
          // again; never carry trust across an address change.
          if (previous != null && previous.address != address) {
            _verifiedPeerIds.remove(peerId);
            _verifyingPeerIds.remove(peerId);
          }
          _peers[peerId] = _LanPeer(
            id: peerId,
            name: packet['name']?.toString() ?? 'جهاز على الشبكة',
            address: address,
            photoBase64: packet['photo']?.toString(),
            lastSeen: DateTime.now(),
          );
          if (!_verifiedPeerIds.contains(peerId)) unawaited(_verifyLanPeer(peerId, address));
          final reply = utf8.encode(jsonEncode({
            'kind': 'blousab_peer',
            'peerId': _userId,
            'name': _userName,
            'photo': _profilePhotoBase64,
            'port': _tcpPort,
          }));
          udp.send(reply, datagram!.address, _discoveryPort);
        } else if (kind == 'blousab_peer') {
          final peerId = packet['peerId']?.toString() ?? '';
          if (peerId.isEmpty) continue;
          final previous = _peers[peerId];
          // A peer ID appearing from a different IP must pass verification
          // again; never carry trust across an address change.
          if (previous != null && previous.address != address) {
            _verifiedPeerIds.remove(peerId);
            _verifyingPeerIds.remove(peerId);
          }
          _peers[peerId] = _LanPeer(
            id: peerId,
            name: packet['name']?.toString() ?? 'جهاز على الشبكة',
            address: address,
            photoBase64: packet['photo']?.toString(),
            lastSeen: DateTime.now(),
          );
          if (!_verifiedPeerIds.contains(peerId)) unawaited(_verifyLanPeer(peerId, address));
        }
      } catch (_) {}
    }
  }

  String _helloTranscript(String senderId, String recipientId, String nonce,
          String identityPublicKey, String ephemeralPublicKey) =>
      'hello|blousab-lan-v2|$senderId|$recipientId|$nonce|$identityPublicKey|$ephemeralPublicKey';

  String _ackTranscript(String senderId, String recipientId, String nonce,
          String senderIdentityKey, String recipientIdentityKey,
          String senderEphemeralKey, String recipientEphemeralKey) =>
      'ack|blousab-lan-v2|$senderId|$recipientId|$nonce|$senderIdentityKey|$recipientIdentityKey|$senderEphemeralKey|$recipientEphemeralKey';

  Future<SecretKey> _deriveLanSessionKey({
    required KeyPair localEphemeralKeyPair,
    required String remoteEphemeralPublicKey,
    required String nonce,
    required String senderId,
    required String recipientId,
  }) async {
    final remote = SimplePublicKey(base64Decode(remoteEphemeralPublicKey),
        type: KeyPairType.x25519);
    final shared = await X25519().sharedSecretKey(
        keyPair: localEphemeralKeyPair, remotePublicKey: remote);
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: base64Url.decode(base64Url.normalize(nonce)),
      info: utf8.encode('blousab-lan-session-v2|$senderId|$recipientId'),
    );
  }

  Future<String> _encryptLanFrame(String payload, SecretKey key) async {
    final nonce = List<int>.generate(12, (_) => Random.secure().nextInt(256));
    final box = await AesGcm.with256bits().encrypt(utf8.encode(payload),
        secretKey: key, nonce: nonce,
        aad: utf8.encode('blousab-lan-frame-v2'));
    return jsonEncode({
      'type': 'blousab_lan_secure_frame',
      'nonce': base64Encode(box.nonce),
      'cipherText': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
  }

  Future<String> _decryptLanFrame(String frame, SecretKey key) async {
    final value = jsonDecode(frame);
    if (value is! Map || value['type'] != 'blousab_lan_secure_frame') {
      throw const FormatException('إطار LAN غير مشفّر أو غير صالح');
    }
    final box = SecretBox(
      base64Decode(value['cipherText']?.toString() ?? ''),
      nonce: base64Decode(value['nonce']?.toString() ?? ''),
      mac: Mac(base64Decode(value['mac']?.toString() ?? '')),
    );
    final clear = await AesGcm.with256bits().decrypt(box, secretKey: key,
        aad: utf8.encode('blousab-lan-frame-v2'));
    return utf8.decode(clear, allowMalformed: false);
  }

  Future<SecretKey> _performAuthenticatedHandshake(Socket socket, String peerId) async {
    final identity = BlousabCryptoIdentity.instance;
    final ownPublicKey = identity.publicKeyBase64;
    final ephemeralPair = await X25519().newKeyPair();
    final ephemeralPublic = await ephemeralPair.extractPublicKey();
    final ephemeralPublicBase64 = base64Encode(ephemeralPublic.bytes);
    final nonceBytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final nonce = base64UrlEncode(nonceBytes).replaceAll('=', '');
    final helloSignature = await identity.signText(
      _helloTranscript(_userId, peerId, nonce, ownPublicKey, ephemeralPublicBase64));
    final iterator = StreamIterator<String>(
        socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()));
    socket.write('${jsonEncode({
      'type': 'blousab_lan_handshake',
      'protocol': 'blousab-lan-v2',
      'senderId': _userId,
      'recipientId': peerId,
      'nonce': nonce,
      'publicKey': ownPublicKey,
      'ephemeralPublicKey': ephemeralPublicBase64,
      'signature': helloSignature,
    })}\n');
    await socket.flush();
    final received = await iterator.moveNext().timeout(const Duration(seconds: 5));
    if (!received) { await iterator.cancel(); throw StateError('لم يصل رد المصافحة المشفّرة'); }
    final ack = jsonDecode(iterator.current);
    await iterator.cancel();
    if (ack is! Map || ack['type'] != 'blousab_lan_handshake_ack' ||
        ack['protocol'] != 'blousab-lan-v2' || ack['senderId'] != peerId ||
        ack['recipientId'] != _userId || ack['nonce'] != nonce) {
      throw StateError('رد المصافحة غير صالح');
    }
    final peerPublicKey = ack['publicKey']?.toString() ?? '';
    final signature = ack['signature']?.toString() ?? '';
    final peerEphemeral = ack['ephemeralPublicKey']?.toString() ?? '';
    final valid = await identity.verifyText(
      publicKeyBase64: peerPublicKey,
      text: _ackTranscript(_userId, peerId, nonce, ownPublicKey, peerPublicKey,
          ephemeralPublicBase64, peerEphemeral),
      signatureBase64: signature,
    );
    if (!valid || !await identity.isPeerKeyTrusted(peerId, peerPublicKey) || peerEphemeral.isEmpty) {
      throw StateError('فشل التحقق من توقيع وهوية مستخدم بلوساب');
    }
    return _deriveLanSessionKey(localEphemeralKeyPair: ephemeralPair,
        remoteEphemeralPublicKey: peerEphemeral, nonce: nonce,
        senderId: _userId, recipientId: peerId);
  }

  Future<void> _verifyLanPeer(String peerId, String address) async {
    if (peerId.isEmpty || peerId == _userId || _verifiedPeerIds.contains(peerId) ||
        !_verifyingPeerIds.add(peerId)) return;
    Socket? socket;
    try {
      socket = await Socket.connect(address, _tcpPort, timeout: const Duration(seconds: 4));
      await _performAuthenticatedHandshake(socket, peerId);
      _verifiedPeerIds.add(peerId);
      final peer = _peers[peerId];
      if (peer != null) _events.add(BlousabEvent(type: 'peerDiscovered',
          name: peer.name, address: 'lan:$address', message: peerId,
          userId: peerId, userName: peer.name, profilePhoto: peer.photoBase64));
    } catch (_) {
      // UDP is only discovery; no peer is exposed without a signed challenge response.
    } finally {
      try { await socket?.close(); } catch (_) { socket?.destroy(); }
      _verifyingPeerIds.remove(peerId);
    }
  }

  Future<Socket> _connectVerifiedPeer(_LanPeer peer) async {
    if (!_verifiedPeerIds.contains(peer.id)) {
      await _verifyLanPeer(peer.id, peer.address);
    }
    if (!_verifiedPeerIds.contains(peer.id)) {
      throw StateError('لم يجتز المستخدم مصافحة بلوساب المشفّرة عبر الشبكة المحلية');
    }
    final socket = await Socket.connect(peer.address, _tcpPort,
        timeout: const Duration(seconds: 4));
    try {
      return socket;
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  void _prunePeers() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
    final expired = _peers.values.where((peer) => peer.lastSeen.isBefore(cutoff)).map((peer) => peer.id).toList();
    for (final id in expired) { _peers.remove(id); _verifiedPeerIds.remove(id); }
  }

  void _acceptClient(Socket socket) {
    final address = socket.remoteAddress.address;
    final buffer = <int>[];
    var closed = false;
    var handshakeComplete = false;
    String? authenticatedPeerId;
    SecretKey? sessionKey;
    Future<void> processing = Future<void>.value();

    void reject() {
      if (closed) return;
      closed = true;
      socket.destroy();
    }

    socket.listen((chunk) {
      if (closed) return;
      for (final byte in chunk) {
        if (byte != 10) {
          buffer.add(byte);
          if (buffer.length > maxFrameBytes) { reject(); return; }
          continue;
        }
        if (buffer.isNotEmpty && buffer.last == 13) buffer.removeLast();
        final frame = List<int>.from(buffer);
        buffer.clear();
        processing = processing.then((_) async {
          if (closed) return;
          try {
            final line = utf8.decode(frame, allowMalformed: false);
            if (!handshakeComplete) {
              final hello = jsonDecode(line);
              if (hello is! Map || hello['type'] != 'blousab_lan_handshake' ||
                  hello['protocol'] != 'blousab-lan-v2') { reject(); return; }
              final peerId = hello['senderId']?.toString() ?? '';
              final recipientId = hello['recipientId']?.toString() ?? '';
              final nonce = hello['nonce']?.toString() ?? '';
              final peerPublicKey = hello['publicKey']?.toString() ?? '';
              final peerEphemeral = hello['ephemeralPublicKey']?.toString() ?? '';
              final signature = hello['signature']?.toString() ?? '';
              final known = _peers[peerId];
              if (peerId.isEmpty || peerId == _userId || recipientId != _userId ||
                  nonce.length < 32 || peerEphemeral.isEmpty || known == null || known.address != address ||
                  DateTime.now().difference(known.lastSeen) > const Duration(seconds: 30)) {
                reject(); return;
              }
              final identity = BlousabCryptoIdentity.instance;
              final valid = await identity.verifyText(
                publicKeyBase64: peerPublicKey,
                text: _helloTranscript(peerId, _userId, nonce, peerPublicKey, peerEphemeral),
                signatureBase64: signature,
              );
              if (!valid || !await identity.isPeerKeyTrusted(peerId, peerPublicKey)) {
                reject(); return;
              }
              final ownPublicKey = identity.publicKeyBase64;
              final ephemeralPair = await X25519().newKeyPair();
              final ownEphemeral = await ephemeralPair.extractPublicKey();
              final ownEphemeralBase64 = base64Encode(ownEphemeral.bytes);
              final ackSignature = await identity.signText(
                _ackTranscript(peerId, _userId, nonce, peerPublicKey, ownPublicKey,
                    peerEphemeral, ownEphemeralBase64));
              sessionKey = await _deriveLanSessionKey(
                localEphemeralKeyPair: ephemeralPair,
                remoteEphemeralPublicKey: peerEphemeral, nonce: nonce,
                senderId: peerId, recipientId: _userId);
              authenticatedPeerId = peerId;
              handshakeComplete = true;
              final newlyVerified = _verifiedPeerIds.add(peerId);
              socket.write('${jsonEncode({
                'type': 'blousab_lan_handshake_ack',
                'protocol': 'blousab-lan-v2',
                'senderId': _userId,
                'recipientId': peerId,
                'nonce': nonce,
                'publicKey': ownPublicKey,
                'ephemeralPublicKey': ownEphemeralBase64,
                'signature': ackSignature,
              })}\n');
              await socket.flush();
              if (newlyVerified) _events.add(BlousabEvent(type: 'peerDiscovered',
                  name: known.name, address: 'lan:$address', message: peerId,
                  userId: peerId, userName: known.name, profilePhoto: known.photoBase64));
              return;
            }
            final key = sessionKey;
            if (key == null) { reject(); return; }
            final clearPayload = await _decryptLanFrame(line, key);
            _events.add(BlousabEvent(type: 'message', address: 'lan:$address',
              name: 'شبكة محلية', message: clearPayload, userId: authenticatedPeerId));
          } catch (_) {
            reject();
          }
        });
      }
    }, onError: (Object error) {
      _emitError('خطأ في اتصال الشبكة المحلية: $error');
      reject();
    }, onDone: () { if (!closed) socket.destroy(); });
  }

  /// Sends a packet only to the peer explicitly selected by the user.
  /// The peer must still be present in the live discovery list; stale saved
  /// addresses are never treated as an active connection.
  Future<void> sendMessageToPeer({required String address, required String payload}) async {
    if (!_running) throw StateError('الشبكة المحلية غير مفعلة');
    if (utf8.encode(payload).length > maxFrameBytes) {
      throw ArgumentError('حجم الحزمة يتجاوز الحد المسموح (1 MiB)');
    }
    final matches = _peers.values.where((p) => p.address == address);
    final peer = matches.isEmpty ? null : matches.first;
    if (peer == null) {
      throw StateError('الجهاز المحدد لم يعد ظاهرًا على الشبكة؛ حدّث البحث واختره مجددًا');
    }
    Socket? socket;
    try {
      socket = await _connectVerifiedPeer(peer);
      final sessionKey = await _performAuthenticatedHandshake(socket, peer.id);
      final secureFrame = await _encryptLanFrame(payload, sessionKey);
      socket.write('$secureFrame\n');
      await socket.flush();
    } catch (e) {
      throw StateError('تعذر الإرسال إلى ${peer.name} عبر Wi-Fi: $e');
    } finally {
      try { await socket?.close(); } catch (_) { socket?.destroy(); }
    }
  }

  /// Sends an acknowledgement or control packet to a live LAN address.
  /// The address comes from the remote TCP connection event (lan:IPv4).
  Future<void> sendControlPacket({required String address, required String payload}) async {
    if (!_running) throw StateError('الشبكة المحلية غير مفعلة');
    if (utf8.encode(payload).length > maxFrameBytes) {
      throw ArgumentError('حجم الحزمة يتجاوز الحد المسموح (1 MiB)');
    }
    final host = address.startsWith('lan:') ? address.substring(4) : address;
    final ip = InternetAddress.tryParse(host);
    if (ip == null) throw ArgumentError('عنوان شبكة غير صالح');
    Socket? socket;
    try {
      final matchingPeers = _peers.values.where((p) => p.address == ip.address && _verifiedPeerIds.contains(p.id));
      final peer = matchingPeers.isEmpty ? null : matchingPeers.first;
      if (peer == null) throw StateError('الطرف غير موثّق عبر مصافحة بلوساب');
      socket = await _connectVerifiedPeer(peer);
      final sessionKey = await _performAuthenticatedHandshake(socket, peer.id);
      final secureFrame = await _encryptLanFrame(payload, sessionKey);
      socket.write('$secureFrame\n');
      await socket.flush();
    } finally {
      try { await socket?.close(); } catch (_) { socket?.destroy(); }
    }
  }

  Future<void> broadcastMessage(String payload) => broadcastMessages(<String>[payload]);

  /// Send many bounded frames over one TCP connection per nearby peer. This
  /// avoids opening a new socket for every media chunk while keeping every
  /// frame below the receiver's memory limit.
  Future<void> broadcastMessages(Iterable<String> payloads) async {
    if (!_running) throw StateError('الشبكة المحلية غير مفعلة');
    final targets = _peers.values
        .where((peer) => _verifiedPeerIds.contains(peer.id))
        .toList(growable: false);
    final frames = payloads.toList(growable: false);
    if (targets.isEmpty) throw StateError('لم يُعثر على مستخدمي بلوساب موثّقين على الشبكة المحلية');
    var sent = 0;
    Object? lastError;
    for (final peer in targets) {
      Socket? socket;
      try {
        socket = await _connectVerifiedPeer(peer);
        final sessionKey = await _performAuthenticatedHandshake(socket, peer.id);
        var frameCount = 0;
        for (final frame in frames) {
          if (utf8.encode(frame).length > maxFrameBytes) {
            throw ArgumentError('حجم إحدى حزم الإرسال يتجاوز الحد المسموح (1 MiB)');
          }
          final secureFrame = await _encryptLanFrame(frame, sessionKey);
          if (utf8.encode(secureFrame).length > maxFrameBytes) {
            throw ArgumentError('حجم الحزمة المشفّرة يتجاوز الحد المسموح (1 MiB)');
          }
          socket.write(secureFrame);
          socket.write('\n');
          frameCount++;
        }
        if (frameCount == 0) { await socket.close(); return; }
        await socket.flush();
        sent++;
      } catch (e) {
        lastError = e;
      } finally {
        try { await socket?.close(); } catch (_) { socket?.destroy(); }
      }
    }
    if (sent == 0) throw StateError('تعذر الإرسال عبر الشبكة المحلية: $lastError');
  }

  void _emitError(String message) {
    _events.add(BlousabEvent(type: 'lanError', message: message));
  }
}

class _LanPeer {
  final String id;
  final String name;
  final String address;
  final String? photoBase64;
  DateTime lastSeen;
  _LanPeer({required this.id, required this.name, required this.address, this.photoBase64, required this.lastSeen});
}