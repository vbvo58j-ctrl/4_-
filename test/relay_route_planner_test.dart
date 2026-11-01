import 'package:flutter_test/flutter_test.dart';
import 'package:blousab/services/relay_route_planner.dart';

void main() {
  const planner = RelayRoutePlanner();

  test('prefers fresh known destination route', () {
    final ranked = planner.rank(
      senderId: 'source', visitedPath: {}, limit: 2,
      peers: const [
        RelayPeerMetric(peerId: 'near', signal: 95, successRate: 90, estimatedHops: 1),
        RelayPeerMetric(peerId: 'route', signal: 45, successRate: 75,
          knownDestination: true, estimatedHops: 2),
      ],
    );
    expect(ranked.first.peerId, 'route');
  });

  test('excludes sender, visited nodes and duplicate peers', () {
    final ranked = planner.rank(
      senderId: 'source', visitedPath: {'visited'}, limit: 5,
      peers: const [
        RelayPeerMetric(peerId: 'source', signal: 100),
        RelayPeerMetric(peerId: 'visited', signal: 100),
        RelayPeerMetric(peerId: 'ok', signal: 20),
        RelayPeerMetric(peerId: 'ok', signal: 80),
      ],
    );
    expect(ranked.map((e) => e.peerId).toList(), ['ok']);
  });

  test('avoids busy and nearly depleted relay when alternatives exist', () {
    final ranked = planner.rank(
      senderId: 'source', visitedPath: {},
      peers: const [
        RelayPeerMetric(peerId: 'weak', signal: 90, successRate: 90,
          batteryPercent: 5, isBusy: true),
        RelayPeerMetric(peerId: 'healthy', signal: 55, successRate: 70,
          batteryPercent: 80),
      ],
    );
    expect(ranked.first.peerId, 'healthy');
  });
}
