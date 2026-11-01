import 'dart:async';

import 'bluetooth_classic_service.dart';
import 'wifi_aware_service.dart';
import 'blousab_crypto_identity.dart';

/// One app-wide view of nearby Blousab identities.
///
/// Security rule: only a reciprocal, signed nonce handshake over Bluetooth
/// or Wi-Fi Aware produces a displayable identity. Advertisements and matching
/// userIds alone never authorize identity merging or transport.
class NearbyPeer {
  final String userId;
  final String userName;
  final String profilePhoto;
  /// Public key belonging to the signed identity, not a display-name identifier.
  final String publicKey;
  final Set<String> bluetoothAddresses;
  final bool wifiAwareCandidate;
  final bool wifiAwareVerified;
  final DateTime lastSeen;

  const NearbyPeer({
    required this.userId,
    required this.userName,
    required this.profilePhoto,
    required this.publicKey,
    required this.bluetoothAddresses,
    required this.wifiAwareCandidate,
    required this.wifiAwareVerified,
    required this.lastSeen,
  });

  bool get bluetoothAvailable => bluetoothAddresses.isNotEmpty;
}

class NearbyPeerDirectory {
  NearbyPeerDirectory._();
  static final NearbyPeerDirectory instance = NearbyPeerDirectory._();

  final StreamController<void> _changes = StreamController<void>.broadcast();
  final Map<String, _VerifiedPeerRecord> _verified = <String, _VerifiedPeerRecord>{};
  final Map<String, String> _addressToUser = <String, String>{};
  final Map<String, String> _wifiCandidateFingerprints = <String, String>{};
  final Set<String> _wifiFingerprintMatches = <String>{};
  final Set<String> _wifiVerifiedUsers = <String>{};
  StreamSubscription<BlousabEvent>? _bluetoothSubscription;
  StreamSubscription<WifiAwareEvent>? _wifiSubscription;
  String _selfId = '';

  Stream<void> get changes => _changes.stream;
  int get pendingWifiCandidateCount => _wifiCandidateFingerprints.length;

  List<NearbyPeer> get peers => _verified.values.map((record) {
    return NearbyPeer(
      userId: record.userId,
      userName: record.userName,
      profilePhoto: record.profilePhoto,
      publicKey: record.publicKey,
      bluetoothAddresses: Set<String>.unmodifiable(record.addresses),
      // Candidate presence is informational only. It does not authorize
      // Wi-Fi routing or mark the Wi-Fi identity as authenticated.
      wifiAwareCandidate: _wifiFingerprintMatches.contains(record.userId),
      wifiAwareVerified: _wifiVerifiedUsers.contains(record.userId),
      lastSeen: record.lastSeen,
    );
  }).toList(growable: false);

  void start({required String selfUserId}) {
    if (_selfId.isNotEmpty && _selfId != selfUserId) {
      _verified.clear();
      _addressToUser.clear();
      _wifiCandidateFingerprints.clear();
      _wifiFingerprintMatches.clear();
      _wifiVerifiedUsers.clear();
    }
    _selfId = selfUserId;
    _bluetoothSubscription ??= BluetoothClassicService.instance.events.listen(_onBluetooth);
    _wifiSubscription ??= WifiAwareService.instance.events.listen(_onWifiAware);
  }

  void _onBluetooth(BlousabEvent event) {
    final id = event.userId?.trim() ?? '';
    final address = event.address?.trim() ?? '';
    if (event.type == 'blousabVerified' && id.isNotEmpty && id != _selfId && address.isNotEmpty) {
      final incomingKey = event.publicKey?.trim() ?? '';
      // A self-signed identity is bound to its Ed25519 key. Never merge two
      // different keys merely because they claim the same Blousab userId.
      if (incomingKey.isEmpty) return;
      final existingRecord = _verified[id];
      if (existingRecord != null && existingRecord.publicKey.isNotEmpty &&
          existingRecord.publicKey != incomingKey) {
        return;
      }
      final oldId = _addressToUser[address];
      if (oldId != null && oldId != id) {
        _verified[oldId]?.addresses.remove(address);
        _removeIfNoBluetooth(oldId);
      }
      _addressToUser[address] = id;
      final record = _verified.putIfAbsent(id, () => _VerifiedPeerRecord(id));
      record.addresses.add(address);
      record.publicKey = incomingKey;
      final name = event.userName?.trim() ?? '';
      if (name.isNotEmpty) record.userName = name;
      final photo = event.profilePhoto?.trim() ?? '';
      if (photo.isNotEmpty) record.profilePhoto = photo;
      record.lastSeen = DateTime.now();
      final pendingWifiFingerprint = _wifiCandidateFingerprints[id];
      if (pendingWifiFingerprint != null) {
        _matchWifiFingerprint(id, pendingWifiFingerprint);
      }
      _changes.add(null);
      return;
    }

    if (event.type == 'disconnected' && address.isNotEmpty) {
      final id = _addressToUser.remove(address);
      if (id != null) {
        _verified[id]?.addresses.remove(address);
        _removeIfNoBluetooth(id);
        _changes.add(null);
      }
    }
  }

