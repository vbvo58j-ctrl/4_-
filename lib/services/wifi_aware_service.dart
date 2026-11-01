import 'dart:async';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class WifiAwarePeer {
  final String userId;
  final String userName;
  final String profilePhoto;
  final String publicKeyFingerprint;
  final String publicKey;
  const WifiAwarePeer({required this.userId, required this.userName, this.profilePhoto = '', this.publicKeyFingerprint = '', this.publicKey = ''});
}

class WifiAwareEvent {
  final String type;
  final WifiAwarePeer? peer;
  final String? message;
  final String? payload;
  const WifiAwareEvent(this.type, {this.peer, this.message, this.payload});
  factory WifiAwareEvent.fromMap(Map<dynamic, dynamic> map) {
    final id = map['userId']?.toString() ?? '';
    final name = map['userName']?.toString() ?? 'مستخدم بلوساب';
    final photo = map['profilePhoto']?.toString() ?? '';
    final fingerprint = map['publicKeyFingerprint']?.toString() ?? '';
    final publicKey = map['publicKey']?.toString() ?? '';
    return WifiAwareEvent(map['type']?.toString() ?? 'unknown',
      peer: id.isEmpty ? null : WifiAwarePeer(userId: id, userName: name, profilePhoto: photo, publicKeyFingerprint: fingerprint, publicKey: publicKey),
      message: map['message']?.toString(),
      payload: map['type']?.toString() == 'dataPacket' ? map['message']?.toString() : null);
  }
}

/// Direct nearby discovery using Android Wi-Fi Aware (NAN), without a router,
/// hotspot, Internet connection, or shared Wi-Fi LAN.
class WifiAwareService {
  WifiAwareService._();
  static final WifiAwareService instance = WifiAwareService._();
  static const MethodChannel _methods = MethodChannel('com.blousab.messenger/wifi_aware');
  static const EventChannel _events = EventChannel('com.blousab.messenger/wifi_aware_events');
  final StreamController<WifiAwareEvent> _controller = StreamController<WifiAwareEvent>.broadcast();
  StreamSubscription<dynamic>? _nativeSubscription;
  final Map<String, WifiAwarePeer> _peers = <String, WifiAwarePeer>{};
  final Set<String> _connectedPeers = <String>{};
  final Set<String> _verifiedPeerIds = <String>{};

  Stream<WifiAwareEvent> get events => _controller.stream;
  List<WifiAwarePeer> get discoveredPeers => List<WifiAwarePeer>.unmodifiable(_peers.values);
  List<String> get connectedPeerIds => List<String>.unmodifiable(_connectedPeers);

  void _ensureNativeListener() {
    if (_nativeSubscription != null) return;
    _nativeSubscription = _events.receiveBroadcastStream().listen((raw) {
      final event = WifiAwareEvent.fromMap(Map<dynamic, dynamic>.from(raw as Map));
      final peer = event.peer;
      if (event.type == 'wifiVerified' && peer != null) {
        _peers[peer.userId] = peer;
        _verifiedPeerIds.add(peer.userId);
      } else if (event.type == 'candidateLost' && peer != null) {
        _peers.remove(peer.userId);
        _verifiedPeerIds.remove(peer.userId);
      } else if (event.type == 'dataConnected' && peer != null) {
        _connectedPeers.add(peer.userId);
      } else if ((event.type == 'dataDisconnected' || event.type == 'candidateLost' || event.type == 'dataError') && peer != null) {
        _connectedPeers.remove(peer.userId);
      } else if (event.type == 'stopped') {
        _peers.clear();
        _verifiedPeerIds.clear();
        _connectedPeers.clear();
      }
      _controller.add(event);
    }, onError: (Object error) {
      _controller.add(WifiAwareEvent('error', message: error.toString()));
    });
  }

  Future<bool> isSupported() async => await _methods.invokeMethod<bool>('isSupported') ?? false;
  Future<bool> isAvailable() async => await _methods.invokeMethod<bool>('isAvailable') ?? false;

  Future<bool> requestPermission() async {
    final sdk = await _methods.invokeMethod<int>('getAndroidSdk').catchError((_) => 0) ?? 0;
    final status = sdk >= 33
      ? await Permission.nearbyWifiDevices.request()
      : await Permission.locationWhenInUse.request();
    return status.isGranted;
  }

