import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/bluetooth_classic_service.dart';
import '../services/local_network_service.dart';

class GamesScreen extends StatefulWidget {
  final String conversationId;
  final String userId;
  final String userName;
  final String? peerAddress;
  const GamesScreen({super.key, required this.conversationId, required this.userId, required this.userName, this.peerAddress});
  @override State<GamesScreen> createState() => _GamesScreenState();
}

class _GamesScreenState extends State<GamesScreen> {
  final _bt = BluetoothClassicService.instance;
  StreamSubscription<BlousabEvent>? _btSub, _lanSub;
  String _game = 'xo';
  String _gameId = '';
  String _mark = 'X';
  String _turn = 'X';
  List<String> _board = List.filled(9, '');
  String _status = 'اختر لعبة وابدأ جلسة مع الطرف الآخر';
  String _mode = 'bluetooth';
  String _rpsChoice = '';
  String _opponentChoice = '';
  bool _joined = false;
  bool _busy = false;
  int _myPongScore = 0;
  int _opPongScore = 0;
  int _pongRally = 0;
  List<Offset> _poolBalls = [const Offset(.25,.5), const Offset(.68,.35), const Offset(.72,.5), const Offset(.68,.65), const Offset(.80,.42), const Offset(.80,.58)];

  @override void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) { if (mounted) setState(() => _mode = p.getString('blousab_connection_mode') ?? 'bluetooth'); });
    _btSub = _bt.events.listen((e) { if (e.type == 'message' && e.message != null) _onPacket(e.message!); });
    _lanSub = LocalNetworkService.instance.events.listen((e) { if (e.type == 'message' && e.message != null) _onPacket(e.message!); });
  }
  @override void dispose() { _btSub?.cancel(); _lanSub?.cancel(); super.dispose(); }

  Future<void> _send(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final wifi = (prefs.getString('blousab_connection_mode') ?? _mode) == 'wifi';
    final packet = jsonEncode({'type':'wasl_game','conversationId':widget.conversationId,'senderId':widget.userId,'senderName':widget.userName,...data});
    if (wifi) { await LocalNetworkService.instance.broadcastMessage(packet); }
    else {
      final address = widget.peerAddress;
      if (address != null && address.isNotEmpty) { await _bt.sendMessage(address: address, message: packet); }
      else { await _bt.broadcastMessage(packet); }
    }
  }
  void _onPacket(String raw) {
    try {
      final d = jsonDecode(raw);
      if (d is! Map || d['type'] != 'wasl_game' || d['conversationId'] != widget.conversationId || d['senderId'] == widget.userId) return;
      final action = d['action']?.toString() ?? '';
      if (action == 'invite') {
        setState(() { _game = d['game']?.toString() ?? 'xo'; _gameId = d['gameId']?.toString() ?? ''; _mark = 'O'; _turn = 'X'; _board = List.filled(9, ''); _joined = true; _rpsChoice = ''; _opponentChoice = ''; _myPongScore = 0; _opPongScore = 0; _pongRally = 0; _poolBalls = [const Offset(.25,.5), const Offset(.68,.35), const Offset(.72,.5), const Offset(.68,.65), const Offset(.80,.42), const Offset(.80,.58)]; _status = 'تحدّاك ${d['senderName'] ?? 'الطرف الآخر'}! أنت O، ابدأ عندما يأتي دورك.'; });
        _send({'action':'accept','gameId':_gameId,'game':_game});
      } else if (d['gameId']?.toString() == _gameId && action == 'accept') {
        setState(() => _status = 'تم الاتصال باللاعب الآخر. أنت X.');
      } else if (d['gameId']?.toString() == _gameId && action == 'move' && _game == 'xo') {
        final i = d['index']; final mark = d['mark']?.toString() ?? '';
        if (i is int && i >= 0 && i < 9 && _board[i].isEmpty && (mark == 'X' || mark == 'O')) {
          setState(() { _board[i] = mark; _turn = mark == 'X' ? 'O' : 'X'; _status = _xoResult() ?? 'دور اللاعب $_turn'; });
        }
      } else if (d['gameId']?.toString() == _gameId && action == 'rps') {
        setState(() { _opponentChoice = d['choice']?.toString() ?? ''; _status = _rpsResult(); });
      } else if (d['gameId']?.toString() == _gameId && action == 'pong') {
        setState(() { _myPongScore = (d['opScore'] as num?)?.toInt() ?? _myPongScore; _opPongScore = (d['myScore'] as num?)?.toInt() ?? _opPongScore; _pongRally = (d['rally'] as num?)?.toInt() ?? _pongRally; _status = 'تبادل الكرة!'; });
      } else if (d['gameId']?.toString() == _gameId && action == 'pool') {
        final raw = d['balls'];
        if (raw is List) { final next = <Offset>[]; for (final b in raw) { if (b is List && b.length == 2 && b[0] is num && b[1] is num) next.add(Offset((b[0] as num).toDouble(), (b[1] as num).toDouble())); } if (next.isNotEmpty) setState(() { _poolBalls = next; _status = 'حرّك الخصم الكرات'; }); }
      } else if (d['gameId']?.toString() == _gameId && action == 'restart') {
        setState(() { _board = List.filled(9, ''); _turn = 'X'; _myPongScore = 0; _opPongScore = 0; _pongRally = 0; _poolBalls = [const Offset(.25,.5), const Offset(.68,.35), const Offset(.72,.5), const Offset(.68,.65), const Offset(.80,.42), const Offset(.80,.58)]; _status = 'بدأت جولة جديدة'; });
      }
    } catch (_) {}
  }
  Future<void> _start(String game) async {
    setState(() { _busy = true; _game = game; _gameId = '${DateTime.now().microsecondsSinceEpoch}_${widget.userId}'; _mark = 'X'; _turn = 'X'; _board = List.filled(9, ''); _joined = false; _rpsChoice = ''; _opponentChoice = ''; _myPongScore = 0; _opPongScore = 0; _pongRally = 0; _poolBalls = [const Offset(.25,.5), const Offset(.68,.35), const Offset(.72,.5), const Offset(.68,.65), const Offset(.80,.42), const Offset(.80,.58)]; _status = 'أُرسلت دعوة اللعبة. افتح شاشة الألعاب لدى الطرف الآخر.'; });
    try { await _send({'action':'invite','game':game,'gameId':_gameId}); }
    catch (e) { if (mounted) setState(() => _status = 'تعذر إرسال الدعوة. تأكد من الاتصال: $e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  String? _xoResult() {
    const lines = [[0,1,2],[3,4,5],[6,7,8],[0,3,6],[1,4,7],[2,5,8],[0,4,8],[2,4,6]];
    for (final l in lines) { if (_board[l[0]].isNotEmpty && _board[l[0]] == _board[l[1]] && _board[l[1]] == _board[l[2]]) return 'الفائز: ${_board[l[0]]} 🎉'; }
    if (_board.every((v) => v.isNotEmpty)) return 'تعادل!';
    return null;
  }
  Future<void> _move(int i) async {
    if (_game != 'xo' || _board[i].isNotEmpty || _turn != _mark || _xoResult() != null) return;
    setState(() { _board[i] = _mark; _turn = _mark == 'X' ? 'O' : 'X'; _status = _xoResult() ?? 'دور اللاعب $_turn'; });
    try { await _send({'action':'move','gameId':_gameId,'index':i,'mark':_mark}); } catch (e) { if (mounted) setState(() => _status = 'تعذر إرسال الحركة: $e'); }
  }
  Future<void> _pongHit() async {
    setState(() { _myPongScore++; _pongRally++; _status = 'نقطة لك! اضغط لإعادة الكرة'; });
    try { await _send({'action':'pong','gameId':_gameId,'myScore':_myPongScore,'opScore':_opPongScore,'rally':_pongRally}); } catch (_) {}
  }
  Future<void> _poolShoot(Offset point) async {
    final next = _poolBalls.map((b) => Offset((b.dx + (point.dx - b.dx) * .18).clamp(.08,.92), (b.dy + (point.dy - b.dy) * .18).clamp(.12,.88))).toList();
    if (next.isNotEmpty) next[0] = Offset(point.dx.clamp(.08,.92), point.dy.clamp(.12,.88));
    setState(() { _poolBalls = next; _status = 'تم تنفيذ الضربة؛ دورك مرة أخرى'; });
    try { await _send({'action':'pool','gameId':_gameId,'balls':_poolBalls.map((b) => [b.dx,b.dy]).toList()}); } catch (_) {}
  }
  Future<void> _chooseRps(String choice) async {
    setState(() { _rpsChoice = choice; _status = 'اخترت $choice. بانتظار اختيار الطرف الآخر...'; });
    try { await _send({'action':'rps','gameId':_gameId,'choice':choice}); if (_opponentChoice.isNotEmpty && mounted) setState(() => _status = _rpsResult()); } catch (e) { if (mounted) setState(() => _status = 'تعذر إرسال الاختيار: $e'); }
  }
  String _rpsResult() {
    if (_rpsChoice.isEmpty || _opponentChoice.isEmpty) return 'بانتظار اختيار الطرف الآخر';
    if (_rpsChoice == _opponentChoice) return 'تعادل!';
    final win = (_rpsChoice == 'حجر' && _opponentChoice == 'مقص') || (_rpsChoice == 'ورقة' && _opponentChoice == 'حجر') || (_rpsChoice == 'مقص' && _opponentChoice == 'ورقة');
    return win ? 'فزت بهذه الجولة 🎉' : 'فاز الطرف الآخر هذه الجولة';
  }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ألعاب المحادثة'), actions: [Icon(_mode == 'wifi' ? Icons.wifi : Icons.bluetooth, size: 22), const SizedBox(width: 12)]),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('العبوا معًا أثناء المحادثة', style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
      const SizedBox(height: 6), const Text('يجب أن يكون الطرف الآخر داخل شاشة الألعاب في نفس المحادثة، وعلى وضع الاتصال نفسه.'),
      const SizedBox(height: 16),
      Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.grid_3x3)), title: const Text('إكس أو (XO)'), subtitle: const Text('لعبة تنافسية بين لاعبين'), trailing: const Icon(Icons.chevron_right), onTap: _busy ? null : () => _start('xo'))),
      Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.back_hand)), title: const Text('حجر ورقة مقص'), subtitle: const Text('اختر حركتك وانتظر الطرف الآخر'), trailing: const Icon(Icons.chevron_right), onTap: _busy ? null : () => _start('rps'))),
      Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.sports_tennis)), title: const Text('كرة الطاولة'), subtitle: const Text('تحدّي نقاط سريع بين لاعبين'), trailing: const Icon(Icons.chevron_right), onTap: _busy ? null : () => _start('pong'))),
      Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.sports_bar)), title: const Text('البلياردو'), subtitle: const Text('طاولة مصغرة باللمس ومزامنة مواضع الكرات'), trailing: const Icon(Icons.chevron_right), onTap: _busy ? null : () => _start('pool'))),
      const SizedBox(height: 12),
      if (_gameId.isNotEmpty) Card(color: Theme.of(context).colorScheme.surfaceContainerHighest, child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text({'xo':'إكس أو','rps':'حجر ورقة مقص','pong':'كرة الطاولة','pool':'البلياردو'}[_game] ?? 'لعبة جماعية', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)), const SizedBox(height: 8), Text(_status), const SizedBox(height: 16),
        if (_game == 'pong') Column(children: [Text('أنت $_myPongScore  —  الخصم $_opPongScore', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), const SizedBox(height: 12), GestureDetector(onTap: _pongHit, child: Container(height: 190, decoration: BoxDecoration(color: const Color(0xff176b50), borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white, width: 3)), child: Stack(children: [const Align(alignment: Alignment.center, child: VerticalDivider(color: Colors.white, thickness: 2)), const Align(alignment: Alignment.center, child: Icon(Icons.sports_tennis, color: Colors.white, size: 64)), const Positioned(left: 10, top: 10, child: Text('اضغط لإعادة الكرة', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))]))), const SizedBox(height: 8), const Text('نموذج لعب مبسّط باللمس؛ اضغط على الطاولة لتسجيل ضربة.')])
        else if (_game == 'pool') Column(children: [GestureDetector(onTapDown: (details) { final box = context.findRenderObject() as RenderBox?; if (box != null) { final local = details.localPosition; final w = box.size.width; final h = 190.0; _poolShoot(Offset((local.dx / w).clamp(.08,.92), (local.dy / h).clamp(.12,.88))); } }, child: Container(height: 190, width: double.infinity, decoration: BoxDecoration(color: const Color(0xff176b50), border: Border.all(color: const Color(0xff6d4025), width: 12), borderRadius: BorderRadius.circular(16)), child: LayoutBuilder(builder: (context, c) => Stack(children: [for (final pocket in [const Offset(.03,.05),const Offset(.5,.04),const Offset(.97,.05),const Offset(.03,.95),const Offset(.5,.96),const Offset(.97,.95)]) Positioned(left: c.maxWidth*pocket.dx-8, top: 190*pocket.dy-8, child: const CircleAvatar(radius: 9, backgroundColor: Colors.black)), for (var i=0;i<_poolBalls.length;i++) Positioned(left: c.maxWidth*_poolBalls[i].dx-10, top: 190*_poolBalls[i].dy-10, child: Container(width: 20,height: 20,decoration: BoxDecoration(color: i==0?Colors.white:[Colors.yellow,Colors.red,Colors.blue,Colors.orange,Colors.purple][(i-1)%5],shape: BoxShape.circle,border: Border.all(color: Colors.black26))))]))), const SizedBox(height: 8), const Text('المس الطاولة لتسديد الكرة؛ هذا نموذج مبسّط وليس محاكاة فيزيائية كاملة.')])
        else if (_game == 'xo') GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), itemCount: 9, gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6), itemBuilder: (context, i) => InkWell(onTap: () => _move(i), child: Container(decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(12)), child: Center(child: Text(_board[i], style: TextStyle(fontSize: 42, fontWeight: FontWeight.bold, color: _board[i] == 'X' ? Colors.teal : Colors.deepOrange))))))
        else if (_game == 'rps') Wrap(alignment: WrapAlignment.center, spacing: 8, children: ['حجر','ورقة','مقص'].map((c) => FilledButton(onPressed: _rpsChoice.isEmpty ? () => _chooseRps(c) : null, child: Text(c))).toList()),
        const SizedBox(height: 12), OutlinedButton.icon(onPressed: () async { setState(() { _board = List.filled(9, ''); _turn = 'X'; _rpsChoice = ''; _opponentChoice = ''; _status = 'بدأت جولة جديدة'; }); try { await _send({'action':'restart','gameId':_gameId}); } catch (_) {} }, icon: const Icon(Icons.refresh), label: const Text('جولة جديدة')),
      ]))),
    ]),
  );
}