  void _onWifiAware(WifiAwareEvent event) {
    final peer = event.peer;
    if (peer == null || peer.userId.isEmpty || peer.userId == _selfId) return;
    if (event.type == 'candidateFound') {
      final fingerprint = peer.publicKeyFingerprint.trim();
      if (fingerprint.isNotEmpty) {
        _wifiCandidateFingerprints[peer.userId] = fingerprint;
        _matchWifiFingerprint(peer.userId, fingerprint);
      }
      _changes.add(null);
    } else if (event.type == 'wifiVerified') {
      final key = peer.publicKey.trim();
      if (key.isEmpty) return;
      final existing = _verified[peer.userId];
      if (existing != null && existing.publicKey.isNotEmpty && existing.publicKey != key) return;
      for (final other in _verified.values) {
        if (other.userId != peer.userId && other.publicKey == key) return;
      }
      final record = _verified.putIfAbsent(peer.userId, () => _VerifiedPeerRecord(peer.userId));
      record.publicKey = key;
      if (peer.userName.trim().isNotEmpty) record.userName = peer.userName;
      if (peer.profilePhoto.trim().isNotEmpty) record.profilePhoto = peer.profilePhoto;
      record.lastSeen = DateTime.now();
      _wifiVerifiedUsers.add(peer.userId);
      _wifiCandidateFingerprints.remove(peer.userId);
      _wifiFingerprintMatches.add(peer.userId);
      _changes.add(null);
    } else if (event.type == 'candidateLost') {
      _wifiCandidateFingerprints.remove(peer.userId);
      _wifiFingerprintMatches.remove(peer.userId);
      _wifiVerifiedUsers.remove(peer.userId);
      _removeIfNoBluetooth(peer.userId);
      _changes.add(null);
    }
  }

  Future<void> _matchWifiFingerprint(String userId, String advertised) async {
    final record = _verified[userId];
    if (record == null || record.publicKey.isEmpty) return;
    try {
      final expected = await BlousabCryptoIdentity.instance.fingerprintFor(record.publicKey);
      // Ignore stale async results if a newer candidate replaced this one.
      if (_wifiCandidateFingerprints[userId] != advertised) return;
      if (expected.replaceAll(RegExp(r'\s+'), '').toLowerCase() ==
          advertised.replaceAll(RegExp(r'\s+'), '').toLowerCase()) {
        _wifiFingerprintMatches.add(userId);
      } else {
        _wifiFingerprintMatches.remove(userId);
      }
      _changes.add(null);
    } catch (_) {
      _wifiFingerprintMatches.remove(userId);
      _changes.add(null);
    }
  }

  void _removeIfNoBluetooth(String id) {
    final record = _verified[id];
    if (record != null && record.addresses.isEmpty && !_wifiVerifiedUsers.contains(id)) _verified.remove(id);
  }

  void stop() {
    _bluetoothSubscription?.cancel();
    _bluetoothSubscription = null;
    _wifiSubscription?.cancel();
    _wifiSubscription = null;
    _verified.clear();
    _addressToUser.clear();
    _wifiCandidateFingerprints.clear();
    _wifiFingerprintMatches.clear();
    _wifiVerifiedUsers.clear();
    _changes.add(null);
  }
}

class _VerifiedPeerRecord {
  _VerifiedPeerRecord(this.userId);
  final String userId;
  String userName = 'مستخدم بلوساب';
  String profilePhoto = '';
  String publicKey = '';
  final Set<String> addresses = <String>{};
  DateTime lastSeen = DateTime.now();
}
