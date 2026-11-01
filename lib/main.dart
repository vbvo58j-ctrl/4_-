import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'screens/communities_screen.dart';
import 'screens/identity_trust_screen.dart';
import 'screens/developer_chat_preview_screen.dart';
import 'screens/stories_strip.dart';
import 'screens/public_feed_screen.dart';
import 'services/bluetooth_classic_service.dart';
import 'services/local_network_service.dart';
import 'services/wifi_aware_service.dart';
import 'services/notification_service.dart';
import 'services/mesh_runtime_service.dart';
import 'services/blousab_crypto_identity.dart';

const String supportUrl = 'https://wsend.co/967737414884';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try { await NotificationService.instance.initialize(); } catch (_) {}
  // Create a unique persistent peer ID before any transport starts.
  try { await BlousabCryptoIdentity.instance.ensureUserId(); } catch (_) {}
  runApp(const BlousabApp());
}

ThemeData buildBlousabTheme(bool dark) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF397BFF),
    brightness: dark ? Brightness.dark : Brightness.light,
  );
  final background = dark ? const Color(0xFF070914) : const Color(0xFFF4F6FF);
  final surface = dark ? const Color(0xFF111629) : Colors.white;
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'sans-serif',
    scaffoldBackgroundColor: background,
    canvasColor: background,
    dividerColor: scheme.outlineVariant.withOpacity(.65),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: background,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      iconTheme: IconThemeData(color: scheme.onSurface),
      titleTextStyle: TextStyle(color: scheme.onSurface, fontSize: 20, fontWeight: FontWeight.w600),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: scheme.outlineVariant.withOpacity(.45))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(color: scheme.onSurface, fontSize: 20, fontWeight: FontWeight.w600),
      contentTextStyle: TextStyle(color: scheme.onSurface),
    ),
    popupMenuTheme: PopupMenuThemeData(color: surface, surfaceTintColor: Colors.transparent),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF151C33) : const Color(0xFFF5F7FF),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant.withOpacity(.8)),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: scheme.outlineVariant)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: scheme.outlineVariant)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: scheme.primary, width: 1.5)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 76,
      backgroundColor: background,
      indicatorColor: scheme.primaryContainer,
      indicatorShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      surfaceTintColor: Colors.transparent,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
          fontSize: 11,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith<IconThemeData?>((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 23,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        );
      }),
    ),
    snackBarTheme: SnackBarThemeData(backgroundColor: dark ? const Color(0xFF293532) : const Color(0xFF263A36), contentTextStyle: const TextStyle(color: Colors.white)),
  );
}

class BlousabApp extends StatelessWidget {
  const BlousabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'بلوساب',
      debugShowCheckedModeBanner: false,
      theme: buildBlousabTheme(false),
      darkTheme: buildBlousabTheme(true),
      themeMode: ThemeMode.system,
      home: const BluetoothGate(),
    );
  }
}

class BluetoothGate extends StatefulWidget {
  const BluetoothGate({super.key});

  @override
  State<BluetoothGate> createState() => _BluetoothGateState();
}

class _BluetoothGateState extends State<BluetoothGate> {
  final BluetoothClassicService _bluetooth = BluetoothClassicService.instance;
  bool _checking = true;
  bool _supported = false;
  bool _enabled = false;
  bool _busy = false;
  String _status = 'جارٍ التحقق من البلوتوث…';

  @override
  void initState() {
    super.initState();
    _checkBluetooth();
  }

  Future<void> _checkBluetooth() async {
    if (mounted) setState(() { _checking = true; });
    try {
      final supported = await _bluetooth.isSupported();
      if (!supported) {
        if (mounted) setState(() {
          _supported = false;
          _enabled = false;
          _status = 'هذا الهاتف لا يدعم Bluetooth Classic.';
          _checking = false;
        });
        return;
      }
      final permissions = await _bluetooth.requestPermissions();
      if (!permissions) {
        if (mounted) setState(() {
          _supported = true;
          _enabled = false;
          _status = 'يلزم السماح بصلاحيات البلوتوث للمتابعة.';
          _checking = false;
        });
        return;
      }
      final enabled = await _bluetooth.isEnabled();
      if (!mounted) return;
      setState(() {
        _supported = true;
        _enabled = enabled;
        _status = enabled
            ? 'البلوتوث جاهز. يمكنك فتح بلوساب.'
            : 'شغّل البلوتوث للمتابعة إلى التطبيق.';
        _checking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'تعذر التحقق من البلوتوث. تحقق من الصلاحيات ثم أعد المحاولة.';
        _checking = false;
      });
    }
  }