  Future<void> start({required String userId, required String userName}) async {
    if (!await isSupported()) {
      throw PlatformException(code: 'WIFI_AWARE_UNSUPPORTED', message: 'هذا الهاتف لا يدعم Wi-Fi Aware');
    }
    if (!await isAvailable()) {
      throw PlatformException(code: 'WIFI_AWARE_UNAVAILABLE', message: 'Wi-Fi Aware غير متاح حاليًا؛ تحقق من تشغيل Wi-Fi ودعم الهاتف');
    }
    final sdk = await _methods.invokeMethod<int>('getAndroidSdk') ?? 0;
    final permission = sdk >= 33
        ? await Permission.nearbyWifiDevices.status
        : await Permission.locationWhenInUse.status;
    if (!permission.isGranted) {
      final granted = await requestPermission();
      if (!granted) {
        throw PlatformException(code: 'WIFI_AWARE_PERMISSION', message: 'يلزم السماح بصلاحية الأجهزة القريبة عبر Wi-Fi');
      }
    }

    // Keep the native event channel attached for the lifetime of this service.
    // This caches nearby peers even while the search dialog is not visible.
    _ensureNativeListener();

    // Subscribe before starting native discovery so startup failures are surfaced.
    final started = Completer<void>();
    late final StreamSubscription<WifiAwareEvent> subscription;
    subscription = events.listen((event) {
      if (started.isCompleted) return;
      if (event.type == 'started') {
        started.complete();
      } else if (event.type == 'error') {
        started.completeError(PlatformException(
          code: 'WIFI_AWARE_START_FAILED',
          message: event.message ?? 'تعذر بدء اكتشاف Wi-Fi المباشر',
        ));
      }
    });
    try {
      await _methods.invokeMethod<bool>('start', {
        'userId': userId,
        'userName': userName,
      });
      await started.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw PlatformException(
          code: 'WIFI_AWARE_TIMEOUT',
          message: 'لم يؤكد Android بدء بث Wi-Fi Aware والبحث عن الأجهزة خلال المهلة المحددة',
        ),
      );
    } finally {
      await subscription.cancel();
    }
  }

  /// Establishes a Wi-Fi Aware data path only after the user explicitly selects
  /// this discovered Blousab identity. Discovery itself never connects.
  Future<void> connectPeer(String peerId) async {
    if (!_verifiedPeerIds.contains(peerId) || !_peers.containsKey(peerId)) {
      throw PlatformException(code: 'PEER_NOT_VERIFIED', message: 'لا يمكن الاتصال قبل اكتمال مصافحة هوية مستخدم بلوساب');
    }
    await _methods.invokeMethod<bool>('connectPeer', {'peerId': peerId});
  }

  Future<void> sendPacket({required String peerId, required String payload}) async {
    if (!_connectedPeers.contains(peerId)) {
      throw PlatformException(code: 'WIFI_AWARE_NOT_CONNECTED', message: 'قناة Wi-Fi Aware غير متصلة بهذا الجهاز');
    }
    await _methods.invokeMethod<bool>('sendPacket', {'peerId': peerId, 'payload': payload});
  }

  Future<List<String>> refreshConnectedPeers() async {
    final peers = await _methods.invokeListMethod<String>('connectedPeers') ?? const <String>[];
    _connectedPeers
      ..clear()
      ..addAll(peers);
    return connectedPeerIds;
  }

  Future<void> broadcastPacket(String payload, {Set<String> excludePeerIds = const <String>{}}) async {
    await refreshConnectedPeers();
    final targets = _connectedPeers.where((id) => !excludePeerIds.contains(id)).toList(growable: false);
    if (targets.isEmpty) throw StateError('لا توجد أجهزة متصلة عبر Wi-Fi Aware');
    var sent = 0;
    Object? lastError;
    for (final peerId in targets) {
      try {
        await sendPacket(peerId: peerId, payload: payload);
        sent++;
      } catch (error) { lastError = error; }
    }
    if (sent == 0) throw StateError('تعذر الإرسال عبر Wi-Fi Aware: $lastError');
  }

  Future<void> broadcastPackets(Iterable<String> payloads, {Set<String> excludePeerIds = const <String>{}}) async {
    await refreshConnectedPeers();
    final targets = _connectedPeers.where((id) => !excludePeerIds.contains(id)).toList(growable: false);
    if (targets.isEmpty) throw StateError('لا توجد أجهزة متصلة عبر Wi-Fi Aware');
    for (final frame in payloads) {
      var sent = 0;
      Object? lastError;
      for (final peerId in targets) {
        try { await sendPacket(peerId: peerId, payload: frame); sent++; }
        catch (error) { lastError = error; }
      }
      if (sent == 0) throw StateError('انقطع إرسال إطار وسائط عبر Wi-Fi Aware: $lastError');
    }
  }

  Future<void> stop() async {
    try { await _methods.invokeMethod<bool>('stop'); } catch (_) {}
    _peers.clear();
    _verifiedPeerIds.clear();
    _connectedPeers.clear();
  }
}
