import 'dart:collection';

/// Short-lived route hints learned only from an established Blousab peer.
/// Hints are advisory (never proof of identity) and expire quickly.
class MeshRouteHint {
  const MeshRouteHint({required this.destinationId, required this.nextHopId,
    required this.hops, required this.expiresAt, this.successRate = 50});
  final String destinationId;
  final String nextHopId;
  final int hops;
  final DateTime expiresAt;
  final int successRate;
  bool get isFresh => expiresAt.isAfter(DateTime.now());
}

class MeshRouteDirectory {
  MeshRouteDirectory._();
  static final MeshRouteDirectory instance = MeshRouteDirectory._();
  static const int maxHints = 256;
  static const int maxAdvertisedHops = 4;
  static const Duration hintTtl = Duration(minutes: 3);
  final LinkedHashMap<String, MeshRouteHint> _hints = LinkedHashMap();

  void learn({required String fromPeerId, required String destinationId,
      required int advertisedHops, int successRate = 50}) {
    if (fromPeerId.isEmpty || destinationId.isEmpty || fromPeerId == destinationId ||
        fromPeerId.length > 256 || destinationId.length > 256 ||
        advertisedHops < 0 || advertisedHops >= maxAdvertisedHops) return;
    final hops = advertisedHops + 1;
    final old = _hints[destinationId];
    if (old != null && old.isFresh && old.hops < hops) return;
    _hints[destinationId] = MeshRouteHint(destinationId: destinationId,
      nextHopId: fromPeerId, hops: hops,
      successRate: successRate.clamp(0, 100), expiresAt: DateTime.now().add(hintTtl));
    while (_hints.length > maxHints) { _hints.remove(_hints.keys.first); }
  }

  /// Remove routes that depended on a peer which is no longer connected.
  void removeNextHop(String peerId) {
    if (peerId.isEmpty) return;
    _hints.removeWhere((_, hint) => hint.nextHopId == peerId);
  }

  /// Remove one destination hint when a newer route advertisement withdraws it.
  void removeDestination(String destinationId, {String? learnedFrom}) {
    final hint = _hints[destinationId];
    if (hint == null) return;
    if (learnedFrom == null || hint.nextHopId == learnedFrom) {
      _hints.remove(destinationId);
    }
  }

  MeshRouteHint? routeTo(String destinationId) {
    final hint = _hints[destinationId];
    if (hint == null) return null;
    if (!hint.isFresh) { _hints.remove(destinationId); return null; }
    return hint;
  }

  List<Map<String, Object>> exportFor(String excludePeerId) {
    final now = DateTime.now();
    _hints.removeWhere((_, hint) => !hint.expiresAt.isAfter(now));
    return _hints.values.where((h) => h.nextHopId != excludePeerId)
      .take(64).map((h) => <String, Object>{
        'destinationId': h.destinationId, 'hops': h.hops,
        'successRate': h.successRate,
      }).toList(growable: false);
  }
}
