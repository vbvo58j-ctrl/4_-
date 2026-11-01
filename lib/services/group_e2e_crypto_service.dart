import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'blousab_crypto_identity.dart';

/// Group E2E key epochs. Group keys are random, stored only in secure storage,
/// and delivered to each approved member inside that member's pairwise E2E
/// envelope. Relays only see the opaque group envelope or key package.
class GroupE2eCryptoService {
  GroupE2eCryptoService._();
  static final GroupE2eCryptoService instance = GroupE2eCryptoService._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _prefix = 'blousab_group_e2e_v1_';
  static const String _seenKey = 'blousab_group_e2e_seen_v1';
  final AesGcm _aes = AesGcm.with256bits();
  final Random _random = Random.secure();
  final Map<String, String> _decryptedCache = <String, String>{};
  Future<void> _stateQueue = Future<void>.value();

  Future<T> _serializeState<T>(Future<T> Function() action) async {
    final previous = _stateQueue;
    final release = Completer<void>();
    _stateQueue = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  String _keyName(String groupId, int epoch) =>
      '$_prefix${base64Url.encode(utf8.encode(groupId))}_$epoch';

  List<int> _randomBytes(int count) =>
      List<int>.generate(count, (_) => _random.nextInt(256));

  Future<int> currentEpoch(String groupId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('blousab_group_epoch_${base64Url.encode(utf8.encode(groupId))}') ?? 0;
  }

  /// Owner creates/rotates a fresh random key whenever membership changes.
  Future<int> rotateGroupKey(String groupId) => _serializeState(() async {
    if (groupId.trim().isEmpty) throw ArgumentError('معرّف المجتمع مطلوب');
    final epoch = (await currentEpoch(groupId)) + 1;
    final key = _randomBytes(32);
    await _storage.write(key: _keyName(groupId, epoch), value: base64Encode(key));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('blousab_group_epoch_${base64Url.encode(utf8.encode(groupId))}', epoch);
    // Keep only a small decryption window for delayed packets.
    for (var old = epoch - 6; old >= 1; old--) {
      await _storage.delete(key: _keyName(groupId, old));
    }
    return epoch;
  });

  /// Create one pairwise encrypted key package per approved member.
  Future<Map<String, Object>> createMemberKeyPackage({
    required String groupId,
    required String memberId,
    required String ownerId,
    required Future<Map<String, Object>> Function(String recipientId, String payload) sealForMember,
  }) => _serializeState(() async {
    final epoch = await currentEpoch(groupId);
    if (epoch < 1) throw StateError('يجب إنشاء مفتاح المجموعة أولاً');
    final encoded = await _storage.read(key: _keyName(groupId, epoch));
    if (encoded == null) throw StateError('مفتاح المجموعة غير موجود في التخزين الآمن');
    final package = <String, Object>{
      'type': 'blousab_group_key_package',
      'version': 1,
      'groupId': groupId,
      'epoch': epoch,
      'ownerId': ownerId,
      'memberId': memberId,
      'groupKey': encoded,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    final raw = jsonEncode(package);
    final sealed = await sealForMember(memberId, raw);
    return <String, Object>{'type': 'blousab_group_key_delivery', 'recipientId': memberId, 'envelope': sealed};
  });

  /// Accept a key package only after its pairwise envelope has been verified
  /// by BlousabCryptoIdentity and the package is addressed to this member.
  Future<void> acceptMemberKeyPackage({
    required Map envelope,
    required String localUserId,
    required Future<String> Function(Map envelope, String localUserId) openPairwise,
    required Future<bool> Function(String ownerId) isApprovedOwner,
  }) => _serializeState(() async {
    final clear = await openPairwise(envelope, localUserId);
    final value = jsonDecode(clear);
    if (value is! Map || value['type'] != 'blousab_group_key_package' || value['version'] != 1) {
      throw const FormatException('حزمة مفتاح المجموعة غير صالحة');
    }
    final groupId = value['groupId']?.toString() ?? '';
    final ownerId = value['ownerId']?.toString() ?? '';
    final memberId = value['memberId']?.toString() ?? '';
    final epoch = int.tryParse('${value['epoch']}') ?? 0;
    final keyText = value['groupKey']?.toString() ?? '';
    final keyBytes = base64Decode(keyText);
    if (groupId.isEmpty || ownerId.isEmpty || memberId != localUserId || epoch < 1 ||
        keyBytes.length != 32 || envelope['senderId']?.toString() != ownerId ||
        envelope['recipientId']?.toString() != localUserId || !(await isApprovedOwner(ownerId))) {
      throw const FormatException('هوية منشئ المجموعة أو العضوية أو المفتاح غير صالحة');
    }
    final created = DateTime.tryParse(value['createdAt']?.toString() ?? '');
    if (created == null || created.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 5))) ||
        DateTime.now().toUtc().difference(created) > const Duration(days: 2)) {
      throw const FormatException('حزمة مفتاح المجموعة منتهية');
    }
    final prefs = await SharedPreferences.getInstance();
    final epochKey = 'blousab_group_epoch_${base64Url.encode(utf8.encode(groupId))}';
    final current = prefs.getInt(epochKey) ?? 0;
    if (epoch <= current) {
      throw const FormatException('تم رفض مفتاح مجموعة قديم أو مكرر');
    }
    await _storage.write(key: _keyName(groupId, epoch), value: keyText);
    await prefs.setInt(epochKey, epoch);
  });

  Future<Map<String, Object>> sealGroupPayload({
    required String groupId,
    required String senderId,
    required String payload,
    required String messageId,
    Map<String, Object?> routingFields = const {},
  }) => _serializeState(() => _sealGroupPayloadLocked(
    groupId: groupId, senderId: senderId, payload: payload,
    messageId: messageId, routingFields: routingFields,
  ));

  Future<Map<String, Object>> _sealGroupPayloadLocked({
    required String groupId,
    required String senderId,
    required String payload,
    required String messageId,
    Map<String, Object?> routingFields = const {},
  }) async {
    await BlousabCryptoIdentity.instance.initialize();
    final epoch = await currentEpoch(groupId);
    final encodedKey = await _storage.read(key: _keyName(groupId, epoch));
    if (epoch < 1 || encodedKey == null) {
      throw StateError('لا يوجد مفتاح مجموعة لهذه النسخة من المجتمع؛ يلزم استلام مفتاح المجموعة المشفر من المنشئ.');
    }
    final aadText = 'blousab-group-e2e-v1|$groupId|$epoch|$senderId|$messageId';
    final box = await _aes.encrypt(utf8.encode(payload), secretKey: SecretKey(base64Decode(encodedKey)), aad: utf8.encode(aadText));
    final unsigned = <String, Object>{
      'type': 'blousab_group_e2e_envelope', 'version': 1,
      'groupId': groupId, 'epoch': epoch, 'senderId': senderId,
      'senderEd25519': BlousabCryptoIdentity.instance.publicKeyBase64,
      'id': messageId, 'recipientId': '*',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'nonce': base64Encode(box.nonce), 'cipherText': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
    const routingAllowed = <String>{'conversationId','sentAt','createdAt','relay','relayEnabled','hopCount','hops','relayPath','transferId','index','chunkCount','totalBytes','checksum'};
    for (final entry in routingFields.entries) {
      if (routingAllowed.contains(entry.key) && entry.value != null) unsigned[entry.key] = entry.value!;
    }
    final canonical = _canonical(unsigned);
    unsigned['signature'] = await BlousabCryptoIdentity.instance.signText(canonical);
    return unsigned;
  }

  Future<String> openGroupPayload(Map envelope, {required String localUserId, required bool Function(String senderId) isApprovedMember}) =>
      _serializeState(() => _openGroupPayloadLocked(envelope, localUserId: localUserId, isApprovedMember: isApprovedMember));

  Future<String> _openGroupPayloadLocked(Map envelope, {required String localUserId, required bool Function(String senderId) isApprovedMember}) async {
    if (envelope['type'] != 'blousab_group_e2e_envelope' || envelope['version'] != 1) {
      throw const FormatException('ظرف تشفير المجموعة غير صالح');
    }
    final groupId = envelope['groupId']?.toString() ?? '';
    final senderId = envelope['senderId']?.toString() ?? '';
    final senderEd = envelope['senderEd25519']?.toString() ?? '';
    final messageId = envelope['id']?.toString() ?? '';
    final epoch = int.tryParse('${envelope['epoch']}') ?? 0;
    if (groupId.isEmpty || senderId.isEmpty || messageId.isEmpty || epoch < 1 ||
        envelope['recipientId']?.toString() != '*' ||
        !isApprovedMember(senderId) || !isApprovedMember(localUserId)) {
      throw const FormatException('مرسل الرسالة ليس عضواً مقبولاً في المجموعة');
    }
    final pinned = await BlousabCryptoIdentity.instance.trustedPeerEd25519PublicKey(senderId);
    if (pinned == null || pinned != senderEd) throw const FormatException('مفتاح مرسل المجموعة غير موثق');
    final unsigned = <String, Object>{};
    for (final entry in envelope.entries) {
      if (entry.key.toString() != 'signature' && entry.value != null) unsigned[entry.key.toString()] = entry.value as Object;
    }
    final valid = await BlousabCryptoIdentity.instance.verifyText(
      publicKeyBase64: pinned, text: _canonical(unsigned), signatureBase64: envelope['signature']?.toString() ?? '',
    );
    if (!valid) throw const FormatException('توقيع رسالة المجموعة غير صحيح');
    final encodedKey = await _storage.read(key: _keyName(groupId, epoch));
    if (encodedKey == null) throw const FormatException('لا تملك مفتاح هذا الإصدار من المجموعة');
    final created = DateTime.tryParse(envelope['createdAt']?.toString() ?? '');
    if (created == null || created.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 5))) || DateTime.now().toUtc().difference(created) > const Duration(days: 7)) {
      throw const FormatException('رسالة المجموعة منتهية');
    }
    final replayId = '$groupId:$epoch:$messageId';
    final prefs = await SharedPreferences.getInstance();
    final seen = (prefs.getStringList(_seenKey) ?? <String>[]).toList();
    if (seen.contains(replayId)) {
      // Multiple in-app listeners may consume the same packet. Permit only
      // this process-local cached plaintext; after restart, replay is rejected.
      final cached = _decryptedCache[replayId];
      if (cached != null) return cached;
      throw const FormatException('تم رفض رسالة مجموعة مكررة');
    }
    final aad = utf8.encode('blousab-group-e2e-v1|$groupId|$epoch|$senderId|$messageId');
    final clearBytes = await _aes.decrypt(SecretBox(base64Decode(envelope['cipherText'].toString()), nonce: base64Decode(envelope['nonce'].toString()), mac: Mac(base64Decode(envelope['mac'].toString()))), secretKey: SecretKey(base64Decode(encodedKey)), aad: aad);
    final clear = utf8.decode(clearBytes);
    seen.add(replayId);
    if (seen.length > 10000) seen.removeRange(0, seen.length - 10000);
    await prefs.setStringList(_seenKey, seen);
    _decryptedCache[replayId] = clear;
    if (_decryptedCache.length > 256) _decryptedCache.remove(_decryptedCache.keys.first);
    return clear;
  }

  String _canonical(Map<String, Object> map) {
    // Relays may append their hop metadata without possessing the group key.
    const mutableRelayFields = <String>{'relayPath', 'hopCount', 'hops'};
    final keys = map.keys.where((key) => !mutableRelayFields.contains(key)).toList()..sort();
    return jsonEncode(<String, Object>{for (final key in keys) key: map[key]!});
  }
}
