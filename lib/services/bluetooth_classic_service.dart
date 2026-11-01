
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'blousab_crypto_identity.dart';

class BlousabDevice {
  final String name;
  final String address;

  const BlousabDevice({required this.name, required this.address});

  factory BlousabDevice.fromMap(Map<dynamic, dynamic> map) {
    return BlousabDevice(
      name: map['name']?.toString() ?? 'جهاز',
      address: map['address']?.toString() ?? '',
    );
  }
}

class BlousabEvent {
  final String type;
  final String? address;
  final String? name;
  final String? message;
  final String? userId;
  final String? userName;
  final String? profilePhoto;
  /// Ed25519 public key verified by the native mutual-nonce handshake.
  final String? publicKey;
  final int? eventId;

  const BlousabEvent({
    required this.type,
    this.address,
    this.name,
    this.message,
    this.userId,
    this.userName,
    this.profilePhoto,
    this.publicKey,
    this.eventId,
  });

  factory BlousabEvent.fromMap(Map<dynamic, dynamic> map) {
    return BlousabEvent(
      type: map['type']?.toString() ?? 'unknown',
      address: map['address']?.toString(),
      name: map['name']?.toString(),
      message: map['message']?.toString(),
      userId: map['userId']?.toString(),
      userName: map['userName']?.toString(),
      profilePhoto: map['profilePhoto']?.toString(),
      publicKey: map['publicKey']?.toString(),
      eventId: int.tryParse(map['eventId']?.toString() ?? ''),
    );
  }
}

class BluetoothClassicService {
  BluetoothClassicService._() {
    _methods.setMethodCallHandler(_handleNativeMethodCall);
  }

