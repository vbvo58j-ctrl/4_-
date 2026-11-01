import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:blousab/services/relay_policy.dart';

void main() {
  Map<String, dynamic> packet({
    String id = 'm-1',
    int hops = 0,
    List<String> path = const [],
    bool relay = true,
    String? createdAt,
  }) => {
    'id': id,
    'senderId': 'sender-1',
    'recipientId': 'community-1',
    'relayEnabled': relay,
    'hopCount': hops,
    'relayPath': path,
    'createdAt': createdAt ?? DateTime.now().toIso8601String(),
  };

  test('increments hops and appends this relay to path', () {
    final policy = RelayPolicy();
    final result = policy.acceptAndPrepareForward(
      jsonEncode(packet()), thisDeviceId: 'relay-B');
    expect(result?['hopCount'], 1);
    expect(result?['relayPath'], ['relay-B']);
  });

  test('rejects duplicate message IDs', () {
    final policy = RelayPolicy();
    final raw = jsonEncode(packet());
    expect(policy.acceptAndPrepareForward(raw), isNotNull);
    expect(policy.acceptAndPrepareForward(raw), isNull);
  });

  test('does not mark invalid stale packet as seen', () {
    final policy = RelayPolicy();
    final stale = jsonEncode(packet(
      id: 'stale-1',
      createdAt: DateTime.now().subtract(const Duration(days: 3)).toIso8601String(),
    ));
    expect(policy.acceptAndPrepareForward(stale), isNull);
    final valid = jsonEncode(packet(id: 'stale-1'));
    expect(policy.acceptAndPrepareForward(valid), isNotNull);
  });

  test('rejects a packet whose path already includes this device', () {
    final policy = RelayPolicy();
    expect(policy.acceptAndPrepareForward(
      jsonEncode(packet(path: ['relay-B'])), thisDeviceId: 'relay-B'), isNull);
  });

  test('rejects too many hops and oversized frames', () {
    final policy = RelayPolicy();
    expect(policy.acceptAndPrepareForward(jsonEncode(packet(hops: 5))), isNull);
    expect(policy.acceptAndPrepareForward('x' * (RelayPolicy.maxPacketBytes + 1)), isNull);
  });
}

// Multi-hop receipts use the same bounded forwarding policy as chat packets.
// This guards the protocol fields needed for an ACK to travel back through
// intermediary devices instead of stopping at the first hop.
