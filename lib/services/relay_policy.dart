import 'dart:convert';

/// Bounds and loop-prevention for opt-in relay packets.
/// IMPORTANT: this is not sender authentication or cryptographic verification.
class RelayPolicy {
  RelayPolicy();

  static const int maxHops = 5;
  static const int maxAgeSeconds = 24 * 60 * 60;
  static const int maxSeenIds = 5000;
  static const int maxPacketBytes = 1024 * 1024;
  static const int maxPathLength = maxHops + 1;

  final Set<String> _seen = <String>{};

  Map<String, dynamic>? acceptAndPrepareForward(String rawJson,
      {String? thisDeviceId}) {
    if (utf8.encode(rawJson).length > maxPacketBytes) return null;
    Map<String, dynamic> packet;
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) return null;
      packet = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }

    if (packet['relayEnabled'] != true) return null;
    final id = packet['id']?.toString() ?? packet['messageId']?.toString() ?? '';
    final senderId = packet['senderId']?.toString() ?? '';
    final recipientId = packet['recipientId']?.toString() ?? '';
    if (id.isEmpty || id.length > 160 || senderId.isEmpty || senderId.length > 256 ||
        recipientId.isEmpty || recipientId.length > 256) return null;
    if (_seen.contains(id)) return null;

    final created = DateTime.tryParse(packet['createdAt']?.toString() ??
        packet['sentAt']?.toString() ?? '');
    final now = DateTime.now();
    if (created == null || now.difference(created).inSeconds > maxAgeSeconds ||
        created.isAfter(now.add(const Duration(minutes: 5)))) return null;

    final hops = int.tryParse(packet['hopCount']?.toString() ?? '0');
    if (hops == null || hops < 0 || hops >= maxHops) return null;
    final pathRaw = packet['relayPath'];
    if (pathRaw != null && pathRaw is! List) return null;
    final path = (pathRaw is List)
        ? pathRaw.map((e) => e.toString()).toList(growable: true)
        : <String>[];
    if (path.length > maxPathLength || path.any((e) => e.isEmpty || e.length > 256)) return null;
    if (thisDeviceId != null && (thisDeviceId.isEmpty || path.contains(thisDeviceId))) return null;
    if (thisDeviceId != null) path.add(thisDeviceId);

    // Only mark a packet seen after every validation succeeds, preventing an
    // invalid/stale packet from poisoning the de-duplication cache.
    _seen.add(id);
    if (_seen.length > maxSeenIds) _seen.remove(_seen.first);
    packet['hopCount'] = hops + 1;
    packet['relayPath'] = path;
    return packet;
  }

  bool markSeen(String messageId) {
    if (messageId.isEmpty || messageId.length > 160) return false;
    final added = _seen.add(messageId);
    if (_seen.length > maxSeenIds) _seen.remove(_seen.first);
    return added;
  }
}