  static final BluetoothClassicService instance = BluetoothClassicService._();

  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    if (call.method == 'signHandshakeTranscript') {
      final arguments = call.arguments;
      final text = arguments is Map ? (arguments['text']?.toString() ?? '') : '';
      if (text.isEmpty || text.length > 2048) {
        throw PlatformException(
          code: 'INVALID_TRANSCRIPT',
          message: 'بيانات تحدي المصافحة غير صالحة',
        );
      }
      return BlousabCryptoIdentity.instance.signText(text);
    }
    throw MissingPluginException('النداء غير مدعوم: ${call.method}');
  }

  static const MethodChannel _methods =
      MethodChannel('com.blousab.messenger/bluetooth');

  static const EventChannel _events =
      EventChannel('com.blousab.messenger/events');

  Stream<BlousabEvent>? _stream;
  final Set<int> _seenServiceEventIds = <int>{};

  Future<void> _acknowledgeServiceEvent(int eventId) async {
    try {
      await _methods.invokeMethod<bool>('ackSessionEvent', {'eventId': eventId});
    } catch (_) {
      // A later service reattachment will replay the unacknowledged event.
    }
  }

  Stream<BlousabEvent> get events {
    return _stream ??= _events.receiveBroadcastStream().asyncExpand((raw) async* {
      final map = Map<dynamic, dynamic>.from(raw as Map);
      final event = BlousabEvent.fromMap(map);
      final id = event.eventId;
      if (id != null) {
        if (!_seenServiceEventIds.add(id)) {
          await _acknowledgeServiceEvent(id);
          return;
        }
        if (_seenServiceEventIds.length > 512) {
          final ordered = _seenServiceEventIds.toList(growable: false);
          _seenServiceEventIds.removeAll(ordered.take(256));
        }
        // Yield to all broadcast subscribers before acknowledging the service
        // queue entry. If the host disappears first, the service replays it.
        yield event;
        await _acknowledgeServiceEvent(id);
        return;
      }
      yield event;
    }).asBroadcastStream();
  }

  Future<bool> requestPermissions() async {
    final sdk = await getAndroidSdk();
    if (sdk >= 31) {
      // Permissions are requested once during first app setup. Later operations
      // only check their status and do not repeatedly show permission dialogs.
      final connect = await Permission.bluetoothConnect.status;
      final scan = await Permission.bluetoothScan.status;
      final advertise = await Permission.bluetoothAdvertise.status;
      return connect.isGranted && scan.isGranted && advertise.isGranted;
    }
    // Legacy Bluetooth connect/listen does not need a runtime permission.
    // Location permission is requested during first app setup for discovery.
    return true;
  }

  Future<int> getAndroidSdk() async =>
      await _methods.invokeMethod<int>('getAndroidSdk') ?? 0;

  Future<void> requestDiscoverable() async {
    await _ensurePermission();
    await _methods.invokeMethod<bool>('requestDiscoverable');
  }

  Future<void> startDiscovery() async {
    await _ensurePermission();
    if (await getAndroidSdk() < 31) {
      final location = await Permission.locationWhenInUse.status;
      if (!location.isGranted) {
        throw PlatformException(
          code: 'DISCOVERY_PERMISSION_DENIED',
          message: 'لم تُمنح صلاحية الموقع أثناء إعداد التطبيق الأولي؛ افتح أذونات أندرويد لتفعيلها.',
        );
      }
    }
    await _methods.invokeMethod<bool>('startDiscovery');
  }

  /// Performs a short-lived Blousab handshake against a low-level scan
  /// candidate. A successful result emits blousabVerified but does not retain
  /// the RFCOMM socket or start a chat connection.
  Future<bool> verifyCandidate(String address) async {
    await _ensurePermission();
    if (address.isEmpty) return false;
    try {
      return await _methods.invokeMethod<bool>('verifyCandidate', {'address': address}) ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> cancelDiscovery() async {
    try { await _methods.invokeMethod<bool>('cancelDiscovery'); } catch (_) {}
  }

  /// Low-level transport candidates for the internal Blousab handshake only.
  /// Callers MUST filter candidates by a verified Blousab identity before
  /// rendering them. The Android device name is transport metadata, never a
  /// user-facing profile name. This scan does not establish a chat session.
  Future<List<BlousabDevice>> discoverNearbyDevices({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    await _ensurePermission();
    final found = <String, BlousabDevice>{};
    final verifying = <String>{};
    final subscription = events.listen((event) {
      if (event.type == 'deviceFound' && event.address != null && event.address!.isNotEmpty) {
        final address = event.address!;
        found[address] = BlousabDevice(name: '', address: address);
        if (verifying.add(address)) {
          // Discovery verification is deliberately separate from a chat link.
          verifyCandidate(address).whenComplete(() => verifying.remove(address));
        }
      }
    });
    try {
      await startDiscovery();
      await Future<void>.delayed(timeout);
    } finally {
      await cancelDiscovery();
      await subscription.cancel();
    }
    return found.values.toList(growable: false);
  }

  Future<void> _ensurePermission() async {
    if (!await requestPermissions()) {
      throw PlatformException(
        code: 'PERMISSION_DENIED',
        message: 'صلاحيات البلوتوث غير ممنوحة. افتح أذونات أندرويد لتفعيلها؛ لن يكرر بلوساب نافذة الطلب تلقائيًا.',
      );
    }
  }

  Future<bool> isSupported() async {
    return await _methods.invokeMethod<bool>('isSupported') ?? false;
  }

  Future<bool> isEnabled() async {
    await _ensurePermission();
    return await _methods.invokeMethod<bool>('isEnabled') ?? false;
  }

  Future<void> requestEnable() async {
    await _ensurePermission();
    await _methods.invokeMethod<bool>('requestEnable');
  }

  Future<List<BlousabDevice>> getPairedDevices() async {
    await _ensurePermission();

    final list = await _methods.invokeMethod<List<dynamic>>(
      'getPairedDevices',
    );

    return (list ?? []).map((item) {
      return BlousabDevice.fromMap(
        Map<dynamic, dynamic>.from(item as Map),
      );
    }).toList();
  }

  Future<void> setIdentity({required String userId, required String userName, String profilePhoto = '', required String publicKey, required String signature, required String signedPayload}) async {
    await _ensurePermission();
    await _methods.invokeMethod<bool>('setIdentity', {
      'userId': userId,
      'userName': userName,
      'photo': profilePhoto,
      'publicKey': publicKey,
      'signature': signature,
      'signedPayload': signedPayload,
    });
  }

  Future<void> startServer() async {
    await _ensurePermission();
    await _methods.invokeMethod<bool>('startServer');
  }

  Future<void> connect(String address) async {
    await _ensurePermission();

    await _methods.invokeMethod<bool>(
      'connect',
      {'address': address},
    );
  }

  Future<void> sendMessage({
    required String address,
    required String message,
  }) async {
    await _ensurePermission();

    final success = await _methods.invokeMethod<bool>(
      'sendMessage',
      {'address': address, 'message': message},
    );

    if (success != true) {
      throw PlatformException(
        code: 'SEND_FAILED',
        message: 'لم يؤكد البلوتوث إرسال الرسالة.',
      );
    }
  }


  Future<void> broadcastMessage(String message) async {
    await _ensurePermission();
    final success = await _methods.invokeMethod<bool>(
      'sendMessage',
      {'address': '*', 'message': message},
    );
    if (success != true) {
      throw PlatformException(
        code: 'BROADCAST_FAILED',
        message: 'تعذر إرسال الرسالة إلى الأجهزة المتصلة.',
      );
    }
  }

  Future<void> disconnect([String? address]) async {
    await _methods.invokeMethod<bool>(
      'disconnect',
      {if (address != null) 'address': address},
    );
  }

  Future<void> stopServer() async {
    await _methods.invokeMethod<bool>('stopServer');
  }
}