import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/blousab_crypto_identity.dart';

/// QR-based out-of-band identity confirmation. Scanning only parses the payload;
/// the user must compare the two displayed fingerprints before pinning the key.
class IdentityTrustScreen extends StatefulWidget {
  final String userId;
  final String userName;
  final String profilePhotoPath;

  const IdentityTrustScreen({super.key, required this.userId, required this.userName, this.profilePhotoPath = ''});

  @override
  State<IdentityTrustScreen> createState() => _IdentityTrustScreenState();
}

class _IdentityTrustScreenState extends State<IdentityTrustScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  String? _payload;
  String? _fingerprint;
  bool _loading = true;
  bool _scanLocked = false;
  bool _comparisonConfirmed = false;
  String? _status;
  Map<String, String>? _scanned;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      final identity = BlousabCryptoIdentity.instance;
      final id = widget.userId.isNotEmpty ? widget.userId : await identity.ensureUserId();
      final payload = await identity.exportTrustPayload(userId: id);
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _payload = payload;
        _fingerprint = decoded['fingerprint']?.toString();
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _status = 'تعذر تجهيز رمز الهوية: $e'; });
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_scanLocked) return;
    final raw = capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
    if (raw == null || raw.isEmpty) return;
    _scanLocked = true;
    final identity = BlousabCryptoIdentity.instance;
    final parsed = await identity.parseTrustPayload(raw);
    final localId = await identity.ensureUserId();
    if (!mounted) return;
    if (parsed != null && parsed['userId'] == localId) {
      setState(() { _scanned = null; _status = 'لا يمكن توثيق هوية هذا الهاتف باعتبارها مستخدمًا آخر.'; });
      await Future<void>.delayed(const Duration(seconds: 2));
      _scanLocked = false;
      return;
    }
    setState(() {
      _scanned = parsed;
      _comparisonConfirmed = false;
      _status = parsed == null ? 'رمز غير صالح أو بصمته لا تطابق مفتاح الهوية.' : null;
    });
    if (parsed == null) {
      await Future<void>.delayed(const Duration(seconds: 2));
      _scanLocked = false;
    }
  }

  Future<void> _confirmTrust() async {
    final peer = _scanned;
    if (peer == null || !_comparisonConfirmed) return;
    final ok = await BlousabCryptoIdentity.instance.trustPeerKeyAfterFingerprintCheck(
      peerId: peer['userId']!, publicKeyBase64: peer['publicKey']!, e2ePublicKeyBase64: peer['e2ePublicKey']!, confirmedFingerprint: peer['fingerprint']!,
    );
    if (!mounted) return;
    setState(() {
      _status = ok ? 'تم تثبيت هوية ${peer['userId']} بعد تأكيد المقارنة.' : 'تعذر التوثيق: المفتاح غير صالح أو توجد هوية مثبتة بمفتاح مختلف.';
      if (ok) { _scanned = null; _comparisonConfirmed = false; _scanLocked = false; }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('هوية بلوساب الآمنة'), bottom: TabBar(controller: _tabs, tabs: const [Tab(icon: Icon(Icons.qr_code), text: 'رمزي'), Tab(icon: Icon(Icons.qr_code_scanner), text: 'مسح رمز') ])),
      body: _loading ? const Center(child: CircularProgressIndicator()) : TabBarView(controller: _tabs, children: [
        _buildMyCode(theme),
        _buildScanner(theme),
      ]),
    );
  }

  Widget _buildMyCode(ThemeData theme) {
    if (_payload == null) return Center(child: Text(_status ?? 'تعذر تحميل الهوية'));
    final photo = widget.profilePhotoPath;
    return ListView(padding: const EdgeInsets.all(20), children: [
      Center(child: CircleAvatar(radius: 34, backgroundImage: photo.isNotEmpty && File(photo).existsSync() ? FileImage(File(photo)) : null, child: photo.isEmpty ? const Icon(Icons.person, size: 34) : null)),
      const SizedBox(height: 10),
      Center(child: Text(widget.userName, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold))),
      const SizedBox(height: 5),
      const Center(child: Text('اعرض هذا الرمز للطرف الآخر ليمسحه ويقارن بصمة الهوية.')),
      const SizedBox(height: 24),
      Center(child: Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)), child: QrImageView(data: _payload!, version: QrVersions.auto, size: 250, backgroundColor: Colors.white))),
      const SizedBox(height: 22),
      const Text('بصمة هويتك', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      SelectableText(_fingerprint ?? '', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1)),
      const SizedBox(height: 12),
      const Text('يجب أن تتطابق البصمتان على الهاتفين قبل قبول الاتصال الأول. لا تشارك المفتاح الخاص؛ فهو لا يظهر في الرمز.', textAlign: TextAlign.center),
    ]);
  }

  Widget _buildScanner(ThemeData theme) {
    if (_scanned != null) {
      return ListView(padding: const EdgeInsets.all(20), children: [
        const Icon(Icons.verified_user_outlined, size: 54),
        const SizedBox(height: 12),
        Text('هوية بلوساب: ${_scanned!['userId']}', textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        const Text('البصمة المستخرجة من QR. قارنها يدويًا مع الهاتف الآخر قبل التوثيق:', textAlign: TextAlign.center),
        const SizedBox(height: 12),
        SelectableText(_scanned!['fingerprint'] ?? '', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1)),
        const SizedBox(height: 16),
        CheckboxListTile(value: _comparisonConfirmed, onChanged: (v) => setState(() => _comparisonConfirmed = v ?? false), controlAffinity: ListTileControlAffinity.leading, title: const Text('تحققت بنفسي من تطابق البصمة على الهاتفين'), subtitle: const Text('لا تحدد هذا الخيار إذا لم تقارن البصمتين فعليًا.'), contentPadding: EdgeInsets.zero),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: _comparisonConfirmed ? _confirmTrust : null, icon: const Icon(Icons.shield_outlined), label: const Text('تأكيد وتوثيق الهوية')),
        TextButton(onPressed: () => setState(() { _scanned = null; _comparisonConfirmed = false; _scanLocked = false; }), child: const Text('مسح رمز آخر')),
      ]);
    }
    return Column(children: [
      Expanded(child: MobileScanner(onDetect: _onDetect)),
      if (_status != null) Padding(padding: const EdgeInsets.all(12), child: Text(_status!, textAlign: TextAlign.center)),
      const Padding(padding: EdgeInsets.all(12), child: Text('وجّه الكاميرا إلى رمز هوية بلوساب. المسح لا يوثق المستخدم تلقائيًا.', textAlign: TextAlign.center)),
    ]);
  }
}
