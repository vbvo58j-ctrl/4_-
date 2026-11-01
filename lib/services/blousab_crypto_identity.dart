import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device identity used to authenticate Blousab LAN sessions.
/// The Ed25519 seed is stored through Android Keystore-backed secure storage.
class BlousabCryptoIdentity {
  BlousabCryptoIdentity._();
  static final BlousabCryptoIdentity instance = BlousabCryptoIdentity._();

  static const _storage = FlutterSecureStorage();
  static const _seedKey = 'blousab_ed25519_seed_v1';
  static const _peerPrefix = 'blousab_peer_ed25519_v1_';
  static const _x25519SeedKey = 'blousab_x25519_identity_seed_v1';
  static const _peerE2ePrefix = 'blousab_peer_x25519_v1_';
  final Ed25519 _algorithm = Ed25519();
  SimpleKeyPair? _keyPair;
  String? _publicKeyBase64;
  SimpleKeyPair? _x25519KeyPair;
  String? _x25519PublicKeyBase64;
  Future<void> _replayQueue = Future<void>.value();

  /// Ensures every installation has a stable, unique Blousab peer ID.
  /// The old shared fallback ID caused unrelated devices to collide during
  /// LAN authentication and Mesh routing.
  Future<String> ensureUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getString('wasl_user_id') ?? '').trim();
    if (current.isNotEmpty && current != 'blousab-user') return current;
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    final generated = 'bs_${base64UrlEncode(bytes).replaceAll('=', '')}';
    await prefs.setString('wasl_user_id', generated);
    return generated;
  }

  Future<void> initialize() async {
    if (_keyPair != null) return;
    var seedText = await _storage.read(key: _seedKey);
    if (seedText == null || seedText.isEmpty) {
      final generated = await _algorithm.newKeyPair();
      final seed = await generated.extractPrivateKeyBytes();
      seedText = base64Encode(seed);
      await _storage.write(key: _seedKey, value: seedText);
    }
    final seed = base64Decode(seedText);
    _keyPair = await _algorithm.newKeyPairFromSeed(seed);
    final publicKey = await _keyPair!.extractPublicKey();
    _publicKeyBase64 = base64Encode(publicKey.bytes);
    var xSeedText = await _storage.read(key: _x25519SeedKey);
    if (xSeedText == null || xSeedText.isEmpty) {
      final generatedX = await X25519().newKeyPair();
      xSeedText = base64Encode(await generatedX.extractPrivateKeyBytes());
      await _storage.write(key: _x25519SeedKey, value: xSeedText);
    }
    _x25519KeyPair = await X25519().newKeyPairFromSeed(base64Decode(xSeedText));
    final xPublic = await _x25519KeyPair!.extractPublicKey();
    _x25519PublicKeyBase64 = base64Encode(xPublic.bytes);
  }

  String get x25519PublicKeyBase64 {
    final value = _x25519PublicKeyBase64;
    if (value == null) throw StateError('مفتاح E2E لم يُهيأ');
    return value;
  }

  String get publicKeyBase64 {
    final value = _publicKeyBase64;
    if (value == null) throw StateError('هوية بلوساب التشفيرية لم تُهيأ');
    return value;
  }

  Future<String> signText(String text) async {
    await initialize();
    final signature = await _algorithm.sign(
      utf8.encode(text),
      keyPair: _keyPair!,
    );
    return base64Encode(signature.bytes);
  }

  /// Stable short fingerprint for out-of-band peer confirmation (for example
  /// comparing a QR/safety number). This does not itself establish trust.
  Future<String> fingerprintFor(String publicKeyBase64) async {
    final keyBytes = base64Decode(publicKeyBase64);
    if (keyBytes.length != 32) throw ArgumentError('مفتاح Ed25519 غير صالح');
    final digest = await Sha256().hash(keyBytes);
    final hex = digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return List<String>.generate(8, (i) => hex.substring(i * 8, i * 8 + 8)).join(' ');
  }

  Future<bool> verifyText({
    required String publicKeyBase64,
    required String text,
    required String signatureBase64,
  }) async {
    try {
      final publicKey = SimplePublicKey(
        base64Decode(publicKeyBase64),
        type: KeyPairType.ed25519,
      );
      final signature = Signature(
        base64Decode(signatureBase64),
        publicKey: publicKey,
      );
      return await _algorithm.verify(utf8.encode(text), signature: signature);
    } catch (_) {
      return false;
    }
  }

  /// Creates a signed, self-contained identity assertion for short-range
  /// discovery. The signature proves possession of the Ed25519 private key;
  /// it does not silently pin a first-contact peer as trusted.
  Future<Map<String, String>> createSignedDiscoveryIdentity({
    required String userId,
    required String userName,
    required String profilePhoto,
  }) async {
    await initialize();
    final payload = <String, Object>{
      'type': 'blousab_discovery_identity',
      'version': 2,
      'userId': userId.trim(),
      'userName': userName,
      'profilePhoto': profilePhoto,
      'publicKey': publicKeyBase64,
      'e2ePublicKey': x25519PublicKeyBase64,
    };
    if ((payload['userId'] as String).isEmpty) {
      throw ArgumentError('معرّف مستخدم بلوساب مطلوب');
    }
    final payloadBytes = utf8.encode(jsonEncode(payload));
    final signature = await _algorithm.sign(payloadBytes, keyPair: _keyPair!);
    return <String, String>{
      'payload': base64Encode(payloadBytes),
      'signature': base64Encode(signature.bytes),
    };
  }

  /// Exports the public identity for out-of-band QR exchange. The private
  /// Ed25519 seed is never included in this payload.
  Future<String> exportTrustPayload({required String userId}) async {
    await initialize();
    final id = userId.trim();
    if (id.isEmpty) throw ArgumentError('معرّف مستخدم بلوساب مطلوب');
    final fingerprint = await _trustFingerprint(publicKeyBase64, x25519PublicKeyBase64);
    return jsonEncode(<String, Object>{
      'type': 'blousab_identity_trust',
      'version': 2,
      'userId': id,
      'publicKey': publicKeyBase64,
      'e2ePublicKey': x25519PublicKeyBase64,
      'fingerprint': fingerprint,
    });
  }

  String _canonicalEnvelope(Map<String, Object> values) {
    // Mesh relays are allowed to advance these hop-by-hop routing fields.
    // All end-to-end identity, destination, content and nonce fields remain
    // signed; each hop separately authenticates the previous transport peer.
    const mutableRelayFields = <String>{'relayPath', 'hopCount', 'hops'};
    final keys = values.keys.where((key) => !mutableRelayFields.contains(key)).toList()..sort();
    return jsonEncode(<String, Object>{for (final key in keys) key: values[key]!});
  }

  Future<T> _serializeReplay<T>(Future<T> Function() action) async {
    final previous = _replayQueue;
    final release = Completer<void>();
    _replayQueue = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  Future<bool> _markE2eEnvelopeSeen(String envelopeId) => _serializeReplay(() async {
    if (envelopeId.isEmpty || envelopeId.length > 128) return false;
    final prefs = await SharedPreferences.getInstance();
    final seen = (prefs.getStringList('blousab_e2e_seen_v1') ?? <String>[]).toList();
    if (seen.contains(envelopeId)) return false;
    seen.add(envelopeId);
    if (seen.length > 5000) seen.removeRange(0, seen.length - 5000);
    await prefs.setStringList('blousab_e2e_seen_v1', seen);
    return true;
  });

  Future<String> _trustFingerprint(String ed25519PublicKey, String x25519PublicKey) async {
    final digest = await Sha256().hash(utf8.encode('blousab-trust-v2|$ed25519PublicKey|$x25519PublicKey'));
    final hex = digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return List<String>.generate(8, (i) => hex.substring(i * 8, i * 8 + 8)).join(' ');
  }

  /// Parses and validates the public QR payload. Parsing does not pin trust.
  Future<Map<String, String>?> parseTrustPayload(String raw) async {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['type'] != 'blousab_identity_trust' || decoded['version'] != 2) {
        return null;
      }
      final userId = decoded['userId']?.toString().trim() ?? '';
      final publicKey = decoded['publicKey']?.toString() ?? '';
      final e2ePublicKey = decoded['e2ePublicKey']?.toString() ?? '';
      final suppliedFingerprint = decoded['fingerprint']?.toString().trim() ?? '';
      if (userId.isEmpty || userId.length > 256 || publicKey.isEmpty || e2ePublicKey.isEmpty) return null;
      final bytes = base64Decode(publicKey);
      final e2eBytes = base64Decode(e2ePublicKey);
      if (bytes.length != 32 || e2eBytes.length != 32) return null;
      final actualFingerprint = await _trustFingerprint(publicKey, e2ePublicKey);
      if (actualFingerprint.toLowerCase() != suppliedFingerprint.toLowerCase()) return null;
      return <String, String>{
        'userId': userId,
        'publicKey': publicKey,
        'e2ePublicKey': e2ePublicKey,
        'fingerprint': actualFingerprint,
      };
    } catch (_) {
      return null;
    }
  }

  /// Encrypts a payload for a previously QR-pinned Blousab identity.
  /// The signed envelope is opaque to Mesh relays. Static X25519 is used here
  /// as a compatibility foundation; a later ratchet adds forward secrecy.
  Future<Map<String, Object>> sealE2ePayload({
    required String senderId,
    required String recipientId,
    required String payload,
    Map<String, Object?> routingFields = const <String, Object?>{},
  }) async {
    await initialize();
    final peerX = await trustedPeerE2ePublicKey(recipientId);
    if (peerX == null) throw StateError('لا يوجد مفتاح E2E موثوق للمستلم؛ امسح QR وقارن البصمة أولاً.');
    final remote = SimplePublicKey(base64Decode(peerX), type: KeyPairType.x25519);
    final shared = await X25519().sharedSecretKey(keyPair: _x25519KeyPair!, remotePublicKey: remote);
    final salt = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: salt,
      info: utf8.encode('blousab-e2e-static-v1|$senderId|$recipientId'),
    );
    final aad = utf8.encode('blousab-e2e-envelope-v1|$senderId|$recipientId');
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(payload), secretKey: key, aad: aad,
    );
    final unsigned = <String, Object>{
      'type': 'blousab_e2e_envelope', 'version': 1,
      'senderId': senderId, 'recipientId': recipientId,
      'senderEd25519': publicKeyBase64,
      'senderX25519': x25519PublicKeyBase64,
      'envelopeId': base64UrlEncode(List<int>.generate(18, (_) => Random.secure().nextInt(256))).replaceAll('=', ''),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'salt': base64Encode(salt), 'nonce': base64Encode(box.nonce),
      'cipherText': base64Encode(box.cipherText), 'mac': base64Encode(box.mac.bytes),
    };
    // Only non-content routing metadata is exposed to Mesh relays. The inner
    // application packet (including message/file content) remains encrypted.
    const allowedRouting = <String>{
      'id', 'conversationId', 'sentAt', 'createdAt', 'relay', 'relayEnabled',
      'hopCount', 'hops', 'relayPath', 'transferId', 'index', 'chunkCount',
      'totalBytes', 'checksum',
    };
    for (final entry in routingFields.entries) {
      if (allowedRouting.contains(entry.key) && entry.value != null) {
        unsigned[entry.key] = entry.value!;
      }
    }
    final canonical = _canonicalEnvelope(unsigned);
    unsigned['signature'] = await signText(canonical);
    return unsigned;
  }

  /// Verifies sender pin + Ed25519 signature before attempting AES-GCM.
  /// A relay can forward the map unchanged without learning its contents.
  Future<String> openE2ePayload(Map envelope, {required String localUserId}) async {
    await initialize();
    if (envelope['type'] != 'blousab_e2e_envelope' || envelope['version'] != 1 ||
        envelope['recipientId']?.toString() != localUserId) {
      throw const FormatException('ظرف E2E غير صالح أو ليس موجهاً لهذا المستخدم.');
    }
    final senderId = envelope['senderId']?.toString() ?? '';
    final senderEd = envelope['senderEd25519']?.toString() ?? '';
    final senderX = envelope['senderX25519']?.toString() ?? '';
    if (senderId.isEmpty || senderEd.isEmpty || senderX.isEmpty) {
      throw const FormatException('هوية مرسل E2E ناقصة.');
    }
    final pinnedEd = await trustedPeerEd25519PublicKey(senderId);
    final pinnedX = await trustedPeerE2ePublicKey(senderId);
    if (pinnedEd == null || pinnedX == null || pinnedEd != senderEd || pinnedX != senderX) {
      throw const FormatException('مفاتيح المرسل لا تطابق الهوية التي وثقتها عبر QR.');
    }
    final signature = envelope['signature']?.toString() ?? '';
    final unsigned = <String, Object>{};
    for (final entry in envelope.entries) {
      if (entry.key.toString() == 'signature' || entry.value == null) continue;
      unsigned[entry.key.toString()] = entry.value as Object;
    }
    if (!await verifyText(publicKeyBase64: pinnedEd, text: _canonicalEnvelope(unsigned), signatureBase64: signature)) {
      throw const FormatException('توقيع ظرف E2E غير صحيح.');
    }
    final remote = SimplePublicKey(base64Decode(senderX), type: KeyPairType.x25519);
    final shared = await X25519().sharedSecretKey(keyPair: _x25519KeyPair!, remotePublicKey: remote);
    final salt = base64Decode(envelope['salt'].toString());
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared, nonce: salt,
      info: utf8.encode('blousab-e2e-static-v1|$senderId|$localUserId'),
    );
    final aad = utf8.encode('blousab-e2e-envelope-v1|$senderId|$localUserId');
    final createdAt = DateTime.tryParse(envelope['createdAt']?.toString() ?? '');
    if (createdAt == null || createdAt.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 5))) ||
        DateTime.now().toUtc().difference(createdAt) > const Duration(days: 7)) {
      throw const FormatException('ظرف E2E منتهي أو يحمل توقيتاً غير صالح.');
    }
    final clear = await AesGcm.with256bits().decrypt(
      SecretBox(base64Decode(envelope['cipherText'].toString()),
        nonce: base64Decode(envelope['nonce'].toString()),
        mac: Mac(base64Decode(envelope['mac'].toString()))),
      secretKey: key, aad: aad,
    );
    final envelopeId = envelope['envelopeId']?.toString() ?? '';
    if (!await _markE2eEnvelopeSeen(envelopeId)) {
      throw const FormatException('تم رفض إعادة تشغيل ظرف E2E سبق استلامه.');
    }
    return utf8.decode(clear);
  }

  Future<String?> trustedPeerE2ePublicKey(String peerId) async {
    if (peerId.trim().isEmpty) return null;
    final key = '$_peerE2ePrefix${base64Url.encode(utf8.encode(peerId))}';
    return _storage.read(key: key);
  }

  Future<String?> trustedPeerEd25519PublicKey(String peerId) async {
    if (peerId.trim().isEmpty) return null;
    final key = '$_peerPrefix${base64Url.encode(utf8.encode(peerId))}';
    return _storage.read(key: key);
  }

  /// Returns true only when this exact public key was explicitly trusted before.
  /// Network handshakes must never create trust implicitly.
  Future<bool> isPeerKeyTrusted(String peerId, String publicKeyBase64) async {
    if (peerId.trim().isEmpty || publicKeyBase64.isEmpty) return false;
    try {
      final bytes = base64Decode(publicKeyBase64);
      if (bytes.length != 32) return false;
      final key = '$_peerPrefix${base64Url.encode(utf8.encode(peerId))}';
      final existing = await _storage.read(key: key);
      return existing != null && existing == publicKeyBase64;
    } catch (_) {
      return false;
    }
  }

  /// Explicit first-contact trust. The user must compare the fingerprint
  /// obtained out-of-band (QR or another trusted channel) and enter it here.
  /// This method is intentionally never called by a network handshake.
  Future<bool> trustPeerKeyAfterFingerprintCheck({
    required String peerId,
    required String publicKeyBase64,
    required String e2ePublicKeyBase64,
    required String confirmedFingerprint,
  }) async {
    if (peerId.trim().isEmpty || publicKeyBase64.isEmpty || e2ePublicKeyBase64.isEmpty ||
        confirmedFingerprint.trim().isEmpty) return false;
    try {
      final bytes = base64Decode(publicKeyBase64);
      final e2eBytes = base64Decode(e2ePublicKeyBase64);
      if (bytes.length != 32 || e2eBytes.length != 32) return false;
      final actual = await _trustFingerprint(publicKeyBase64, e2ePublicKeyBase64);
      if (actual.toLowerCase() != confirmedFingerprint.trim().toLowerCase()) {
        return false;
      }
      final key = '$_peerPrefix${base64Url.encode(utf8.encode(peerId))}';
      final existing = await _storage.read(key: key);
      if (existing != null && existing != publicKeyBase64) return false;
      final e2eKey = '$_peerE2ePrefix${base64Url.encode(utf8.encode(peerId))}';
      final existingE2e = await _storage.read(key: e2eKey);
      if (existingE2e != null && existingE2e != e2ePublicKeyBase64) return false;
      await _storage.write(key: key, value: publicKeyBase64);
      await _storage.write(key: e2eKey, value: e2ePublicKeyBase64);
      return true;
    } catch (_) {
      return false;
    }
  }

}
