import 'package:flutter/material.dart';

/// Local-only sandbox to preview chat UI and exercise chat controls without networking.
class DeveloperChatPreviewScreen extends StatefulWidget {
  const DeveloperChatPreviewScreen({super.key});

  @override
  State<DeveloperChatPreviewScreen> createState() => _DeveloperChatPreviewScreenState();
}

class _DeveloperChatPreviewScreenState extends State<DeveloperChatPreviewScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final List<_PreviewMessage> _messages = [
    _PreviewMessage('السلام عليكم 👋', false, '10:24 ص'),
    _PreviewMessage('وعليكم السلام، أهلًا بك في بلوساب 🌿', true, '10:24 ص'),
    _PreviewMessage('هذه محادثة تجريبية لمعاينة واجهة الدردشة.', false, '10:25 ص'),
    _PreviewMessage('جرّب الإعدادات والمرفقات وأزرار الاتصال من هنا.', true, '10:25 ص'),
    _PreviewMessage('هل تظهر الصورة والرسائل بشكل مناسب؟ 📎', false, '10:26 ص'),
  ];

  static const _green = Color(0xFF128C7E);
  static const _wallpapers = <Color>[
    Color(0xFFEAF2EE), Color(0xFFF4E8D8), Color(0xFFE5ECF8),
    Color(0xFFF4E5EF), Color(0xFF202B33), Color(0xFFF2F2F2),
  ];
  Color _wallpaper = _wallpapers[0];
  double _fontSize = 16;
  bool _showTimes = true;
  bool _compactBubbles = false;
  bool _blocked = false;
  bool _muted = false;
  bool _pinned = false;
  bool _disappearing = false;
  bool _readReceipts = true;
  bool _searching = false;
  bool _showDetails = true;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _messages.add(_PreviewMessage(text, true, TimeOfDay.now().format(context)));
      _controller.clear();
    });
    _scrollToBottom();
  }

  void _addSample(String label, {IconData? icon}) {
    setState(() => _messages.add(_PreviewMessage(label, true, TimeOfDay.now().format(context), icon: icon)));
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = _wallpaper == const Color(0xFF202B33);
    final textColor = dark ? Colors.white : const Color(0xFF202124);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor ?? Theme.of(context).colorScheme.surface,
        foregroundColor: Theme.of(context).appBarTheme.foregroundColor ?? Theme.of(context).colorScheme.onSurface,
        title: Row(children: [
          CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: Icon(Icons.person, color: Theme.of(context).colorScheme.onPrimaryContainer),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('محادثة تجريبية', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            Text(_blocked ? 'محظور (وضع تجريبي)' : 'متصل — معاينة للمطور', style: const TextStyle(fontSize: 11)),
          ])),
        ]),
        actions: [
          IconButton(tooltip: 'بحث داخل الدردشة', onPressed: () => setState(() => _searching = !_searching), icon: const Icon(Icons.search)),
          PopupMenuButton<String>(tooltip: 'خيارات المحادثة', onSelected: _handleMenu, itemBuilder: (_) => [
            const PopupMenuItem(value: 'settings', child: ListTile(dense: true, leading: Icon(Icons.tune), title: Text('إعدادات المحادثة'))),
            const PopupMenuItem(value: 'contact', child: ListTile(dense: true, leading: Icon(Icons.person_outline), title: Text('معلومات الملف الشخصي'))),
            PopupMenuItem(value: 'mute', child: ListTile(dense: true, leading: Icon(_muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined), title: Text(_muted ? 'إلغاء كتم الإشعارات' : 'كتم الإشعارات'))),
            PopupMenuItem(value: 'pin', child: ListTile(dense: true, leading: Icon(Icons.push_pin_outlined), title: Text(_pinned ? 'إلغاء التثبيت' : 'تثبيت المحادثة'))),
            PopupMenuItem(value: 'block', child: ListTile(dense: true, leading: Icon(_blocked ? Icons.lock_open : Icons.block), title: Text(_blocked ? 'فك الحظر' : 'حظر جهة الاتصال'))),
            const PopupMenuItem(value: 'clear', child: ListTile(dense: true, leading: Icon(Icons.delete_outline), title: Text('مسح محتوى الدردشة'))),
          ]),
        ],
      ),
      body: Container(
        color: _wallpaper,
        child: Column(children: [
          Container(width: double.infinity, margin: const EdgeInsets.fromLTRB(10, 8, 10, 5), padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: dark ? Colors.white10 : const Color(0xFFFFF3CD), borderRadius: BorderRadius.circular(10)),
            child: Text('وضع تجريبي: كل الخيارات والرسائل محلية ولا تتصل بأي مستخدم.', textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: dark ? Colors.white70 : const Color(0xFF765B13)))),
          if (_searching) Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: TextField(
            autofocus: true, decoration: InputDecoration(hintText: 'ابحث في الرسائل التجريبية', prefixIcon: const Icon(Icons.search), suffixIcon: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _searching = false)), filled: true, fillColor: dark ? Colors.white12 : Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none)),
            onSubmitted: (q) { final found = _messages.where((m) => m.text.contains(q)).length; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('عُثر على $found رسالة مطابقة (معاينة).'))); },
          )),
          Expanded(child: ListView.builder(controller: _scroll, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), itemCount: _messages.length,
            itemBuilder: (context, index) {
              final m = _messages[index];
              final bubbleColor = m.mine ? (dark ? const Color(0xFF24584F) : const Color(0xFFD7F8C6)) : (dark ? const Color(0xFF34414A) : Colors.white);
              return Align(alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft, child: Container(
                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .82),
                margin: EdgeInsets.symmetric(vertical: _compactBubbles ? 2 : 4),
                padding: EdgeInsets.fromLTRB(12, _compactBubbles ? 5 : 9, 9, 5),
                decoration: BoxDecoration(color: bubbleColor, borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(13), topRight: const Radius.circular(13),
                  bottomLeft: Radius.circular(m.mine ? 13 : 3), bottomRight: Radius.circular(m.mine ? 3 : 13)), boxShadow: const [BoxShadow(color: Color(0x10000000), blurRadius: 2)]),
                child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (m.icon != null) Padding(padding: const EdgeInsets.only(bottom: 4), child: Icon(m.icon, size: 40, color: _green)),
                  Align(alignment: Alignment.centerRight, child: Text(m.text, style: TextStyle(fontSize: _fontSize, color: dark ? Colors.white : textColor))),
                  if (_showTimes) const SizedBox(height: 3),
                  if (_showTimes) Row(mainAxisSize: MainAxisSize.min, children: [Text(m.time, style: TextStyle(fontSize: 10, color: dark ? Colors.white60 : Colors.black54)), if (m.mine && _readReceipts) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.done_all, size: 14, color: Colors.blue))]),
                ]),
              ));
            })),
          if (_blocked) Container(width: double.infinity, padding: const EdgeInsets.all(8), color: Colors.orange.shade100, child: const Text('جهة الاتصال محظورة في المعاينة — الإرسال معطل حتى فك الحظر.', textAlign: TextAlign.center, style: TextStyle(color: Colors.black87))),
          SafeArea(top: false, child: Container(color: dark ? const Color(0xFF172027) : const Color(0xFFF7F7F7), padding: const EdgeInsets.fromLTRB(4, 5, 6, 5), child: Row(children: [
            PopupMenuButton<String>(tooltip: 'إرفاق', icon: const Icon(Icons.add_circle_outline, color: _green), onSelected: _handleAttachment, itemBuilder: (_) => const [
              PopupMenuItem(value: 'image', child: ListTile(dense: true, leading: Icon(Icons.image), title: Text('صورة تجريبية'))),
              PopupMenuItem(value: 'camera', child: ListTile(dense: true, leading: Icon(Icons.camera_alt), title: Text('كاميرا (معاينة)'))),
              PopupMenuItem(value: 'file', child: ListTile(dense: true, leading: Icon(Icons.insert_drive_file), title: Text('ملف تجريبي'))),
              PopupMenuItem(value: 'audio', child: ListTile(dense: true, leading: Icon(Icons.headphones), title: Text('رسالة صوتية تجريبية'))),
              PopupMenuItem(value: 'location', child: ListTile(dense: true, leading: Icon(Icons.location_on), title: Text('موقع تجريبي'))),
              PopupMenuItem(value: 'contact', child: ListTile(dense: true, leading: Icon(Icons.contact_page), title: Text('جهة اتصال تجريبية'))),
            ]),
            IconButton(tooltip: 'رسالة صوتية', onPressed: () => _addSample('🎙 رسالة صوتية تجريبية • 0:08', icon: Icons.play_circle_fill), icon: const Icon(Icons.mic, color: _green)),
            Expanded(child: TextField(controller: _controller, minLines: 1, maxLines: 4, onSubmitted: (_) => _send(), decoration: InputDecoration(hintText: _blocked ? 'فك الحظر للتجربة' : 'اكتب رسالة تجريبية', filled: true, fillColor: dark ? Colors.white12 : Colors.white, contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10), border: OutlineInputBorder(borderRadius: BorderRadius.circular(25), borderSide: BorderSide.none)))),
            const SizedBox(width: 5),
            CircleAvatar(backgroundColor: _blocked ? Colors.grey : _green, child: IconButton(onPressed: _blocked ? null : _send, icon: const Icon(Icons.send, color: Colors.white, size: 19))),
          ]))),
        ]),
      ),
    );
  }

  void _handleMenu(String value) {
    switch (value) {
      case 'settings': _showChatSettings(); break;
      case 'contact': _showContactInfo(); break;
      case 'mute': setState(() => _muted = !_muted); _toast(_muted ? 'تم كتم الإشعارات في المعاينة' : 'تم إلغاء الكتم في المعاينة'); break;
      case 'pin': setState(() => _pinned = !_pinned); _toast(_pinned ? 'تم تثبيت المحادثة في المعاينة' : 'تم إلغاء التثبيت في المعاينة'); break;
      case 'block': _confirmBlock(); break;
      case 'clear': _confirmClear(); break;
    }
  }

  void _showChatSettings() {
    showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, builder: (sheetContext) => StatefulBuilder(builder: (context, setSheetState) => SafeArea(child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 24), child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('إعدادات المحادثة التجريبية', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6), const Text('غيّر الإعدادات وشاهد تأثيرها فورًا على هذه المعاينة.'),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('إظهار وقت الرسائل'), value: _showTimes, onChanged: (v) { setState(() => _showTimes = v); setSheetState(() {}); }),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('فقاعات رسائل مضغوطة'), subtitle: const Text('تقليل المسافة بين الرسائل'), value: _compactBubbles, onChanged: (v) { setState(() => _compactBubbles = v); setSheetState(() {}); }),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('علامات القراءة (✓✓)'), value: _readReceipts, onChanged: (v) { setState(() => _readReceipts = v); setSheetState(() {}); }),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('الرسائل ذاتية الاختفاء'), subtitle: const Text('عرض شارة توضيحية فقط في هذه المعاينة'), value: _disappearing, onChanged: (v) { setState(() => _disappearing = v); setSheetState(() {}); }),
        if (_disappearing) const ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.timer_outlined), title: Text('مؤقت تجريبي'), subtitle: Text('24 ساعة — لا يحذف رسائل فعلية')),
        const Divider(),
        Text('حجم الخط: ${_fontSize.round()}', style: const TextStyle(fontWeight: FontWeight.w600)),
        Slider(min: 12, max: 24, divisions: 6, value: _fontSize, label: _fontSize.round().toString(), onChanged: (v) { setState(() => _fontSize = v); setSheetState(() {}); }),
        const SizedBox(height: 4), const Text('خلفية المحادثة'), const SizedBox(height: 8),
        Wrap(spacing: 12, runSpacing: 8, children: _wallpapers.map((color) => InkWell(onTap: () { setState(() => _wallpaper = color); setSheetState(() {}); }, child: CircleAvatar(radius: 20, backgroundColor: color, child: _wallpaper == color ? const Icon(Icons.check, color: _green) : null))).toList()),
        const Divider(),
        ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.notifications_off_outlined), title: Text(_muted ? 'إلغاء كتم الإشعارات' : 'كتم الإشعارات'), onTap: () { setState(() => _muted = !_muted); setSheetState(() {}); }),
        ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.push_pin_outlined), title: Text(_pinned ? 'إلغاء تثبيت المحادثة' : 'تثبيت المحادثة'), onTap: () { setState(() => _pinned = !_pinned); setSheetState(() {}); }),
        ListTile(contentPadding: EdgeInsets.zero, leading: Icon(_blocked ? Icons.lock_open : Icons.block), title: Text(_blocked ? 'فك الحظر' : 'حظر جهة الاتصال'), onTap: () { Navigator.pop(sheetContext); _confirmBlock(); }),
        ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.delete_outline, color: Colors.red), title: const Text('مسح محتوى الدردشة', style: TextStyle(color: Colors.red)), onTap: () { Navigator.pop(sheetContext); _confirmClear(); }),
        const SizedBox(height: 8),
        SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(sheetContext), child: const Text('تم'))),
      ])),
    ))));
  }

  void _handleAttachment(String value) {
    switch (value) {
      case 'image': _addSample('🖼 صورة تجريبية (عنصر معاينة)', icon: Icons.image); break;
      case 'camera': _addSample('📷 صورة من الكاميرا (محاكاة فقط)', icon: Icons.camera_alt); break;
      case 'file': _addSample('📎 ملف تجريبي.pdf • 245 KB', icon: Icons.insert_drive_file); break;
      case 'audio': _addSample('🎵 رسالة صوتية تجريبية • 0:12', icon: Icons.play_circle_fill); break;
      case 'location': _addSample('📍 موقع تجريبي — غير حقيقي', icon: Icons.location_on); break;
      case 'contact': _addSample('👤 جهة اتصال تجريبية', icon: Icons.contact_page); break;
    }
  }

  void _confirmClear() => showDialog<void>(context: context, builder: (c) => AlertDialog(
    title: const Text('مسح محتوى الدردشة التجريبية؟'),
    content: const Text('سيتم مسح الرسائل من شاشة المعاينة فقط. لا تتأثر أي محادثة حقيقية.'),
    actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('إلغاء')), FilledButton(onPressed: () { setState(() => _messages.clear()); Navigator.pop(c); }, child: const Text('مسح'))],
  ));

  void _confirmBlock() => showDialog<void>(context: context, builder: (c) => AlertDialog(
    title: Text(_blocked ? 'فك الحظر؟' : 'حظر جهة الاتصال التجريبية؟'),
    content: const Text('هذا التغيير للتجربة داخل هذه الشاشة فقط، ولا يؤثر على أي مستخدم.'),
    actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('إلغاء')), FilledButton(onPressed: () { setState(() => _blocked = !_blocked); Navigator.pop(c); }, child: Text(_blocked ? 'فك الحظر' : 'حظر'))],
  ));

  void _showContactInfo() => showDialog<void>(context: context, builder: (c) => AlertDialog(
    title: const Text('الملف التجريبي'),
    content: const Column(mainAxisSize: MainAxisSize.min, children: [CircleAvatar(radius: 35, child: Icon(Icons.person, size: 38)), SizedBox(height: 12), Text('مستخدم بلوساب التجريبي'), Text('هذه بيانات وهمية لمعاينة الواجهة.')]),
    actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('إغلاق'))],
  ));

  void _showInfo(BuildContext context) => showDialog<void>(context: context, builder: (c) => AlertDialog(title: const Text('محادثة تجريبية'), content: const Text('هذه واجهة محلية للمطور. أزرار الإعدادات والمرفقات والحظر والمسح تغيّر المعاينة فقط ولا تتصل بالشبكة.'), actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('حسنًا'))]));
  void _toast(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

class _PreviewMessage {
  final String text;
  final bool mine;
  final String time;
  final IconData? icon;
  const _PreviewMessage(this.text, this.mine, this.time, {this.icon});
}