  Future<void> _enableBluetooth() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!await _bluetooth.requestPermissions()) {
        _notice('لم تُمنح صلاحيات البلوتوث.');
        return;
      }
      if (!await _bluetooth.isEnabled()) {
        await _bluetooth.requestEnable();
        _notice('وافق على تشغيل البلوتوث في نافذة Android، ثم اضغط «إعادة التحقق».');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _checkBluetooth();
    } catch (e) {
      _notice('تعذر تشغيل البلوتوث: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    // Do not block the whole app when Bluetooth is disabled: Wi-Fi mode and settings must remain accessible.
    return const BlousabShell();

    /* Legacy Bluetooth gate UI retained below for reference.
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Icon(Icons.bluetooth, size: 54,
                      color: Theme.of(context).colorScheme.onPrimaryContainer),
                  ),
                  const SizedBox(height: 24),
                  Text('بلوساب', style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  const Text('تواصل محلي عبر Bluetooth Classic', textAlign: TextAlign.center),
                  const SizedBox(height: 18),
                  Text(_status, textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  if (_checking || _busy) const CircularProgressIndicator(),
                  if (!_checking && !_enabled) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _supported ? _enableBluetooth : null,
                        icon: const Icon(Icons.bluetooth_searching),
                        label: const Text('تشغيل البلوتوث'),
                      ),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _checkBluetooth,
                      child: const Text('إعادة التحقق'),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'لن تظهر واجهة المحادثات حتى يتم تفعيل البلوتوث.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    */
  }
}

class BlousabShell extends StatefulWidget {
  const BlousabShell({super.key});

  @override
  State<BlousabShell> createState() => _BlousabShellState();
}

