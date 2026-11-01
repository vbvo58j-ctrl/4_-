/// Deterministic next-hop ranking for opt-in Blusab mesh relaying.
///
/// This planner does not open sockets or authenticate peers. Callers must pass
/// only peers already verified by the Blusab handshake and must enforce the
/// user's relay/privacy settings before forwarding.
class RelayPeerMetric {
  const RelayPeerMetric({
    required this.peerId,
    this.signal = 0,
    this.successRate = 0,
    this.knownDestination = false,
    this.estimatedHops = 99,
    this.batteryPercent = 100,
    this.isCharging = false,
    this.isBusy = false,
  });

  final String peerId;
  /// 0..100; unknown values should be passed as 0.
  final int signal;
  /// 0..100 based on recent successful forwarding outcomes.
  final int successRate;
  /// True only when a fresh, authenticated route hint exists.
  final bool knownDestination;
  final int estimatedHops;
  final int batteryPercent;
  final bool isCharging;
  final bool isBusy;
}

class RelayRoutePlanner {
  const RelayRoutePlanner();

  /// Returns at most [limit] eligible next hops, best first.
  /// Excludes the sender, already visited nodes and malformed peer IDs.
  List<RelayPeerMetric> rank({
    required Iterable<RelayPeerMetric> peers,
    required String senderId,
    required Set<String> visitedPath,
    int limit = 2,
  }) {
    if (senderId.isEmpty || limit <= 0) return const [];
    final unique = <String, RelayPeerMetric>{};
    for (final peer in peers) {
      if (peer.peerId.isEmpty || peer.peerId.length > 256 ||
          peer.peerId == senderId || visitedPath.contains(peer.peerId)) {
        continue;
      }
      final previous = unique[peer.peerId];
      if (previous == null || _score(peer) > _score(previous)) {
        unique[peer.peerId] = peer;
      }
    }
    final result = unique.values.toList()
      ..sort((a, b) {
        final score = _score(b).compareTo(_score(a));
        return score != 0 ? score : a.peerId.compareTo(b.peerId);
      });
    return result.take(limit).toList(growable: false);
  }

  int _score(RelayPeerMetric p) {
    final signal = p.signal.clamp(0, 100).toInt();
    final success = p.successRate.clamp(0, 100).toInt();
    final battery = p.batteryPercent.clamp(0, 100).toInt();
    final hops = p.estimatedHops.clamp(0, 20).toInt();
    var score = signal * 2 + success * 3 + battery;
    if (p.knownDestination) score += 180;
    score -= hops * 18;
    if (p.isCharging) score += 15;
    if (p.isBusy) score -= 120;
    // Do not choose an almost-depleted, non-charging device as a relay.
    if (battery <= 10 && !p.isCharging) score -= 150;
    return score;
  }
}
