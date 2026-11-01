import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Durable outbox stored in the app's private files directory (not preferences).
/// Entries remain until a delivery acknowledgement is received.
class PendingMessageStore {
  PendingMessageStore._();
  static final PendingMessageStore instance = PendingMessageStore._();
  Future<void> _tail = Future<void>.value();

  static const int maxEntries = 1000;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}/blousab_pending_outbox.json');
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try { completer.complete(await action()); }
      catch (e, st) { completer.completeError(e, st); }
    });
    return completer.future;
  }

  Future<List<Map<String, dynamic>>> list() => _serialized(() async {
    final file = await _file();
    if (!await file.exists()) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) throw const FormatException('Outbox root is not a list');
      return decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (error) {
      // Preserve a damaged outbox; never interpret corruption as an empty queue.
      throw StateError('تعذر قراءة صندوق الإرسال المحفوظ؛ تم الحفاظ على الملف دون استبداله: $error');
    }
  });

  Future<void> enqueue(Map<String, dynamic> entry) => _serialized(() async {
    final file = await _file();
    final current = await _read(file);
    final id = entry['messageId']?.toString() ?? '';
    if (id.isEmpty) throw ArgumentError('messageId is required');
    if (current.any((e) => e['messageId'] == id)) return;
    if (current.length >= maxEntries) {
      throw StateError('صندوق الإرسال ممتلئ؛ أرسل بعض الرسائل أو أفرغ مساحة قبل إضافة رسائل جديدة.');
    }
    final now = DateTime.now();
    current.add({...entry, 'queuedAt': now.toIso8601String(),
      'nextAttemptAt': now.toIso8601String(), 'attempts': 0});
    await _writeAtomic(file, current);
  });

  Future<void> remove(String messageId) => _serialized(() async {
    final file = await _file();
    final current = await _read(file);
    current.removeWhere((e) => e['messageId'] == messageId);
    await _writeAtomic(file, current);
  });

  Future<void> noteAttempt(String messageId) => _serialized(() async {
    final file = await _file();
    final current = await _read(file);
    final index = current.indexWhere((e) => e['messageId'] == messageId);
    if (index < 0) return;
    final attempts = (current[index]['attempts'] as num? ?? 0).toInt() + 1;
    final exponent = (attempts - 1).clamp(0, 8).toInt();
    final delaySeconds = (2 * (1 << exponent)).clamp(2, 300).toInt();
    final now = DateTime.now();
    current[index]['attempts'] = attempts;
    current[index]['lastAttemptAt'] = now.toIso8601String();
    current[index]['nextAttemptAt'] = now.add(Duration(seconds: delaySeconds)).toIso8601String();
    await _writeAtomic(file, current);
  });

  Future<void> _writeAtomic(File file, List<Map<String, dynamic>> rows) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(rows), flush: true);
    await temp.rename(file.path);
  }

  Future<List<Map<String, dynamic>>> _read(File file) async {
    if (!await file.exists()) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) throw const FormatException('Outbox root is not a list');
      return decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (error) { throw StateError('تعذر قراءة صندوق الإرسال: $error'); }
  }
}

