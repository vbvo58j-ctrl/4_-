import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Durable receiver-side file assembly. Each transfer is atomically persisted
/// after every accepted chunk so an app restart does not discard progress.
class IncomingFileTransferStore {
  IncomingFileTransferStore._();
  static final IncomingFileTransferStore instance = IncomingFileTransferStore._();
  static const int maxTransfers = 8;
  static const int maxBytesPerTransfer = 4 * 1024 * 1024;
  static const Duration maxAge = Duration(hours: 24);

  Future<Directory> _root() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/blousab_incoming_transfers');
    await dir.create(recursive: true);
    return dir;
  }

  String _safeId(String id) => base64Url.encode(utf8.encode(id)).replaceAll('=', '');

  Future<File> _file(String id) async => File('${(await _root()).path}/${_safeId(id)}.json');

  Future<Map<String, dynamic>?> load(String id) async {
    try {
      final file = await _file(id);
      if (!await file.exists()) return null;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) return null;
      final map = Map<String, dynamic>.from(value);
      final created = DateTime.tryParse('${map['createdAt']}');
      if (created == null || DateTime.now().difference(created) > maxAge) {
        await file.delete();
        return null;
      }
      return map;
    } catch (_) { return null; }
  }

  Future<bool> beginTransfer({required String transferId, required String fileName,
    required String senderId, required String senderName, required String conversationId,
    required int chunkCount, required int totalBytes, required int checksum}) async {
    if (transferId.isEmpty || senderId.isEmpty || conversationId.isEmpty ||
        chunkCount < 1 || chunkCount > 192 || totalBytes < 1 ||
        totalBytes > maxBytesPerTransfer || checksum < 0) return false;
    final target = await _file(transferId);
    if (await target.exists()) {
      final old = await load(transferId);
      return old != null && old['senderId'] == senderId &&
          old['conversationId'] == conversationId && old['chunkCount'] == chunkCount &&
          old['totalBytes'] == totalBytes && old['checksum'] == checksum;
    }
    final root = await _root();
    final files = root.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
    if (files.length >= maxTransfers) return false;
    final data = <String, dynamic>{
      'transferId': transferId, 'fileName': fileName, 'senderId': senderId,
      'senderName': senderName, 'conversationId': conversationId,
      'chunkCount': chunkCount, 'totalBytes': totalBytes, 'checksum': checksum,
      'createdAt': DateTime.now().toIso8601String(), 'chunks': <String, dynamic>{},
    };
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    await temp.rename(target.path);
    return true;
  }

  Future<bool> saveChunk({required String transferId, required String fileName,
    required String senderId, required String senderName, required String conversationId,
    required int chunkCount, required int totalBytes, required int checksum,
    required int index, required List<int> bytes}) async {
    if (transferId.isEmpty || chunkCount < 1 || chunkCount > 192 || totalBytes < 1 ||
        totalBytes > maxBytesPerTransfer || index < 0 || index >= chunkCount ||
        bytes.isEmpty || bytes.length > 24 * 1024) return false;
    final root = await _root();
    final target = await _file(transferId);
    Map<String, dynamic> data;
    if (await target.exists()) {
      final loaded = await load(transferId);
      if (loaded == null) return false;
      data = loaded;
      if (data['senderId'] != senderId || data['conversationId'] != conversationId ||
          data['chunkCount'] != chunkCount || data['totalBytes'] != totalBytes ||
          data['checksum'] != checksum) return false;
    } else {
      final files = root.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
      if (files.length >= maxTransfers) return false;
      data = {'transferId': transferId, 'fileName': fileName, 'senderId': senderId,
        'senderName': senderName, 'conversationId': conversationId, 'chunkCount': chunkCount,
        'totalBytes': totalBytes, 'checksum': checksum,
        'createdAt': DateTime.now().toIso8601String(), 'chunks': <String, dynamic>{}};
    }
    final chunks = Map<String, dynamic>.from(data['chunks'] as Map? ?? {});
    if (!chunks.containsKey('$index')) chunks['$index'] = base64Encode(bytes);
    var storedBytes = 0;
    for (final encoded in chunks.values) {
      try { storedBytes += base64Decode(encoded.toString()).length; } catch (_) { return false; }
    }
    if (storedBytes > totalBytes) return false;
    data['chunks'] = chunks;
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
    return true;
  }


  Future<List<int>> missingIndices(String transferId, {int? expectedCount}) async {
    final data = await load(transferId);
    if (data == null) return expectedCount == null ? <int>[] : List<int>.generate(expectedCount, (i) => i);
    final count = int.tryParse('${data['chunkCount']}') ?? 0;
    if (count < 1 || count > 192 || (expectedCount != null && expectedCount != count)) return <int>[];
    final chunks = Map<String, dynamic>.from(data['chunks'] as Map? ?? {});
    return List<int>.generate(count, (i) => i).where((i) => !chunks.containsKey('$i')).toList();
  }

  /// Persists a retry timestamp so missing-chunk requests survive screen
  /// changes and app restarts without flooding the sender.
  Future<bool> markMissingRequest(String transferId, List<int> indices,
      {Duration cooldown = const Duration(seconds: 15)}) async {
    final data = await load(transferId);
    if (data == null || indices.isEmpty) return false;
    final now = DateTime.now();
    final previous = DateTime.tryParse('${data['missingRequestAt']}');
    if (previous != null && now.difference(previous) < cooldown) return false;
    data['missingRequestAt'] = now.toIso8601String();
    data['missingRequestIndices'] = indices.take(192).toList();
    final target = await _file(transferId);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
    return true;
  }


  Future<void> clearMissingRequest(String transferId) async {
    final data = await load(transferId);
    if (data == null) return;
    data.remove('missingRequestAt');
    data.remove('missingRequestIndices');
    final target = await _file(transferId);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
  }

  Future<void> clearChunks(String transferId) async {
    final data = await load(transferId);
    if (data == null) return;
    data['chunks'] = <String, dynamic>{};
    data.remove('missingRequestAt');
    data.remove('missingRequestIndices');
    final target = await _file(transferId);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
  }

  Future<void> remove(String transferId) async {
    try { final f = await _file(transferId); if (await f.exists()) await f.delete(); } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> incomplete() async {
    final root = await _root();
    final result = <Map<String, dynamic>>[];
    for (final entity in root.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
      try {
        final value = jsonDecode(await entity.readAsString());
        if (value is Map) result.add(Map<String, dynamic>.from(value));
      } catch (_) { try { await entity.delete(); } catch (_) {} }
    }
    return result;
  }
}
