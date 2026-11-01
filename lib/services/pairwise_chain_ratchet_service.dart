import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'blousab_crypto_identity.dart';

/// Pairwise DH/chain ratchet session engine used by live direct-chat and file paths.
/// Session setup is authenticated by the user's QR-pinned Ed25519 identity;
/// per-message keys are derived from directional chains and periodically
/// refreshed through X25519 DH ratchets. Group traffic uses its own sender-key path.
class PairwiseChainRatchetService {
  PairwiseChainRatchetService._();
  static final PairwiseChainRatchetService instance = PairwiseChainRatchetService._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _prefix = 'blousab_pair_dh_ratchet_v2_';
  static const int _maxSkipped = 128;
  final X25519 _x25519 = X25519();
  final Hmac _hmac = Hmac.sha256();
  final AesGcm _aes = AesGcm.with256bits();
  final Random _random = Random.secure();

  // Serialize all state transitions for a peer. FlutterSecureStorage does not
  // provide compare-and-swap transactions, so concurrent read/modify/write
  // operations would otherwise be able to overwrite each other.
  final Map<String, Future<void>> _peerTails = <String, Future<void>>{};

  Future<T> _withPeerLock<T>(String peerId, Future<T> Function() action) async {
    final previous = _peerTails[peerId] ?? Future<void>.value();
    final gate = Completer<void>();
    final queued = gate.future;
    _peerTails[peerId] = queued;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
      if (identical(_peerTails[peerId], queued)) {
        _peerTails.remove(peerId);
      }
    }
  }

  List<int> _randomBytes(int count) =>
      List<int>.generate(count, (_) => _random.nextInt(256));

  String _storageKey(String peerId, String sessionId) =>
      '$_prefix${base64Url.encode(utf8.encode(peerId))}_${sessionId}';

  Future<List<int>> _mac(List<int> key, String label) async =>
      (await _hmac.calculateMac(utf8.encode(label), secretKey: SecretKey(key))).bytes;

  String _canonical(Map<String, Object> map) {
    // Mesh relays are allowed to update only hop metadata. Excluding these
    // mutable fields keeps the sender's signature valid end-to-end while all
    // identity, session, counter, routing destination and ciphertext fields
    // remain signed.
    final keys = map.keys.where((key) =>
      key != 'relayPath' && key != 'hopCount' && key != 'hops').toList()..sort();
    return jsonEncode(<String, Object>{for (final key in keys) key: map[key]!});
  }

  /// Initiator creates a signed ephemeral offer. Keep the returned private
  /// ephemeral key only until [finishInitiator]; never send it over the wire.
  Future<Map<String, Object>> createOffer({required String localUserId, required String peerId, String? conversationId}) async {
    await BlousabCryptoIdentity.instance.initialize();
    final ephemeral = await _x25519.newKeyPair();
    final public = await ephemeral.extractPublicKey();
    final body = <String, Object>{
      'type': 'blousab_ratchet_offer', 'version': 2,
      'senderId': localUserId, 'recipientId': peerId,
      'id': 'ratchet_offer_${base64UrlEncode(_randomBytes(12))}',
      'conversationId': conversationId ?? '',
      'relay': true, 'relayEnabled': true, 'hopCount': 0, 'hops': 0, 'relayPath': <String>[],
      'ephemeral': base64Encode(public.bytes),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'nonce': base64Encode(_randomBytes(32)),
    };
    final signature = await BlousabCryptoIdentity.instance.signText(_canonical(body));
    final offer = <String, Object>{...body, 'signature': signature};
    final privateBytes = await ephemeral.extractPrivateKeyBytes();
    await _storage.write(
      key: '${_storageKey(peerId, 'pending')}_${base64Url.encode(utf8.encode(offer['nonce'] as String))}',
      value: jsonEncode(<String, Object>{
        'private': base64Encode(privateBytes), 'offer': offer,
      }),
    );
    return offer;
  }

  Future<bool> _verifySigned(Map packet, String senderId) async {
    final pinned = await BlousabCryptoIdentity.instance.trustedPeerEd25519PublicKey(senderId);
    if (pinned == null || packet['signature'] == null) return false;
    final body = <String, Object>{};
    for (final entry in packet.entries) {
      if (entry.key.toString() != 'signature' && entry.value != null) {
        body[entry.key.toString()] = entry.value as Object;
      }
    }
    return BlousabCryptoIdentity.instance.verifyText(
      publicKeyBase64: pinned,
      text: _canonical(body),
      signatureBase64: packet['signature'].toString(),
    );
  }

  /// Responder authenticates the offer, contributes fresh DH entropy, and
  /// derives the same root/role-separated chains as the initiator.
  Future<Map<String, Object>> acceptOffer({
    required Map offer,
    required String localUserId,
  }) {
    final peerId = offer['senderId']?.toString() ?? '';
    if (peerId.isEmpty) return Future.error(const FormatException('هوية المرسل غير صالحة'));
    return _withPeerLock(peerId, () => _acceptOfferUnlocked(offer: offer, localUserId: localUserId));
  }

  Future<Map<String, Object>> _acceptOfferUnlocked({
    required Map offer,
    required String localUserId,
  }) async {
    await BlousabCryptoIdentity.instance.initialize();
    final peerId = offer['senderId']?.toString() ?? '';
    if (offer['type'] != 'blousab_ratchet_offer' || offer['version'] != 2 ||
        offer['recipientId']?.toString() != localUserId || peerId.isEmpty ||
        !await _verifySigned(offer, peerId)) {
      throw const FormatException('عرض إنشاء جلسة التشفير غير موثوق');
    }
    _validateFresh(offer['createdAt']?.toString());
    final offerNonce = offer['nonce']?.toString() ?? '';
    final offerId = offer['id']?.toString() ?? '';
    if (offerNonce.isEmpty || offerId.isEmpty ||
        base64Decode(offerNonce).length != 32 ||
        offer['conversationId']?.toString().isEmpty != false) {
      throw const FormatException('حقول عرض المصافحة أو nonce غير صالحة');
    }
    final acceptedKey = '${_storageKey(peerId, 'accepted')}_$offerNonce';
    final cachedAnswer = await _storage.read(key: acceptedKey);
    if (cachedAnswer != null) {
      final decodedAnswer = jsonDecode(cachedAnswer);
      if (decodedAnswer is Map) return Map<String, Object>.from(decodedAnswer.map((k, v) => MapEntry(k.toString(), v as Object)));
      throw const FormatException('رد المصافحة المحفوظ غير صالح');
    }
    final remoteBytes = base64Decode(offer['ephemeral'].toString());
    if (remoteBytes.length != 32) throw const FormatException('مفتاح مؤقت غير صالح');
    final localEphemeral = await _x25519.newKeyPair();
    final localPublic = await localEphemeral.extractPublicKey();
    final remote = SimplePublicKey(remoteBytes, type: KeyPairType.x25519);
    final shared = await _x25519.sharedSecretKey(keyPair: localEphemeral, remotePublicKey: remote);
    final answerBody = <String, Object>{
      'type': 'blousab_ratchet_answer', 'version': 2,
      'senderId': localUserId, 'recipientId': peerId,
      'id': 'ratchet_answer_${base64UrlEncode(_randomBytes(12))}',
      'conversationId': offer['conversationId']?.toString() ?? '',
      'relay': true, 'relayEnabled': true, 'hopCount': 0, 'hops': 0, 'relayPath': <String>[localUserId],
      'offerNonce': offer['nonce'].toString(),
      'ephemeral': base64Encode(localPublic.bytes),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'nonce': base64Encode(_randomBytes(32)),
    };
    final answer = <String, Object>{
      ...answerBody,
      'signature': await BlousabCryptoIdentity.instance.signText(_canonical(answerBody)),
    };
    final transcript = '${_canonical(_asObjectMap(offer))}|${_canonical(answerBody)}';
    await _saveSession(peerId, transcript, await shared.extractBytes(),
      localDhPrivate: await localEphemeral.extractPrivateKeyBytes(),
      remoteDhPublic: remoteBytes, initiator: false);
    await _storage.write(key: acceptedKey, value: jsonEncode(answer));
    return answer;
  }

  /// Initiator verifies the answer and completes the ephemeral DH handshake.
  Future<void> finishInitiator({
    required Map offer,
    required Map answer,
    required String localUserId,
    required String peerId,
  }) => _withPeerLock(peerId, () => _finishInitiatorUnlocked(
    offer: offer, answer: answer, localUserId: localUserId, peerId: peerId,
  ));

  Future<void> _finishInitiatorUnlocked({
    required Map offer,
    required Map answer,
    required String localUserId,
    required String peerId,
  }) async {
    if (offer['senderId']?.toString() != localUserId ||
        offer['recipientId']?.toString() != peerId ||
        answer['senderId']?.toString() != peerId ||
        answer['recipientId']?.toString() != localUserId ||
        answer['offerNonce']?.toString() != offer['nonce']?.toString() ||
        answer['conversationId']?.toString() != offer['conversationId']?.toString() ||
        (answer['id']?.toString() ?? '').isEmpty ||
        answer['type'] != 'blousab_ratchet_answer' || answer['version'] != 2 ||
        !await _verifySigned(answer, peerId)) {
      throw const FormatException('رد إنشاء جلسة التشفير غير صالح');
    }
    _validateFresh(answer['createdAt']?.toString());
    final pendingKey = '${_storageKey(peerId, 'pending')}_${base64Url.encode(utf8.encode(offer['nonce'].toString()))}';
    final pendingText = await _storage.read(key: pendingKey);
    if (pendingText == null) throw const FormatException('مفتاح الجلسة المؤقت غير موجود');
    final pending = jsonDecode(pendingText) as Map;
    final ephemeral = await _x25519.newKeyPairFromSeed(base64Decode(pending['private'].toString()));
    final remoteBytes = base64Decode(answer['ephemeral'].toString());
    if (remoteBytes.length != 32 || base64Decode(answer['nonce'].toString()).length != 32) {
      throw const FormatException('مفتاح الرد أو nonce المؤقت غير صالح');
    }
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(remoteBytes, type: KeyPairType.x25519),
    );
    final answerBody = <String, Object>{};
    for (final entry in answer.entries) {
      if (entry.key.toString() != 'signature' && entry.value != null) answerBody[entry.key.toString()] = entry.value as Object;
    }
    final transcript = '${_canonical(_asObjectMap(offer))}|${_canonical(answerBody)}';
    await _saveSession(peerId, transcript, await shared.extractBytes(),
      localDhPrivate: base64Decode(pending['private'].toString()),
      remoteDhPublic: remoteBytes, initiator: true);
    await _storage.delete(key: pendingKey);
  }

  Future<bool> hasActiveSession(String peerId) async {
    final sessionId = await _storage.read(key: _storageKey(peerId, 'active'));
    if (sessionId == null || sessionId.isEmpty) return false;
    final raw = await _storage.read(key: _storageKey(peerId, sessionId));
    if (raw == null) return false;
    try {
      final state = jsonDecode(raw) as Map;
      return state['version'] == 2 && state['sessionId'] == sessionId;
    } catch (_) { return false; }
  }

  Future<bool> hasPendingOffer(String peerId) async {
    final prefix = '${_storageKey(peerId, 'pending')}_';
    final all = await _storage.readAll();
    return all.keys.any((key) => key.startsWith(prefix));
  }

  Future<void> _clearPendingOffers(String peerId) async {
    final prefix = '${_storageKey(peerId, 'pending')}_';
    final all = await _storage.readAll();
    for (final key in all.keys.where((key) => key.startsWith(prefix))) {
      await _storage.delete(key: key);
    }
  }

  /// Consumes signed session-control packets. Returns an answer for an offer;
  /// answers complete the initiator side and return null.
  Future<Map<String, Object>?> handleHandshakePacket({
    required Map packet, required String localUserId,
  }) async {
    final type = packet['type']?.toString() ?? '';
    final peerId = packet['senderId']?.toString() ?? '';
    if (peerId.isEmpty || packet['recipientId']?.toString() != localUserId) {
      throw const FormatException('وجهة مصافحة Ratchet غير صحيحة');
    }
    if (type == 'blousab_ratchet_offer') {
      // Resolve simultaneous first-contact offers deterministically. If both
      // sides initiated, the lexicographically smaller stable user ID wins
      // the initiator role; the other side discards its competing ephemeral.
      if (await hasPendingOffer(peerId)) {
        if (localUserId.compareTo(peerId) < 0) return null;
        await _clearPendingOffers(peerId);
      }
      return acceptOffer(offer: packet, localUserId: localUserId);
    }
    if (type == 'blousab_ratchet_answer') {
      final nonce = packet['offerNonce']?.toString() ?? '';
      if (nonce.isEmpty) throw const FormatException('معرّف العرض مفقود');
      final pendingKey = '${_storageKey(peerId, 'pending')}_${base64Url.encode(utf8.encode(nonce))}';
      final pendingText = await _storage.read(key: pendingKey);
      if (pendingText == null) throw const FormatException('لا يوجد عرض مصافحة منتظر لهذا الرد');
      final pending = jsonDecode(pendingText) as Map;
      final offer = pending['offer'];
      if (offer is! Map || offer['nonce']?.toString() != nonce) {
        throw const FormatException('العرض المحفوظ لا يطابق الرد');
      }
      await finishInitiator(offer: offer, answer: packet,
        localUserId: localUserId, peerId: peerId);
      return null;
    }
    throw const FormatException('نوع مصافحة Ratchet غير معروف');
  }

  Map<String, Object> _asObjectMap(Map value) => <String, Object>{
    for (final entry in value.entries) if (entry.value != null) entry.key.toString(): entry.value as Object,
  };

  void _validateFresh(String? raw) {
    final date = DateTime.tryParse(raw ?? '');
    if (date == null || date.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 3))) ||
        DateTime.now().toUtc().difference(date) > const Duration(minutes: 10)) {
      throw const FormatException('مصافحة الجلسة قديمة أو توقيتها غير صالح');
    }
  }

  Future<(List<int>, List<int>)> _kdfRoot(List<int> rootKey, List<int> dhOutput) async {
    final material = await Hkdf(hmac: _hmac, outputLength: 64).deriveKey(
      secretKey: SecretKey(dhOutput), nonce: rootKey,
      info: utf8.encode('blousab-double-ratchet-root-v2'),
    );
    final bytes = await material.extractBytes();
    return (bytes.sublist(0, 32), bytes.sublist(32, 64));
  }

  Future<List<int>> _dh(List<int> privateBytes, List<int> publicBytes) async {
    if (privateBytes.length != 32 || publicBytes.length != 32) {
      throw const FormatException('مفتاح DH Ratchet غير صالح');
    }
    final pair = await _x25519.newKeyPairFromSeed(privateBytes);
    final secret = await _x25519.sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
    );
    return secret.extractBytes();
  }

  Future<void> _skipUntil(Map<String, dynamic> state, int until, String dhTag) async {
    final current = state['receiveCounter'] as int;
    if (until < current || until - current > _maxSkipped) {
      if (until == current) return;
      throw const FormatException('عداد الرسائل السابقة خارج نافذة Ratchet');
    }
    var chain = base64Decode(state['receiveChain'].toString());
    final skipped = (state['skipped'] as Map).cast<String, String>();
    for (var index = current; index < until; index++) {
      if (skipped.length >= _maxSkipped) throw const FormatException('امتلأت مفاتيح الرسائل المؤجلة');
      skipped['$dhTag:$index'] = base64Encode(await _mac(chain, 'message-$index'));
      chain = Uint8List.fromList(await _mac(chain, 'chain-next'));
    }
    state['receiveChain'] = base64Encode(chain);
    state['receiveCounter'] = until;
    state['skipped'] = skipped;
  }

  Future<void> _saveSession(String peerId, String transcript, List<int> shared,
      {required List<int> localDhPrivate, required List<int> remoteDhPublic, required bool initiator}) async {
    final localDhPair = await _x25519.newKeyPairFromSeed(localDhPrivate);
    final localDhPublic = await localDhPair.extractPublicKey();
    final transcriptHash = await Sha256().hash(utf8.encode(transcript));
    final sessionId = base64UrlEncode(transcriptHash.bytes).replaceAll('=', '');
    final root = await Hkdf(hmac: _hmac, outputLength: 32).deriveKey(
      secretKey: SecretKey(shared),
      nonce: transcriptHash.bytes,
      info: utf8.encode('blousab-pair-chain-root-v1|$sessionId'),
    );
    final rootBytes = await root.extractBytes();
    final i2r = await _mac(rootBytes, 'initiator-to-responder-v1');
    final r2i = await _mac(rootBytes, 'responder-to-initiator-v1');
    final state = <String, Object>{
      'version': 2, 'sessionId': sessionId, 'peerId': peerId,
      'rootKey': base64Encode(rootBytes),
      'dhPrivate': base64Encode(localDhPrivate),
      'dhPublic': base64Encode(localDhPublic.bytes),
      'remoteDhPublic': base64Encode(remoteDhPublic),
      'sendChain': base64Encode(initiator ? i2r : r2i),
      'receiveChain': base64Encode(initiator ? r2i : i2r),
      'sendCounter': 0, 'receiveCounter': 0, 'previousSendCount': 0,
      'hasReceivedMessage': false, 'needsSendRatchet': false, 'initiator': initiator,
      'skipped': <String, String>{},
    };
    await _storage.write(key: _storageKey(peerId, sessionId), value: jsonEncode(state));
    await _storage.write(key: '${_storageKey(peerId, 'active')}', value: sessionId);
  }

  Future<Map<String, dynamic>> _load(String peerId) async {
    final sessionId = await _storage.read(key: _storageKey(peerId, 'active'));
    if (sessionId == null) throw StateError('لا توجد جلسة Ratchet؛ أعد المصافحة مع الطرف');
    final raw = await _storage.read(key: _storageKey(peerId, sessionId));
    if (raw == null) throw StateError('حالة جلسة Ratchet غير موجودة');
    final state = (jsonDecode(raw) as Map).cast<String, dynamic>();
    if (state['version'] != 2) throw StateError('جلسة Ratchet قديمة؛ أعد المصافحة الآمنة');
    return state;
  }

  Future<Map<String, Object>> encrypt({required String peerId, required String plaintext, Map<String, Object?> routingFields = const {}}) =>
      _withPeerLock(peerId, () => _encryptUnlocked(peerId: peerId, plaintext: plaintext, routingFields: routingFields));

  Future<Map<String, Object>> _encryptUnlocked({required String peerId, required String plaintext, required Map<String, Object?> routingFields}) async {
    final state = await _load(peerId);
    // After the first authenticated inbound message, rotate our DH key before
    // the next outbound packet. This is the initiator/responder transition
    // that makes the DH ratchet advance even when no remote key changed yet.
    if (state['needsSendRatchet'] == true) {
      final fresh = await _x25519.newKeyPair();
      final freshPrivate = await fresh.extractPrivateKeyBytes();
      final freshPublic = await fresh.extractPublicKey();
      final dhOutput = await _dh(freshPrivate, base64Decode(state['remoteDhPublic'].toString()));
      final step = await _kdfRoot(base64Decode(state['rootKey'].toString()), dhOutput);
      state['rootKey'] = base64Encode(step.$1);
      state['sendChain'] = base64Encode(step.$2);
      state['previousSendCount'] = state['sendCounter'] as int;
      state['sendCounter'] = 0;
      state['dhPrivate'] = base64Encode(freshPrivate);
      state['dhPublic'] = base64Encode(freshPublic.bytes);
      state['needsSendRatchet'] = false;
    }
    final counter = state['sendCounter'] as int;
    final chain = base64Decode(state['sendChain'].toString());
    final messageKey = await _mac(chain, 'message-$counter');
    final nextChain = await _mac(chain, 'chain-next');
    final sessionId = state['sessionId'].toString();
    final localId = await BlousabCryptoIdentity.instance.ensureUserId();
    final aad = utf8.encode('blousab-pair-chain-v1|$sessionId|$localId|$peerId|$counter');
    final box = await _aes.encrypt(utf8.encode(plaintext), secretKey: SecretKey(messageKey), aad: aad);
    final packet = <String, Object>{
      'type': 'blousab_pair_chain_message', 'version': 2,
      'sessionId': sessionId, 'senderId': localId,
      'recipientId': peerId, 'dhPublic': state['dhPublic'].toString(),
      'previousChainLength': state['previousSendCount'] as int, 'counter': counter,
      'nonce': base64Encode(box.nonce), 'cipherText': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
      for (final entry in routingFields.entries) if (entry.value != null) entry.key: entry.value!,
    };
    packet['signature'] = await BlousabCryptoIdentity.instance.signText(_canonical(packet));
    state['sendChain'] = base64Encode(nextChain);
    state['sendCounter'] = counter + 1;
    await _storage.write(key: _storageKey(peerId, sessionId), value: jsonEncode(state));
    return packet;
  }

  Future<String> decrypt({required String peerId, required Map packet}) =>
      _withPeerLock(peerId, () => _decryptUnlocked(peerId: peerId, packet: packet));

  Future<String> _decryptUnlocked({required String peerId, required Map packet}) async {
    final state = await _load(peerId);
    final sessionId = state['sessionId'].toString();
    final localId = await BlousabCryptoIdentity.instance.ensureUserId();
    if (packet['type'] != 'blousab_pair_chain_message' || packet['version'] != 2 ||
        packet['sessionId']?.toString() != sessionId || packet['senderId']?.toString() != peerId ||
        packet['recipientId']?.toString() != localId) {
      throw const FormatException('رسالة Ratchet لا تخص هذه الجلسة');
    }
    if (!await _verifySigned(packet, peerId)) throw const FormatException('توقيع رسالة Ratchet غير صحيح');
    final counter = int.tryParse('${packet['counter']}');
    final previousLength = int.tryParse('${packet['previousChainLength']}');
    final remoteDh = base64Decode(packet['dhPublic'].toString());
    if (counter == null || counter < 0 || previousLength == null || previousLength < 0 || remoteDh.length != 32) {
      throw const FormatException('حقول DH Ratchet أو عداد الرسالة غير صالحة');
    }
    final skipped = (state['skipped'] as Map).cast<String, String>();
    final oldRemote = base64Decode(state['remoteDhPublic'].toString());
    final tag = base64UrlEncode(remoteDh).replaceAll('=', '');
    List<int> messageKey;
    final delayedKey = !_sameBytes(remoteDh, oldRemote) ? skipped.remove('$tag:$counter') : null;
    if (!_sameBytes(remoteDh, oldRemote) && delayedKey != null) {
      // This packet belongs to a previous DH chain. Its one-time skipped key
      // was derived when that chain was retired; do not roll the DH ratchet back.
      messageKey = base64Decode(delayedKey);
      final aad = utf8.encode('blousab-pair-chain-v1|$sessionId|${packet['senderId']}|${packet['recipientId']}|$counter');
      final clear = await _aes.decrypt(
        SecretBox(base64Decode(packet['cipherText'].toString()),
          nonce: base64Decode(packet['nonce'].toString()),
          mac: Mac(base64Decode(packet['mac'].toString()))),
        secretKey: SecretKey(messageKey), aad: aad,
      );
      state['skipped'] = skipped;
      await _storage.write(key: _storageKey(peerId, sessionId), value: jsonEncode(state));
      return utf8.decode(clear);
    }
    if (!_sameBytes(remoteDh, oldRemote)) {
      await _skipUntil(state, previousLength, base64UrlEncode(oldRemote).replaceAll('=', ''));
      final receiveDh = await _dh(base64Decode(state['dhPrivate'].toString()), remoteDh);
      final receiveStep = await _kdfRoot(base64Decode(state['rootKey'].toString()), receiveDh);
      state['rootKey'] = base64Encode(receiveStep.$1);
      state['receiveChain'] = base64Encode(receiveStep.$2);
      state['remoteDhPublic'] = base64Encode(remoteDh);
      state['previousSendCount'] = state['sendCounter'];
      state['sendCounter'] = 0;
      state['receiveCounter'] = 0;
      final fresh = await _x25519.newKeyPair();
      final freshPrivate = await fresh.extractPrivateKeyBytes();
      final freshPublic = await fresh.extractPublicKey();
      final sendDh = await _dh(freshPrivate, remoteDh);
      final sendStep = await _kdfRoot(base64Decode(state['rootKey'].toString()), sendDh);
      state['rootKey'] = base64Encode(sendStep.$1);
      state['sendChain'] = base64Encode(sendStep.$2);
      state['dhPrivate'] = base64Encode(freshPrivate);
      state['dhPublic'] = base64Encode(freshPublic.bytes);
      state['hasReceivedMessage'] = true;
      state['needsSendRatchet'] = false;
    }
    final current = state['receiveCounter'] as int;
    if (counter < current) {
      final saved = skipped.remove('$tag:$counter');
      if (saved == null) throw const FormatException('رسالة مكررة أو مفتاحها غير متاح');
      messageKey = base64Decode(saved);
    } else {
      if (counter - current > _maxSkipped || skipped.length + (counter - current) > _maxSkipped) {
        throw const FormatException('تجاوزت الرسالة حد القفز المسموح في Ratchet');
      }
      var chain = base64Decode(state['receiveChain'].toString());
      for (var index = current; index < counter; index++) {
        skipped['$tag:$index'] = base64Encode(await _mac(chain, 'message-$index'));
        chain = Uint8List.fromList(await _mac(chain, 'chain-next'));
      }
      messageKey = await _mac(chain, 'message-$counter');
      state['receiveChain'] = base64Encode(await _mac(chain, 'chain-next'));
      state['receiveCounter'] = counter + 1;
    }
    final aad = utf8.encode('blousab-pair-chain-v1|$sessionId|${packet['senderId']}|${packet['recipientId']}|$counter');
    final clear = await _aes.decrypt(
      SecretBox(base64Decode(packet['cipherText'].toString()),
        nonce: base64Decode(packet['nonce'].toString()),
        mac: Mac(base64Decode(packet['mac'].toString()))),
      secretKey: SecretKey(messageKey), aad: aad,
    );
    if (state['hasReceivedMessage'] != true) {
      state['hasReceivedMessage'] = true;
      // Only the responder starts the first DH turn. This deterministic role
      // rule prevents both peers from advancing the root key simultaneously.
      state['needsSendRatchet'] = state['initiator'] != true;
    }
    state['skipped'] = skipped;
    await _storage.write(key: _storageKey(peerId, sessionId), value: jsonEncode(state));
    return utf8.decode(clear);
  }

  bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) { diff |= a[i] ^ b[i]; }
    return diff == 0;
  }
}