class _BlousabShellState extends State<BlousabShell> with WidgetsBindingObserver {
  String _userName = 'مستخدم بلوساب';
  String _background = 'داكن';
  String _chatWallpaper = 'mint';
  String _profilePhotoPath = ''; // صورة الملف الشخصي
  int _homeTabIndex = 0; // تبدأ الواجهة بالمحادثات
  bool _lanEnabled = true;
  bool _nearbyVisible = true;
  String _connectionMode = 'bluetooth';
  double _messageFontSize = 16;
  bool _showMessageTime = true;
  bool _vibrateOnSend = true;
  bool _compactBubbles = false;
  bool _appLockEnabled = false;
  bool _appLocked = false;
  String _appLockPin = '';
  StreamSubscription<BlousabEvent>? _notificationBluetoothSubscription;
  StreamSubscription<BlousabEvent>? _notificationLanSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
    _startNotificationListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_appLockEnabled || _appLockPin.isEmpty) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (mounted) setState(() => _appLocked = true);
    }
  }

  Future<void> _manageAppLock() async {
    final prefs = await SharedPreferences.getInstance();
    final currentPin = prefs.getString('blousab_app_lock_pin') ?? '';
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    final result = await showDialog<Map<String, String>?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('قفل التطبيق'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(currentPin.isEmpty ? 'أنشئ رمزًا من 4 إلى 8 أرقام لقفل بلوساب.' : 'يمكنك تغيير رمز القفل أو إلغاء القفل من الزر أدناه.'),
          const SizedBox(height: 12),
          TextField(controller: pinController, keyboardType: TextInputType.number, obscureText: true, maxLength: 8, decoration: const InputDecoration(labelText: 'رمز القفل (4-8 أرقام)')),
          TextField(controller: confirmController, keyboardType: TextInputType.number, obscureText: true, maxLength: 8, decoration: const InputDecoration(labelText: 'تأكيد الرمز')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('رجوع')),
          if (currentPin.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(ctx, {'pin': ''}),
              child: const Text('إلغاء القفل'),
            ),
          FilledButton(onPressed: () {
            final pin = pinController.text.trim();
            final confirm = confirmController.text.trim();
            if (pin.isEmpty || pin.length < 4 || pin.length > 8 || !RegExp(r'^\d+$').hasMatch(pin) || pin != confirm) {
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('أدخل رمزًا من 4 إلى 8 أرقام وتأكد من تطابقه.'))); return;
            }
            Navigator.pop(ctx, {'pin': pin});
          }, child: const Text('حفظ'))],
      ),
    );
    pinController.dispose(); confirmController.dispose();
    if (result == null) return;
    final pin = result['pin'] ?? '';
    if (pin.isEmpty) {
      await prefs.remove('blousab_app_lock_pin');
      await prefs.setBool('blousab_app_lock_enabled', false);
      if (mounted) setState(() { _appLockEnabled = false; _appLockPin = ''; _appLocked = false; });
    } else {
      await prefs.setString('blousab_app_lock_pin', pin);
      await prefs.setBool('blousab_app_lock_enabled', true);
      if (mounted) setState(() { _appLockEnabled = true; _appLockPin = pin; _appLocked = false; });
    }
  }

  Future<void> _unlockApp() async {
    final controller = TextEditingController();
    final entered = await showDialog<String>(context: context, barrierDismissible: false, builder: (ctx) => AlertDialog(
      title: const Text('بلوساب مقفل'),
      content: TextField(controller: controller, autofocus: true, keyboardType: TextInputType.number, obscureText: true, decoration: const InputDecoration(labelText: 'أدخل رمز القفل')),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('فتح التطبيق'))],
    ));
    controller.dispose();
    if (entered == _appLockPin && mounted) setState(() => _appLocked = false);
    else if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('رمز القفل غير صحيح.')));
  }

  void _startNotificationListeners() {
    _notificationBluetoothSubscription = BluetoothClassicService.instance.events.listen((event) {
      if (event.type == 'message' && event.message != null) {
        _notifyForIncoming(event.message!);
      }
    });
    _notificationLanSubscription = LocalNetworkService.instance.events.listen((event) {
      if (event.type == 'message' && event.message != null) {
        _notifyForIncoming(event.message!);
      }
    });
  }

  Future<void> _notifyForIncoming(String raw) async {
    final currentUserId = await BlousabCryptoIdentity.instance.ensureUserId();
    await NotificationService.instance.handleIncomingPayload(raw, currentUserId: currentUserId);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _notificationBluetoothSubscription?.cancel();
    _notificationLanSubscription?.cancel();
    MeshRuntimeService.instance.dispose();
    super.dispose();
  }

  Future<void> _startBluetoothListener() async {
    try {
      await BluetoothClassicService.instance.startServer();
    } catch (_) {
      // The user can start listening from the Bluetooth action if Android
      // has just returned from the system permission/enable dialog.
    }
  }

  Future<void> _startNearbyVisibility() async {
    // Prepare the Blousab identity before accepting RFCOMM candidates. A peer is
    // never announced as a Blousab user until the reciprocal protocol handshake.
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = await BlousabCryptoIdentity.instance.ensureUserId();
      final photo = prefs.getString('wasl_profile_photo') ?? '';
      final service = BluetoothClassicService.instance;
      if (await service.isSupported() && await service.isEnabled()) {
        final signedIdentity = await BlousabCryptoIdentity.instance
            .createSignedDiscoveryIdentity(
          userId: userId,
          userName: _userName,
          profilePhoto: photo,
        );
        await service.setIdentity(
          userId: userId,
          userName: _userName,
          profilePhoto: photo,
          publicKey: BlousabCryptoIdentity.instance.publicKeyBase64,
          signature: signedIdentity['signature']!,
          signedPayload: signedIdentity['payload']!,
        );
        await service.startServer();
        await service.requestDiscoverable();
      }
    } catch (_) {
      // Bluetooth visibility is best-effort; Wi-Fi Aware remains an independent path.
    }
  }

  Future<void> _setNearbyVisibility(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('blousab_nearby_visible', enabled);
    if (!mounted) return;
    setState(() => _nearbyVisible = enabled);
    if (enabled) {
      await _startNearbyVisibility();
      final userId = await BlousabCryptoIdentity.instance.ensureUserId();
      try { await WifiAwareService.instance.start(userId: userId, userName: _userName); } catch (_) {}
      try {
        await LocalNetworkService.instance.start(userId: userId, userName: _userName);
      } catch (_) {}
    } else {
      try { await WifiAwareService.instance.stop(); } catch (_) {}
      try { await BluetoothClassicService.instance.stopServer(); } catch (_) {}
      try { await LocalNetworkService.instance.stop(); } catch (_) {}
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _userName = prefs.getString('wasl_user_name') ?? 'مستخدم بلوساب';
      _background = prefs.getString('wasl_background') ?? 'داكن';
      _chatWallpaper = prefs.getString('wasl_chat_wallpaper') ?? 'mint';
      _profilePhotoPath = prefs.getString('wasl_profile_photo') ?? '';
      _lanEnabled = prefs.getBool('blousab_lan_enabled') ?? true;
      _nearbyVisible = prefs.getBool('blousab_nearby_visible') ?? true;
      _connectionMode = 'both';
      _messageFontSize = (prefs.getDouble('blousab_message_font_size') ?? 16).clamp(14, 22).toDouble();
      _showMessageTime = prefs.getBool('blousab_show_message_time') ?? true;
      _vibrateOnSend = prefs.getBool('blousab_vibrate_on_send') ?? true;
      _compactBubbles = prefs.getBool('blousab_compact_bubbles') ?? false;
      _appLockEnabled = false;
      _appLockPin = '';
      _appLocked = _appLockEnabled && _appLockPin.isNotEmpty;
    });
    await _requestInitialPermissionsOnce(prefs);
    final meshUserId = await BlousabCryptoIdentity.instance.ensureUserId();
    // Attach the app-scoped mesh listeners before starting either transport so
    // the first verified/connected events cannot be missed during startup.
    await MeshRuntimeService.instance.start(userId: meshUserId, userName: _userName);
    // Start Android's foreground execution host only after the first-run
    // permission flow. The host notification is explicit; actual sockets still
    // belong to MainActivity until the transport migration is completed.
    if (Platform.isAndroid) {
      try {
        await const MethodChannel('com.blousab.messenger/background_runtime').invokeMethod<bool>('start');
      } catch (error) {
        debugPrint('Blousab background host could not start: $error');
      }
    }
    await _ensureBluetoothOnLaunch();
    if (_nearbyVisible) {
      await _startNearbyVisibility();
      final id = await BlousabCryptoIdentity.instance.ensureUserId();
      try { await WifiAwareService.instance.start(userId: id, userName: _userName); } catch (_) {}
    }
    if (_nearbyVisible) {
      final id = await BlousabCryptoIdentity.instance.ensureUserId();
      try { await LocalNetworkService.instance.start(userId: id, userName: _userName); } catch (_) {}
    }
  }

  Future<void> _ensureBluetoothOnLaunch() async {
    try {
      final service = BluetoothClassicService.instance;
      if (!await service.isSupported()) return;
      // If permission was denied on the first-run request, do not keep prompting.
      final sdk = await service.getAndroidSdk();
      if (sdk >= 31) {
        final connect = await Permission.bluetoothConnect.status;
        final scan = await Permission.bluetoothScan.status;
        final advertise = await Permission.bluetoothAdvertise.status;
        if (!connect.isGranted || !scan.isGranted || !advertise.isGranted) return;
      }
      if (!await service.isEnabled()) {
        // Android displays its own approval dialog; apps cannot silently turn BT on.
        await service.requestEnable();
      }
      if (await service.isEnabled()) {
        await service.startServer();
      }
    } catch (_) {
      // Keep the rest of the app usable if the user declines or the device disallows it.
    }
  }

  /// Android runtime/special permissions are requested during first app setup,
  /// not from a persistent settings row. Android may still show system approval UI.
  Future<void> _requestInitialPermissionsOnce(SharedPreferences prefs) async {
    if (prefs.getBool('blousab_initial_permissions_attempted') == true) return;
    // Set first to prevent repeated prompts if Android pauses/recreates the app.
    await prefs.setBool('blousab_initial_permissions_attempted', true);
    try {
      final sdk = await BluetoothClassicService.instance.getAndroidSdk();
      if (sdk >= 31) {
        await <Permission>[
          Permission.bluetoothConnect,
          Permission.bluetoothScan,
          Permission.bluetoothAdvertise,
        ].request();
      } else if (sdk > 0 && sdk <= 30) {
        await Permission.locationWhenInUse.request();
      }
    } catch (_) {}
    try { await Permission.nearbyWifiDevices.request(); } catch (_) {}
    try { await Permission.notification.request(); } catch (_) {}
    // Overlay permission is special access: Android requires a separate user
    // confirmation screen, so this can never be silently granted at install.
    try {
      if (!await Permission.systemAlertWindow.isGranted) {
        await Permission.systemAlertWindow.request();
      }
    } catch (_) {}
  }

  Future<String?> _pickAndStoreProfilePhoto() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 65,
        maxWidth: 640,
      );
      if (picked == null) return null;
      // Gallery providers may return temporary/cache paths. Copy the image
      // into the app's documents directory so the profile photo persists.
      final directory = await getApplicationDocumentsDirectory();
      final profileDirectory = Directory('${directory.path}/profile');
      if (!await profileDirectory.exists()) {
        await profileDirectory.create(recursive: true);
      }
      final extension = picked.path.contains('.')
          ? picked.path.substring(picked.path.lastIndexOf('.'))
          : '.jpg';
      final destination = File(
        '${profileDirectory.path}/profile_photo${extension.toLowerCase()}',
      );
      if (await destination.exists()) await destination.delete();
      await File(picked.path).copy(destination.path);
      return destination.path;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر اختيار الصورة. تحقق من صلاحية الوصول للصور ثم حاول مجددًا.')),
        );
      }
      return null;
    }
  }

  Future<void> _announceProfileUpdate({required String userId, required String userName}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final path = prefs.getString('wasl_profile_photo') ?? '';
      String? photo;
      if (path.isNotEmpty) {
        final file = File(path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty && bytes.length <= 100 * 1024) {
            photo = base64Encode(bytes);
          }
        }
      }
      final packet = jsonEncode({
        'type': 'profile_update',
        'senderId': userId,
        'senderName': userName,
        if (photo != null) 'senderPhoto': photo,
      });

      // Send updates to Bluetooth peers used in previous direct conversations.
      final addresses = <String>{};
      for (final key in prefs.getKeys()) {
        if (key.startsWith('blousab_last_device_dm_')) {
          final address = prefs.getString(key);
          if (address != null && address.isNotEmpty && !address.startsWith('lan:')) {
            addresses.add(address);
          }
        }
      }
      for (final address in addresses) {
        try {
          await BluetoothClassicService.instance.sendMessage(address: address, message: packet);
        } catch (_) {
          // A saved peer may be offline; the next handshake/message refreshes the profile.
        }
      }

      // Also publish to discovered peers on the same local Wi-Fi network.
      try {
        if (LocalNetworkService.instance.isRunning) {
          await LocalNetworkService.instance.broadcastMessage(packet);
        }
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> _manageConnectivityPermissions() async {
    final messages = <String>[];
    try {
      final bluetoothStatuses = await <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
      ].request();
      final bluetoothGranted = bluetoothStatuses.values.every((status) => status.isGranted);
      messages.add(bluetoothGranted
          ? 'صلاحيات البلوتوث: ممنوحة.'
          : 'بعض صلاحيات البلوتوث لم تُمنح؛ يمكنك السماح بها من إعدادات التطبيق.');
    } catch (_) {
      messages.add('تعذر طلب صلاحيات البلوتوث تلقائيًا على هذا الإصدار.');
    }
    try {
      final wifiStatus = await Permission.nearbyWifiDevices.request();
      messages.add(wifiStatus.isGranted
          ? 'صلاحية أجهزة Wi-Fi القريبة: ممنوحة.'
          : 'صلاحية أجهزة Wi-Fi القريبة غير ممنوحة أو غير مطلوبة على هذا الهاتف.');
    } catch (_) {
      // Permission is not available on every Android version.
    }
    // Battery optimization exemption is special Android access. Check it
    // through the native API and open Android's official consent screen.
    try {
      const batteryChannel = MethodChannel('com.blousab.messenger/battery');
      var exempt = await batteryChannel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
      if (!exempt && Platform.isAndroid) {
        messages.add('تحسينات البطارية: غير مستثنى.');
        // Keep this action explicit and user-initiated from the permissions dialog.
      } else {
        messages.add(exempt
            ? 'العمل دون قيود تحسينات البطارية: مفعّل.'
            : 'حالة تحسينات البطارية غير متاحة على هذا النظام.');
      }
    } catch (_) {
      messages.add('تعذر التحقق من حالة استثناء تحسينات البطارية.');
    }
    try {
      final overlay = await Permission.systemAlertWindow.status;
      if (!overlay.isGranted) {
        final result = await Permission.systemAlertWindow.request();
        messages.add(result.isGranted
            ? 'السماح بالظهور فوق التطبيقات الأخرى: مفعّل.'
            : 'لتفعيل الظهور فوق التطبيقات الأخرى، فعّله من صفحة إعدادات أندرويد التي فتحت.');
      } else {
        messages.add('السماح بالظهور فوق التطبيقات الأخرى: مفعّل بالفعل.');
      }
    } catch (_) {
      messages.add('افتح معلومات تطبيق بلوساب في إعدادات أندرويد لتفعيل الظهور فوق التطبيقات الأخرى.');
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('صلاحيات بلوساب'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final message in messages) Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('• $message'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.battery_saver),
              label: const Text('إعدادات تحسين البطارية'),
              onPressed: () async {
                try {
                  const batteryChannel = MethodChannel('com.blousab.messenger/battery');
                  await batteryChannel.invokeMethod<bool>('requestIgnoreBatteryOptimizations');
                } catch (_) {
                  try { await openAppSettings(); } catch (_) {}
                }
              },
            ),
            const Text('بعد الرجوع من إعدادات أندرويد، افتح صفحة الصلاحيات مرة أخرى للتحقق من الحالة. هذا الاستثناء يساعد على استمرار العمل في الخلفية لكنه لا يلغي جميع قيود النظام.'),
          ]),
        ),
        actions: [
          TextButton(onPressed: () async { Navigator.pop(dialogContext); await openAppSettings(); }, child: const Text('إعدادات التطبيق')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('تم')),
        ],
      ),
    );
  }

  Future<void> _openSettings() async {
    final nameController = TextEditingController(text: _userName);
    String selectedBackground = _background;
    String selectedWallpaper = _chatWallpaper;
    String selectedPhotoPath = _profilePhotoPath;
    bool photoWasPicked = false;
    bool selectedNearbyVisible = _nearbyVisible;
    double selectedFontSize = _messageFontSize;
    bool selectedShowTime = _showMessageTime;
    bool selectedVibrate = _vibrateOnSend;
    bool selectedCompact = _compactBubbles;
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => Theme(
        // Rebuild the entire settings theme when the user changes appearance.
        // Builder below ensures Theme.of(context) reads this theme, not the page theme.
        data: buildBlousabTheme(selectedBackground == 'داكن'),
        child: Builder(
          builder: (context) => AlertDialog(
          insetPadding: EdgeInsets.zero,
          constraints: const BoxConstraints.expand(),
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          elevation: 0,
          backgroundColor: Theme.of(context).colorScheme.surface,
          titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
          contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          title: Row(children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.settings_outlined, color: Theme.of(context).colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: 12),
            const Expanded(child: Text('الإعدادات', style: TextStyle(fontWeight: FontWeight.bold))),
            IconButton(
              tooltip: 'إغلاق الإعدادات',
              onPressed: () => Navigator.pop(dialogContext),
              icon: const Icon(Icons.close),
            ),
          ]),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.45),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(children: [
                    GestureDetector(
                      onTap: () async {
                        final path = await _pickAndStoreProfilePhoto();
                        if (path != null) setDialogState(() { selectedPhotoPath = path; photoWasPicked = true; });
                      },
                      child: Stack(alignment: Alignment.bottomRight, children: [
                        CircleAvatar(
                          radius: 43,
                          backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.15),
                          backgroundImage: selectedPhotoPath.isNotEmpty && File(selectedPhotoPath).existsSync() ? FileImage(File(selectedPhotoPath)) : null,
                          child: selectedPhotoPath.isEmpty || !File(selectedPhotoPath).existsSync() ? const Icon(Icons.person, size: 48) : null,
                        ),
                        CircleAvatar(radius: 14, child: const Icon(Icons.camera_alt, size: 16)),
                      ]),
                    ),
                    const SizedBox(height: 8),
                    Text(nameController.text.trim().isEmpty ? 'مستخدم بلوساب' : nameController.text.trim(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                    const SizedBox(height: 3),
                    Text('اضغط على الصورة لتغييرها', style: Theme.of(context).textTheme.bodySmall),
                    if (selectedPhotoPath.isNotEmpty)
                      TextButton.icon(onPressed: () => setDialogState(() => selectedPhotoPath = ''), icon: const Icon(Icons.delete_outline), label: const Text('إزالة الصورة')),
                  ]),
                ),
                TextField(
                  controller: nameController,
                  maxLength: 40,
                  decoration: const InputDecoration(
                    labelText: 'اسم المستخدم',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: selectedBackground,
                  decoration: const InputDecoration(
                    labelText: 'مظهر التطبيق',
                    prefixIcon: Icon(Icons.palette_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'افتراضي', child: Text('افتراضي')),
                    DropdownMenuItem(value: 'فاتح', child: Text('فاتح')),
                    DropdownMenuItem(value: 'داكن', child: Text('داكن')),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => selectedBackground = value);
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: selectedWallpaper,
                  decoration: const InputDecoration(
                    labelText: 'خلفية المحادثة',
                    prefixIcon: Icon(Icons.wallpaper_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'mint', child: Text('أخضر هادئ')),
                    DropdownMenuItem(value: 'cream', child: Text('كريمي')),
                    DropdownMenuItem(value: 'plain', child: Text('أبيض بسيط')),
                    DropdownMenuItem(value: 'night', child: Text('داكن')),
                  ],
                  onChanged: (value) { if (value != null) setDialogState(() => selectedWallpaper = value); },
                ),
                const SizedBox(height: 8),
                Card(
                  child: SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    secondary: const Icon(Icons.visibility_outlined),
                    title: const Text('مرئي للأجهزة التي حولك', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text('تشغيل الظهور التلقائي عبر Bluetooth والشبكة المحلية عند فتح بلوساب. قد يطلب Android موافقة إضافية.'),
                    value: selectedNearbyVisible,
                    onChanged: (value) => setDialogState(() => selectedNearbyVisible = value),
                  ),
                ),
                const SizedBox(height: 8),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Row(children: [Icon(Icons.chat_bubble_outline), SizedBox(width: 8), Text('تخصيص المحادثات', style: TextStyle(fontWeight: FontWeight.bold))]),
                      const SizedBox(height: 8),
                      Row(children: [const Expanded(child: Text('حجم نص الرسائل')), Text('${selectedFontSize.round()}')]),
                      Slider(value: selectedFontSize, min: 14, max: 22, divisions: 8, label: '${selectedFontSize.round()}', onChanged: (value) => setDialogState(() => selectedFontSize = value)),
                      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('إظهار وقت الرسالة'), subtitle: const Text('عرض وقت الإرسال أسفل كل رسالة'), value: selectedShowTime, onChanged: (value) => setDialogState(() => selectedShowTime = value)),
                      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('فقاعات مضغوطة'), subtitle: const Text('عرض رسائل أكثر على الشاشة'), value: selectedCompact, onChanged: (value) => setDialogState(() => selectedCompact = value)),
                      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('اهتزاز خفيف عند الإرسال'), subtitle: const Text('اهتزاز محلي عند إرسال الرسالة بنجاح'), value: selectedVibrate, onChanged: (value) => setDialogState(() => selectedVibrate = value)),
                    ]),
                  ),
                ),
                const SizedBox(height: 8),
                const SizedBox(height: 8),
                const SizedBox(height: 8),
                const SizedBox(height: 10),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.qr_code_2, color: Color(0xFF128C7E)),
                    title: const Text('هوية بلوساب الآمنة وQR', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text('اعرض رمز هويتك أو امسح رمز مستخدم آخر وقارن البصمة قبل توثيقه'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () async {
                      final id = await BlousabCryptoIdentity.instance.ensureUserId();
                      if (!context.mounted) return;
                      Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => IdentityTrustScreen(userId: id, userName: _userName, profilePhotoPath: _profilePhotoPath),
                      ));
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.preview_outlined, color: Color(0xFF128C7E)),
                    title: const Text('محادثة وهمية تجريبية (للمطور)', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text('معاينة واجهة المحادثة وتجربة شكل الرسائل دون اتصال'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () {
                      Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => const DeveloperChatPreviewScreen(),
                      ));
                    },
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF9800),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.support_agent, color: Colors.blue, size: 30),
                      title: const Text('التواصل مع المطور', style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),
                      subtitle: const Text('للاقتراحات والمساعدة', style: TextStyle(color: Colors.blue)),
                      trailing: const Icon(Icons.open_in_new, color: Colors.blue),
                      onTap: _openSupport,
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                const Text(
                  'تُحفظ هذه الإعدادات على هذا الهاتف. لا تُزامَن تلقائيًا مع الأجهزة الأخرى.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: () => Navigator.pop(dialogContext),
                icon: const Icon(Icons.close),
                label: const Text('إلغاء'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              )),
              const SizedBox(width: 12),
              Expanded(child: FilledButton.icon(
                onPressed: () => Navigator.pop(dialogContext, {
                  'name': nameController.text.trim(),
                  'background': selectedBackground,
                  'wallpaper': selectedWallpaper,
                  'photoPath': selectedPhotoPath,
                  'photoWasPicked': photoWasPicked,
                  'nearbyVisible': selectedNearbyVisible,
                  'messageFontSize': selectedFontSize,
                  'showMessageTime': selectedShowTime,
                  'vibrateOnSend': selectedVibrate,
                  'compactBubbles': selectedCompact,
                }),
                icon: const Icon(Icons.save_outlined),
                label: const Text('حفظ التغييرات'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              )),
            ]),
          ],
          ),
        ),
        ),
      ),
    );
    nameController.dispose();
    if (result == null) return;
    final enteredName = (result['name'] as String? ?? '').trim();
    final cleanName = enteredName.isEmpty ? 'مستخدم بلوساب' : enteredName;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('wasl_user_name', cleanName);
    await prefs.setString('wasl_background', result['background'] as String);
    await prefs.setString('wasl_chat_wallpaper', result['wallpaper'] as String? ?? 'mint');
    final photoPath = result['photoPath'] as String? ?? '';
    if (photoPath.isEmpty) { await prefs.remove('wasl_profile_photo'); } else { await prefs.setString('wasl_profile_photo', photoPath); }
    const lanEnabled = true;
    final nearbyVisible = result['nearbyVisible'] as bool? ?? true;
    await prefs.setBool('blousab_lan_enabled', lanEnabled);
    await prefs.setBool('blousab_nearby_visible', nearbyVisible);
    const connectionMode = 'both';
    await prefs.setString('blousab_connection_mode', 'both');
    final messageFontSize = (result['messageFontSize'] as double? ?? 16).clamp(14, 22).toDouble();
    final showMessageTime = result['showMessageTime'] as bool? ?? true;
    final vibrateOnSend = result['vibrateOnSend'] as bool? ?? true;
    final compactBubbles = result['compactBubbles'] as bool? ?? false;
    await prefs.setDouble('blousab_message_font_size', messageFontSize);
    await prefs.setBool('blousab_show_message_time', showMessageTime);
    await prefs.setBool('blousab_vibrate_on_send', vibrateOnSend);
    await prefs.setBool('blousab_compact_bubbles', compactBubbles);
    final userId = await BlousabCryptoIdentity.instance.ensureUserId();
    if (nearbyVisible) {
      try {
        await LocalNetworkService.instance.start(userId: userId, userName: cleanName);
      } catch (_) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر تشغيل الشبكة المحلية. تحقق من اتصال Wi-Fi.')));
      }
    } else {
      await LocalNetworkService.instance.stop();
    }
    if (!nearbyVisible) {
      try { await BluetoothClassicService.instance.stopServer(); } catch (_) {}
      try { await WifiAwareService.instance.stop(); } catch (_) {}
      try { await LocalNetworkService.instance.stop(); } catch (_) {}
    } else {
      await _startNearbyVisibility();
      try { await WifiAwareService.instance.start(userId: userId, userName: cleanName); } catch (_) {}
      try { await LocalNetworkService.instance.start(userId: userId, userName: cleanName); } catch (_) {}
    }
    final oldPhotoPath = _profilePhotoPath;
    if ((result['photoWasPicked'] as bool? ?? false) || oldPhotoPath != photoPath || _userName != cleanName) {
      await MeshRuntimeService.instance.updateIdentity(userId: userId, userName: cleanName);
      await _announceProfileUpdate(userId: userId, userName: cleanName);
    }
    if (!mounted) return;
    setState(() {
      _userName = cleanName;
      _background = result['background'] as String;
      _chatWallpaper = result['wallpaper'] as String? ?? 'mint';
      _profilePhotoPath = photoPath;
      _lanEnabled = lanEnabled;
      _nearbyVisible = nearbyVisible;
      _connectionMode = connectionMode;
      _messageFontSize = messageFontSize;
      _showMessageTime = showMessageTime;
      _vibrateOnSend = vibrateOnSend;
      _compactBubbles = compactBubbles;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(!nearbyVisible ? 'تم حفظ الإعدادات وإيقاف الظهور للأجهزة القريبة.' : 'تم حفظ الإعدادات. يعمل Bluetooth وWi-Fi تلقائيًا معًا عند توفرهما.')));
  }

  Future<void> _openSupport() async {
    // Try the WhatsApp app first, then its official HTTPS deep link.
    final targets = <Uri>[
      Uri.parse('whatsapp://send?phone=967737414884'),
      Uri.parse('https://wa.me/967737414884'),
      Uri.parse('https://api.whatsapp.com/send?phone=967737414884'),
      Uri.parse(supportUrl),
    ];
    for (final uri in targets) {
      try {
        final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (opened) return;
      } catch (_) {
        // Continue to the next compatible WhatsApp link.
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح واتساب. ثبّت التطبيق أو تأكد من اتصال الإنترنت.')),
      );
    }
  }

  Widget _buildProfileTab() {
    final photo = _profilePhotoPath;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 24),
        Center(
          child: CircleAvatar(
            radius: 48,
            backgroundImage: photo.isNotEmpty && File(photo).existsSync() ? FileImage(File(photo)) : null,
            child: photo.isEmpty || !File(photo).existsSync() ? const Icon(Icons.person, size: 48) : null,
          ),
        ),
        const SizedBox(height: 12),
        Center(child: Text(_userName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
        const SizedBox(height: 24),
        Card(
          child: ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('الإعدادات'),
            subtitle: const Text('الحساب والمظهر والخصوصية والاتصال'),
            trailing: const Icon(Icons.chevron_left),
            onTap: _openSettings,
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('تعديل الملف الشخصي'),
            subtitle: const Text('تغيير الاسم والصورة من الإعدادات'),
            trailing: const Icon(Icons.chevron_left),
            onTap: _openSettings,
          ),
        ),
      ],
    );
  }

  Future<void> _openNotifications() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [Icon(Icons.notifications_active_outlined), SizedBox(width: 8), Text('الإشعارات')]),
        content: const Text('ستظهر إشعارات الرسائل الواردة عبر بلوساب في إشعارات الهاتف. إذا لم تظهر، تحقق من سماح Android بإشعارات التطبيق.'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_appLocked && _appLockEnabled && _appLockPin.isNotEmpty) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_outline, size: 72),
                    const SizedBox(height: 18),
                    const Text(
                      'بلوساب مقفل',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text('أدخل رمز القفل للمتابعة', textAlign: TextAlign.center),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _unlockApp,
                      icon: const Icon(Icons.lock_open),
                      label: const Text('فتح التطبيق'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    final isDark = _background == 'داكن';
    return Theme(
      data: buildBlousabTheme(isDark),
      child: Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              elevation: 0,
              child: Container(
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant.withOpacity(.22), width: .6)),
                ),
                child: SizedBox(
                height: 54,
                child: Row(
                  children: [
                    const SizedBox(width: 14),
                    Container(
                      width: 34, height: 34,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(11),
                        gradient: const LinearGradient(colors: [Color(0xFF16C8FF), Color(0xFF6555FF), Color(0xFFB44CFF)]),
                        boxShadow: [BoxShadow(color: const Color(0xFF397BFF).withOpacity(.22), blurRadius: 12)],
                      ),
                      child: const Icon(Icons.forum_rounded, color: Colors.white, size: 21),
                    ),
                    const SizedBox(width: 9),
                    Expanded(child: Text('بلوساب', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: .2, color: Theme.of(context).colorScheme.onSurface))),
                    Icon(Icons.bluetooth_connected, color: Theme.of(context).colorScheme.primary, size: 19),
                    const SizedBox(width: 8),
                    Icon(Icons.wifi, color: const Color(0xFF38CFFF), size: 19),
                    IconButton(
                      tooltip: 'الإشعارات',
                      onPressed: _openNotifications,
                      icon: Icon(Icons.notifications_none_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
                ),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _homeTabIndex,
                children: [
                  const CommunitiesScreen(),
                  PublicFeedScreen(userName: _userName, profilePhotoPath: _profilePhotoPath),
                  Center(
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: StoriesStrip(userName: _userName, profilePhotoPath: _profilePhotoPath),
                      ),
                    ),
                  ),
                  _buildProfileTab(),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _homeTabIndex,
        onDestinationSelected: (index) => setState(() => _homeTabIndex = index),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline, size: 23),
            selectedIcon: Icon(Icons.chat_bubble_rounded, size: 23),
            label: 'المحادثات',
          ),
          NavigationDestination(
            icon: Icon(Icons.dynamic_feed_outlined, size: 23),
            selectedIcon: Icon(Icons.dynamic_feed_rounded, size: 23),
            label: 'المنشورات',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined, size: 23),
            selectedIcon: Icon(Icons.auto_awesome_rounded, size: 23),
            label: 'القصص',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded, size: 23),
            selectedIcon: Icon(Icons.person_rounded, size: 23),
            label: 'ملفي',
          ),
        ],
      ),     ),
    );
  }
}