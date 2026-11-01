import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/blousab_message.dart';
import 'incoming_file_transfer_store.dart';
import 'message_store.dart';

import 'bluetooth_classic_service.dart';
import 'mesh_route_directory.dart';
import 'wifi_aware_service.dart';
import 'relay_queue_store.dart';
import 'relay_route_planner.dart';
import 'local_network_service.dart';
import 'pending_message_store.dart';
import 'blousab_crypto_identity.dart';
import 'group_e2e_crypto_service.dart';
import 'pairwise_chain_ratchet_service.dart';
import 'community_store.dart';

/// Application-scoped mesh control plane. It remains alive while the user
/// navigates between screens, and accepts route information only from peers
/// whose Blousab identity has already been verified by the transport layer.
class MeshRuntimeService {
  MeshRuntimeService._();
  static final MeshRuntimeService instance = MeshRuntimeService._();

  StreamSubscription<BlousabEvent>? _bluetoothSub;
  StreamSubscription<WifiAwareEvent>? _wifiSub;
  StreamSubscription<BlousabEvent>? _lanSub;
  final Map<String, String> _verifiedBluetooth = <String, String>{};
  String _userId = '';
  String _userName = '';
  bool _started = false;
  Timer? _relayTimer;
  bool _retryingRelayQueue = false;
  bool _retryingPendingOutbox = false;
  final Set<String> _pendingOutboxInFlight = <String>{};
  final Map<String, Future<void>> _incomingFileTasks = <String, Future<void>>{};
  final Map<String, Future<void>> _incomingRatchetTasks = <String, Future<void>>{};

  bool get isStarted => _started;

  /// A relayed packet keeps its original senderId. The authenticated transport
  /// peer is therefore the previous hop, recorded as the final relayPath item.
  /// Direct packets have an empty path and must match senderId exactly.
  bool _isAuthenticatedPreviousHop(Map packet, String authenticatedPeerId) {
    if (authenticatedPeerId.isEmpty) return false;
    final rawPath = packet['relayPath'];
    final path = rawPath is List ? rawPath.map((value) => value.toString()).toList() : <String>[];
    if (path.contains(_userId)) return false;
    if (path.isEmpty) return packet['senderId']?.toString() == authenticatedPeerId;
    return path.last == authenticatedPeerId;
  }

  Future<void> _queueForMeshRoute(String raw) async {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final packet = Map<String, dynamic>.from(decoded.map((key, value) => MapEntry(key.toString(), value)));
      final id = packet['id']?.toString() ?? '';
      final recipient = packet['recipientId']?.toString() ?? '';
      if (id.isEmpty || recipient.isEmpty || recipient == _userId) return;
      packet['relay'] = true;
      packet['relayEnabled'] = true;
      packet['hopCount'] = int.tryParse('${packet['hopCount'] ?? packet['hops'] ?? 0}') ?? 0;
      packet['hops'] = packet['hopCount'];
      packet['relayPath'] = packet['relayPath'] is List ? packet['relayPath'] : <String>[];
      await RelayQueueStore.instance.enqueue(packet);
      await retryQueuedRelays();
    } catch (error) {
      debugPrint('Mesh route enqueue failed: $error');
    }
  }

  Future<void> start({required String userId, required String userName}) async {
    if (userId.trim().isEmpty) return;
    _userId = userId.trim();
    _userName = userName.trim().isEmpty ? 'مستخدم بلوساب' : userName.trim();
    if (_started) return;
    _started = true;
    _bluetoothSub = BluetoothClassicService.instance.events.listen(
      _onBluetoothEvent,
      onError: (Object error, StackTrace stack) => debugPrint('Mesh Bluetooth stream: $error'),
    );
    _wifiSub = WifiAwareService.instance.events.listen(
      _onWifiEvent,
      onError: (Object error, StackTrace stack) => debugPrint('Mesh Wi-Fi stream: $error'),
    );
    _lanSub = LocalNetworkService.instance.events.listen(
      _onLanEvent,
      onError: (Object error, StackTrace stack) => debugPrint('Mesh LAN stream: $error'),
    );
    _relayTimer?.cancel();
    _relayTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(retryQueuedRelays());
      unawaited(retryIncompleteFileTransfers());
      unawaited(retryPendingOutbox());
    });
    unawaited(retryQueuedRelays());
    unawaited(retryIncompleteFileTransfers());
    unawaited(retryPendingOutbox());
  }

  Future<void> updateIdentity({required String userId, required String userName}) async {
    _userId = userId.trim();
    _userName = userName.trim().isEmpty ? 'مستخدم بلوساب' : userName.trim();
  }

  void _onBluetoothEvent(BlousabEvent event) {
    final address = event.address;
    final peerId = event.userId;
    if (event.type == 'blousabVerified' && address != null && address.isNotEmpty &&
        peerId != null && peerId.isNotEmpty && peerId != _userId) {
      _verifiedBluetooth[address] = peerId;
      unawaited(_sendBluetoothRoutes(address, peerId));
      unawaited(retryQueuedRelays());
      unawaited(retryIncompleteFileTransfers());
      unawaited(retryPendingOutbox());
      return;
    }
    if (event.type == 'connected' && address != null) {
      final verifiedId = _verifiedBluetooth[address];
      if (verifiedId != null) { unawaited(_sendBluetoothRoutes(address, verifiedId)); unawaited(retryQueuedRelays()); unawaited(retryIncompleteFileTransfers()); unawaited(retryPendingOutbox()); }
    } else if (event.type == 'disconnected' && address != null) {
      final lostId = _verifiedBluetooth.remove(address);
      if (lostId != null && !WifiAwareService.instance.connectedPeerIds.contains(lostId)) {
        MeshRouteDirectory.instance.removeNextHop(lostId);
      }
    } else if (event.type == 'message' && address != null && event.message != null) {
      final verifiedId = _verifiedBluetooth[address];
      if (verifiedId != null) {
        _acceptRoutePacket(event.message!, verifiedId);
        unawaited(_handleLocalPairwisePacket(event.message!, verifiedId, (payload) =>
          BluetoothClassicService.instance.sendMessage(address: address, message: payload)));
        unawaited(_handleMeshControlPacket(event.message!, verifiedId, (payload) =>
          BluetoothClassicService.instance.sendMessage(address: address, message: payload)));
        unawaited(_handleMissingChunkRequest(event.message!, verifiedId, (payload) =>
          BluetoothClassicService.instance.sendMessage(address: address, message: payload)));
        unawaited(_handleIncomingFilePacket(event.message!, verifiedId, (payload) =>
          BluetoothClassicService.instance.sendMessage(address: address, message: payload)));
      }
    }
  }

  void _onLanEvent(BlousabEvent event) {
    if (event.type != 'message' || event.message == null || event.address == null) return;
    try {
      final decoded = jsonDecode(event.message!);
      if (decoded is! Map) return;
      final senderId = decoded['senderId']?.toString() ?? '';
      if (senderId.isEmpty || senderId == _userId) return;
      final authenticatedPeerId = event.userId ?? '';
      final knownPeer = LocalNetworkService.instance.discoveredPeers
          .any((peer) => peer['id'] == authenticatedPeerId);
      if (!knownPeer || !_isAuthenticatedPreviousHop(decoded, authenticatedPeerId)) return;
      _acceptRoutePacket(event.message!, authenticatedPeerId);
      unawaited(_handleLocalPairwisePacket(event.message!, authenticatedPeerId, (payload) =>
        LocalNetworkService.instance.sendControlPacket(address: event.address!, payload: payload)));
      unawaited(_handleMeshControlPacket(event.message!, authenticatedPeerId, (payload) =>
        LocalNetworkService.instance.sendControlPacket(address: event.address!, payload: payload)));
      unawaited(_handleMissingChunkRequest(event.message!, authenticatedPeerId, (payload) =>
        LocalNetworkService.instance.sendControlPacket(address: event.address!, payload: payload)));
      unawaited(_handleIncomingFilePacket(event.message!, authenticatedPeerId, (payload) =>
        LocalNetworkService.instance.sendControlPacket(address: event.address!, payload: payload)));
      unawaited(retryQueuedRelays());
      unawaited(retryIncompleteFileTransfers());
      unawaited(retryPendingOutbox());
    } catch (error) {
      debugPrint('Ignored malformed LAN mesh packet: $error');
    }
  }

  Future<void> _sendBluetoothRoutes(String address, String peerId) async {
    try {
      await BluetoothClassicService.instance.sendMessage(
        address: address,
        message: jsonEncode({
          'type': 'mesh_route_advert',
          'protocol': 'blousab-mesh-route-v1',
          'senderId': _userId,
          'hints': MeshRouteDirectory.instance.exportFor(peerId),
        }),
      );
    } catch (error) {
      debugPrint('Mesh Bluetooth route advertisement failed: $error');
    }
  }

  Future<void> _onWifiEvent(WifiAwareEvent event) async {
    final peer = event.peer;
    if (peer == null || peer.userId.isEmpty || peer.userId == _userId) return;
    if (event.type == 'dataConnected') {
      try {
        await WifiAwareService.instance.sendPacket(
          peerId: peer.userId,
          payload: jsonEncode({
            'type': 'mesh_route_advert',
            'protocol': 'blousab-mesh-route-v1',
            'senderId': _userId,
            'hints': MeshRouteDirectory.instance.exportFor(peer.userId),
          }),
        );
      } catch (error) {
        debugPrint('Mesh Wi-Fi route advertisement failed: $error');
      }
      unawaited(retryPendingOutbox());
      unawaited(retryQueuedRelays());
    } else if (event.type == 'dataPacket' && event.payload != null) {
      _acceptRoutePacket(event.payload!, peer.userId);
      unawaited(_handleLocalPairwisePacket(event.payload!, peer.userId, (payload) =>
        WifiAwareService.instance.sendPacket(peerId: peer.userId, payload: payload)));
      unawaited(_handleMeshControlPacket(event.payload!, peer.userId, (payload) =>
        WifiAwareService.instance.sendPacket(peerId: peer.userId, payload: payload)));
      unawaited(_handleMissingChunkRequest(event.payload!, peer.userId, (payload) =>
        WifiAwareService.instance.sendPacket(peerId: peer.userId, payload: payload)));
      unawaited(_handleIncomingFilePacket(event.payload!, peer.userId, (payload) =>
        WifiAwareService.instance.sendPacket(peerId: peer.userId, payload: payload)));
      unawaited(retryQueuedRelays());
      unawaited(retryIncompleteFileTransfers());
      unawaited(retryPendingOutbox());
    } else if (event.type == 'candidateLost' || event.type == 'userLost' || event.type == 'dataDisconnected' || event.type == 'dataError') {
      // Keep the peer's route if Bluetooth still has a verified live path.
      final bluetoothStillConnected = _verifiedBluetooth.values.contains(peer.userId);
      if (!bluetoothStillConnected) MeshRouteDirectory.instance.removeNextHop(peer.userId);
    }
  }


  /// Replays already-encrypted direct-chat packets from the durable outbox.
  /// The exact ciphertext is reused: retrying must never call Ratchet.encrypt
  /// again for the same logical message because that would consume a new key.
  /// Entries are retired only by an authenticated end-to-end delivery_ack.
  Future<void> retryPendingOutbox() async {
    if (!_started || _retryingPendingOutbox || _userId.isEmpty) return;
    _retryingPendingOutbox = true;
    try {
      final entries = await PendingMessageStore.instance.list();
      for (final entry in entries) {
        final id = entry['messageId']?.toString() ?? '';
        if (id.isEmpty || _pendingOutboxInFlight.contains(id)) continue;
        if (entry['kind'] == 'file_chunk_transfer') continue;
        final queuedAt = DateTime.tryParse(entry['queuedAt']?.toString() ?? '');
        if (queuedAt == null || DateTime.now().difference(queuedAt) > const Duration(days: 7)) continue;
        final nextAttemptAt = DateTime.tryParse(entry['nextAttemptAt']?.toString() ?? '');
        if (nextAttemptAt != null && nextAttemptAt.isAfter(DateTime.now())) continue;
        final raw = entry['payload']?.toString() ?? '';
        if (raw.isEmpty) continue;
        Map<String, dynamic> packet;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map) continue;
          packet = Map<String, dynamic>.from(decoded.map((k, v) => MapEntry(k.toString(), v)));
        } catch (_) { continue; }
        if (packet['senderId']?.toString() != _userId) continue;
        final isCommunity = entry['isCommunity'] == true;
        final recipient = packet['recipientId']?.toString() ?? '';
        if (isCommunity) {
          if (packet['type'] != 'blousab_group_e2e_envelope' || recipient != '*') continue;
        } else {
          if (packet['type'] != 'blousab_pair_chain_message' ||
              recipient.isEmpty || recipient == '*' || recipient == _userId) continue;
        }

        _pendingOutboxInFlight.add(id);
        try {
          final sent = isCommunity
              ? await _sendPendingGroupPacket(raw)
              : await _sendPendingDirectPacket(raw, recipient);
          await PendingMessageStore.instance.noteAttempt(id);
          if (!sent) {
            // Keep the exact ciphertext until a route becomes available.
            await _queueForMeshRoute(raw);
          }
        } catch (error) {
          debugPrint('Pending direct outbox retry failed ($id): $error');
          await PendingMessageStore.instance.noteAttempt(id);
        } finally {
          _pendingOutboxInFlight.remove(id);
        }
      }
    } catch (error) {
      debugPrint('Pending outbox scan failed: $error');
    } finally {
      _retryingPendingOutbox = false;
    }
  }

  Future<bool> _sendPendingGroupPacket(String raw) async {
    var sent = false;
    if (LocalNetworkService.instance.isRunning && LocalNetworkService.instance.peerCount > 0) {
      try { await LocalNetworkService.instance.broadcastMessage(raw); sent = true; } catch (_) {}
    }
    try { await BluetoothClassicService.instance.broadcastMessage(raw); sent = true; } catch (_) {}
    try { await WifiAwareService.instance.broadcastPacket(raw); sent = true; } catch (_) {}
    return sent;
  }

  Future<bool> _sendPendingDirectPacket(String raw, String recipientId) async {
    // Prefer a verified direct path to the actual recipient.
    if (WifiAwareService.instance.connectedPeerIds.contains(recipientId)) {
      try {
        await WifiAwareService.instance.sendPacket(peerId: recipientId, payload: raw);
        return true;
      } catch (_) {}
    }
    String? bluetoothAddress;
    for (final entry in _verifiedBluetooth.entries) {
      if (entry.value == recipientId) { bluetoothAddress = entry.key; break; }
    }
    if (bluetoothAddress != null) {
      try {
        await BluetoothClassicService.instance.sendMessage(address: bluetoothAddress, message: raw);
        return true;
      } catch (_) {}
    }
    Map<String, String>? lanPeer;
    for (final peer in LocalNetworkService.instance.discoveredPeers) {
      if (peer['id'] == recipientId && (peer['address'] ?? '').isNotEmpty) { lanPeer = peer; break; }
    }
    if (lanPeer != null) {
      try {
        await LocalNetworkService.instance.sendMessageToPeer(address: lanPeer['address']!, payload: raw);
        return true;
      } catch (_) {}
    }

    // Otherwise use a recently learned authenticated mesh next hop.
    final route = MeshRouteDirectory.instance.routeTo(recipientId);
    if (route == null || route.nextHopId == _userId) return false;
    if (WifiAwareService.instance.connectedPeerIds.contains(route.nextHopId)) {
      try {
        await WifiAwareService.instance.sendPacket(peerId: route.nextHopId, payload: raw);
        return true;
      } catch (_) {}
    }
    for (final entry in _verifiedBluetooth.entries) {
      if (entry.value != route.nextHopId) continue;
      try {
        await BluetoothClassicService.instance.sendMessage(address: entry.key, message: raw);
        return true;
      } catch (_) {}
    }
    Map<String, String>? relayLanPeer;
    for (final peer in LocalNetworkService.instance.discoveredPeers) {
      if (peer['id'] == route.nextHopId && (peer['address'] ?? '').isNotEmpty) { relayLanPeer = peer; break; }
    }
    if (relayLanPeer != null) {
      try {
        await LocalNetworkService.instance.sendMessageToPeer(address: relayLanPeer['address']!, payload: raw);
        return true;
      } catch (_) {}
    }
    return false;
  }

  /// Retries durable relay packets independently of whichever screen is open.
  /// Only already-connected Wi-Fi Aware peers and Bluetooth peers that passed
  /// the Blousab handshake are eligible; discovery alone is never a route.
  Future<void> retryQueuedRelays() async {
    if (!_started || _retryingRelayQueue) return;
    _retryingRelayQueue = true;
    try {
      final rows = await RelayQueueStore.instance.listReady();
      for (final row in rows) {
        final id = row['id']?.toString() ?? '';
        final payload = row['payload']?.toString() ?? '';
        if (id.isEmpty || payload.isEmpty || (row['attempts'] as num? ?? 0) >= 30) continue;
        Map<String, dynamic> packet;
        try { final value = jsonDecode(payload); if (value is! Map) continue; packet = Map<String, dynamic>.from(value); } catch (_) { continue; }
        final path = packet['relayPath'] is List ? (packet['relayPath'] as List).map((e) => e.toString()).toSet() : <String>{};
        final destination = packet['recipientId']?.toString() ?? '';
        var sent = false;
        try {
          final connected = await WifiAwareService.instance.refreshConnectedPeers();
          final metrics = connected.map((peerId) {
            final hint = destination.isEmpty || destination == '*' ? null : MeshRouteDirectory.instance.routeTo(destination);
            final via = hint != null && hint.nextHopId == peerId;
            return RelayPeerMetric(peerId: peerId, knownDestination: via, estimatedHops: via ? hint.hops : 99, successRate: via ? hint.successRate : 0, batteryPercent: 100);
          }).toList(growable: false);
          final selected = const RelayRoutePlanner().rank(peers: metrics, senderId: _userId, visitedPath: path, limit: 2);
          for (final peer in selected) {
            try {
              await WifiAwareService.instance.sendPacket(peerId: peer.peerId, payload: payload);
              sent = true;
              break; // One active next hop per attempt prevents duplicate mesh branches.
            } catch (_) {}
          }
        } catch (_) {}
        if (!sent) {
          final metrics = <RelayPeerMetric>[];
          for (final entry in _verifiedBluetooth.entries) {
            final hint = destination.isEmpty || destination == '*' ? null : MeshRouteDirectory.instance.routeTo(destination);
            final via = hint != null && hint.nextHopId == entry.value;
            metrics.add(RelayPeerMetric(peerId: entry.value, knownDestination: via, estimatedHops: via ? hint.hops : 99, successRate: via ? hint.successRate : 0, batteryPercent: 100));
          }
          final selected = const RelayRoutePlanner().rank(peers: metrics, senderId: _userId, visitedPath: path, limit: 2);
          for (final peer in selected) {
            String? address;
            for (final entry in _verifiedBluetooth.entries) { if (entry.value == peer.peerId) { address = entry.key; break; } }
            if (address == null) continue;
            try {
              await BluetoothClassicService.instance.sendMessage(address: address, message: payload);
              sent = true;
              break; // Fall through to another transport only if this path failed.
            } catch (_) {}
          }
        }
        if (!sent && LocalNetworkService.instance.isRunning && LocalNetworkService.instance.peerCount > 0) {
          try { await LocalNetworkService.instance.broadcastMessage(payload); sent = true; } catch (_) {}
        }
        if (sent) await RelayQueueStore.instance.noteAttempt(id);
      }
    } finally { _retryingRelayQueue = false; }
  }


  /// Re-requests missing chunks after app restart or transport reconnection.
  /// The receiver uses the authenticated peer identity stored with the transfer.
  Future<void> retryIncompleteFileTransfers() async {
    if (!_started) return;
    try {
      final transfers = await IncomingFileTransferStore.instance.incomplete();
      for (final transfer in transfers) {
        final transferId = transfer['transferId']?.toString() ?? '';
        final senderId = transfer['senderId']?.toString() ?? '';
        final conversationId = transfer['conversationId']?.toString() ?? '';
        final count = int.tryParse('${transfer['chunkCount'] ?? 0}') ?? 0;
        if (transferId.isEmpty || senderId.isEmpty || conversationId.isEmpty || count < 1 || count > 192) continue;
        final missing = await IncomingFileTransferStore.instance.missingIndices(transferId, expectedCount: count);
        if (missing.isEmpty || !await IncomingFileTransferStore.instance.markMissingRequest(transferId, missing)) continue;
        final now = DateTime.now().toIso8601String();
        final payload = jsonEncode({
          'type': 'file_chunk_missing', 'id': 'missing_${transferId}_${_userId}_${missing.join('_')}',
          'transferId': transferId, 'indices': missing.take(192).toList(),
          'conversationId': conversationId, 'senderId': _userId, 'recipientId': senderId,
          'relay': true, 'relayEnabled': true, 'hopCount': 0, 'hops': 0,
          'relayPath': <String>[], 'sentAt': now, 'createdAt': now,
        });
        await _queueForMeshRoute(payload);
        // The durable relay queue retries this request until a route to the
        // original sender becomes available; no direct-neighbour assumption.
      }
    } catch (error) {
      debugPrint('Mesh incomplete file retry failed: $error');
    }
  }

  /// Receives, persists, repairs and assembles file chunks without relying on
  /// ChatScreen. This keeps transfers alive while the user visits other tabs.
  Future<void> _handleIncomingFilePacket(
    String raw,
    String authenticatedPeerId,
    Future<void> Function(String payload) send,
  ) async {
    String transferId = '';
    try {
      final packet = jsonDecode(raw);
      if (packet is Map) transferId = packet['transferId']?.toString() ?? '';
    } catch (_) { return; }
    if (transferId.isEmpty) return;
    final previous = _incomingFileTasks[transferId];
    final completer = Completer<void>();
    _incomingFileTasks[transferId] = completer.future;
    try {
      if (previous != null) await previous;
      await _processIncomingFilePacket(raw, authenticatedPeerId, send);
    } finally {
      completer.complete();
      if (identical(_incomingFileTasks[transferId], completer.future)) {
        _incomingFileTasks.remove(transferId);
      }
    }
  }

  Future<void> _processIncomingFilePacket(
    String raw,
    String authenticatedPeerId,
    Future<void> Function(String payload) send,
  ) async {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      var packet = Map<String, dynamic>.from(decoded.map((k, v) => MapEntry(k.toString(), v)));
      var authenticatedE2eEnvelope = false;
      if (packet['type'] == 'blousab_pair_chain_message' && packet['transferId'] != null) {
        final ratchetSender = packet['senderId']?.toString() ?? '';
        if (!_isAuthenticatedPreviousHop(packet, authenticatedPeerId) ||
            packet['recipientId']?.toString() != _userId || ratchetSender.isEmpty) return;
        final clear = await PairwiseChainRatchetService.instance.decrypt(
          peerId: ratchetSender, packet: packet,
        );
        final inner = jsonDecode(clear);
        if (inner is! Map || inner['senderId']?.toString() != packet['senderId']?.toString() ||
            inner['recipientId']?.toString() != _userId ||
            inner['id']?.toString() != packet['id']?.toString() ||
            inner['transferId']?.toString() != packet['transferId']?.toString() ||
            inner['conversationId']?.toString() != packet['conversationId']?.toString()) return;
        packet = Map<String, dynamic>.from(inner.map((k, v) => MapEntry(k.toString(), v)));
        authenticatedE2eEnvelope = true;
      } else if (packet['type'] == 'blousab_e2e_envelope') {
        if (!_isAuthenticatedPreviousHop(packet, authenticatedPeerId) ||
            packet['recipientId']?.toString() != _userId) return;
        final clear = await BlousabCryptoIdentity.instance.openE2ePayload(packet, localUserId: _userId);
        final inner = jsonDecode(clear);
        if (inner is! Map || inner['senderId']?.toString() != packet['senderId']?.toString() ||
            inner['recipientId']?.toString() != _userId ||
            inner['id']?.toString() != packet['id']?.toString() ||
            inner['transferId']?.toString() != packet['transferId']?.toString() ||
            inner['conversationId']?.toString() != packet['conversationId']?.toString()) return;
        packet = Map<String, dynamic>.from(inner.map((k, v) => MapEntry(k.toString(), v)));
        authenticatedE2eEnvelope = true;
      } else if (packet['type'] == 'blousab_group_e2e_envelope') {
        if (!_isAuthenticatedPreviousHop(packet, authenticatedPeerId) ||
            packet['recipientId']?.toString() != '*') return;
        final groupId = packet['groupId']?.toString() ?? '';
        final senderId = packet['senderId']?.toString() ?? '';
        final community = await CommunityStore().findById(groupId);
        if (community == null || !community.members.any((m) => m.id == senderId && m.status.name == 'approved')) return;
        final clear = await GroupE2eCryptoService.instance.openGroupPayload(
          packet, localUserId: _userId,
          isApprovedMember: (id) => community.members.any((m) => m.id == id && m.status.name == 'approved'),
        );
        final inner = jsonDecode(clear);
        if (inner is! Map || inner['senderId']?.toString() != senderId ||
            inner['conversationId']?.toString() != groupId ||
            inner['id']?.toString() != packet['id']?.toString() ||
            inner['transferId']?.toString() != packet['transferId']?.toString()) return;
        packet = Map<String, dynamic>.from(inner.map((k, v) => MapEntry(k.toString(), v)));
        authenticatedE2eEnvelope = true;
      }
      final type = packet['type']?.toString() ?? '';
      if (type != 'file_chunk' && type != 'file_chunk_end') return;
      final senderId = packet['senderId']?.toString() ?? '';
      final recipientId = packet['recipientId']?.toString() ?? '';
      final transferId = packet['transferId']?.toString() ?? '';
      final conversationId = packet['conversationId']?.toString() ?? '';
      final isGroupPacket = await CommunityStore().findById(conversationId) != null;
      if ((!authenticatedE2eEnvelope && !_isAuthenticatedPreviousHop(packet, authenticatedPeerId)) ||
          senderId.isEmpty || senderId == _userId ||
          (isGroupPacket ? recipientId != '*' : recipientId != _userId) ||
          transferId.isEmpty || conversationId.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('blousab_blocked_peer_$senderId') ?? false) return;

      if (type == 'file_chunk_end') {
        final count = int.tryParse('${packet['chunkCount'] ?? 0}') ?? 0;
        final totalBytes = int.tryParse('${packet['totalBytes'] ?? 0}') ?? 0;
        final checksum = int.tryParse('${packet['checksum'] ?? -1}') ?? -1;
        if (count < 1 || count > 192 || totalBytes < 1 || totalBytes > 4 * 1024 * 1024 || checksum < 0) return;
        final safeName = (packet['fileName']?.toString() ?? 'ملف مستلم')
            .replaceAll(RegExp(r'[^\w.\- ()\u0600-\u06FF]'), '_');
        await IncomingFileTransferStore.instance.beginTransfer(
          transferId: transferId, fileName: safeName, senderId: senderId,
          senderName: packet['senderName']?.toString() ?? 'مستخدم',
          conversationId: conversationId, chunkCount: count,
          totalBytes: totalBytes, checksum: checksum);
        final missing = await IncomingFileTransferStore.instance.missingIndices(
          transferId, expectedCount: count);
        if (missing.isNotEmpty && await IncomingFileTransferStore.instance.markMissingRequest(transferId, missing)) {
          final now = DateTime.now().toIso8601String();
          await send(jsonEncode({
            'type': 'file_chunk_missing',
            'id': 'missing_${transferId}_${_userId}_${missing.join('_')}',
            'transferId': transferId, 'indices': missing.take(192).toList(),
            'conversationId': conversationId, 'senderId': _userId,
            'recipientId': senderId, 'relay': true, 'relayEnabled': true,
            'hopCount': 0, 'hops': 0, 'relayPath': <String>[],
            'sentAt': now, 'createdAt': now,
          }));
        }
        return;
      }

      final index = int.tryParse('${packet['index'] ?? -1}') ?? -1;
      final count = int.tryParse('${packet['chunkCount'] ?? 0}') ?? 0;
      final totalBytes = int.tryParse('${packet['totalBytes'] ?? -1}') ?? -1;
      final checksum = int.tryParse('${packet['checksum'] ?? -1}') ?? -1;
      final encoded = packet['data']?.toString() ?? '';
      if (count < 1 || count > 192 || index < 0 || index >= count ||
          totalBytes < 1 || totalBytes > 4 * 1024 * 1024 || checksum < 0 ||
          encoded.isEmpty || encoded.length > 48 * 1024) return;
      final bytes = base64Decode(encoded);
      if (bytes.isEmpty || bytes.length > 24 * 1024) return;
      final fileName = (packet['fileName']?.toString() ?? 'ملف مستلم')
          .replaceAll(RegExp(r'[^\w.\- ()\u0600-\u06FF]'), '_');
      final senderName = packet['senderName']?.toString() ?? 'مستخدم';
      final saved = await IncomingFileTransferStore.instance.saveChunk(
        transferId: transferId, fileName: fileName, senderId: senderId,
        senderName: senderName, conversationId: conversationId,
        chunkCount: count, totalBytes: totalBytes, checksum: checksum,
        index: index, bytes: bytes);
      if (!saved) return;
      final state = await IncomingFileTransferStore.instance.load(transferId);
      if (state == null) return;
      final chunks = Map<String, dynamic>.from(state['chunks'] as Map? ?? {});
      if (chunks.length != count) return;
      final builder = BytesBuilder(copy: false);
      for (var i = 0; i < count; i++) {
        final encodedPart = chunks['$i'];
        if (encodedPart == null) return;
        final part = base64Decode(encodedPart.toString());
        if (part.isEmpty || part.length > 24 * 1024) return;
        builder.add(part);
      }
      final complete = builder.takeBytes();
      if (complete.length != totalBytes || _crc32(complete) != checksum) {
        await IncomingFileTransferStore.instance.clearChunks(transferId);
        await retryIncompleteFileTransfers();
        return;
      }

      final store = MessageStore();
      final existing = await store.getMessages(conversationId);
      if (!existing.any((message) => message.id == transferId)) {
        final directory = await getApplicationDocumentsDirectory();
        final file = File('${directory.path}/received_${DateTime.now().millisecondsSinceEpoch}_$fileName');
        await file.writeAsBytes(complete, flush: true);
        await store.saveMessage(BlousabMessage(
          id: transferId, conversationId: conversationId, senderId: senderId,
          senderName: senderName, text: '📎 $fileName',
          sentAt: DateTime.tryParse(packet['sentAt']?.toString() ?? '') ?? DateTime.now(),
          isMine: false, attachmentPath: file.path, attachmentName: fileName));
      }
      final now = DateTime.now().toUtc().toIso8601String();
      final ackId = 'ack_delivery_ack_${transferId}_$_userId';
      final clearAck = <String, Object?>{
        'type': 'delivery_ack', 'id': ackId, 'ackFor': transferId,
        'conversationId': conversationId, 'senderId': _userId,
        // For group envelopes, the authenticated target is inside ciphertext;
        // the outer group envelope remains a broadcast for mesh transport.
        'recipientId': senderId, 'senderName': _userName,
        'relay': true, 'relayEnabled': true, 'hopCount': 0, 'hops': 0,
        'relayPath': <String>[], 'sentAt': now, 'createdAt': now,
      };
      String? encryptedAck;
      if (isGroupPacket) {
        final envelope = await GroupE2eCryptoService.instance.sealGroupPayload(
          groupId: conversationId, senderId: _userId,
          payload: jsonEncode(clearAck), messageId: ackId,
          routingFields: <String, Object?>{
            'conversationId': conversationId, 'sentAt': now,
            'relay': true, 'relayEnabled': true, 'hopCount': 0,
            'hops': 0, 'relayPath': <String>[],
          },
        );
        encryptedAck = jsonEncode(envelope);
      } else if (await PairwiseChainRatchetService.instance.hasActiveSession(senderId)) {
        final envelope = await PairwiseChainRatchetService.instance.encrypt(
          peerId: senderId, plaintext: jsonEncode(clearAck),
          routingFields: <String, Object?>{
            'id': ackId, 'conversationId': conversationId,
            'senderId': _userId, 'recipientId': senderId,
            'sentAt': now, 'createdAt': now,
            'relay': true, 'relayEnabled': true, 'hopCount': 0,
            'hops': 0, 'relayPath': <String>[],
          },
        );
        encryptedAck = jsonEncode(envelope);
      }
      // Never fall back to a clear-text receipt. If a pairwise session is not
      // established, the sender will retain the transfer in its durable outbox.
      if (encryptedAck != null) {
        if (authenticatedPeerId == senderId) {
          try { await send(encryptedAck); } catch (_) { await _queueForMeshRoute(encryptedAck); }
        } else {
          await _queueForMeshRoute(encryptedAck);
        }
      }
      await IncomingFileTransferStore.instance.remove(transferId);
    } catch (error) {
      debugPrint('Mesh incoming file packet failed: $error');
    }
  }

  /// Resends only the requested file chunks from the durable sender outbox.
  /// This is app-scoped so the sender does not need to keep ChatScreen open.
  Future<void> _handleMissingChunkRequest(
    String raw,
    String authenticatedPeerId,
    Future<void> Function(String payload) send,
  ) async {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['type'] != 'file_chunk_missing' ||
          !_isAuthenticatedPreviousHop(decoded, authenticatedPeerId) ||
          decoded['recipientId']?.toString() != _userId) return;
      final transferId = decoded['transferId']?.toString() ?? '';
      final conversationId = decoded['conversationId']?.toString() ?? '';
      final requesterId = decoded['senderId']?.toString() ?? '';
      final rawIndices = decoded['indices'];
      if (transferId.isEmpty || conversationId.isEmpty || requesterId.isEmpty ||
          rawIndices is! List ||
          rawIndices.isEmpty || rawIndices.length > 192) return;

      final entries = await PendingMessageStore.instance.list();
      final matches = entries.where((entry) =>
        entry['messageId']?.toString() == transferId &&
        entry['kind'] == 'file_chunk_transfer').toList();
      if (matches.isEmpty) return;
      final entry = matches.first;
      if (entry['conversationId']?.toString() != conversationId) return;
      final path = entry['localPath']?.toString() ?? '';
      if (path.isEmpty) return;
      final file = File(path);
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      const maxBytes = 4 * 1024 * 1024;
      const chunkBytes = 24 * 1024;
      if (bytes.isEmpty || bytes.length > maxBytes) return;
      final count = (bytes.length / chunkBytes).ceil();
      final checksum = _crc32(bytes);
      final unique = <int>{};
      for (final value in rawIndices) {
        final index = int.tryParse('$value');
        if (index != null && index >= 0 && index < count) unique.add(index);
      }
      if (unique.isEmpty) return;
      for (final index in unique) {
        final start = index * chunkBytes;
        final end = (start + chunkBytes).clamp(0, bytes.length).toInt();
        final now = DateTime.now().toIso8601String();
        final clearPacket = jsonEncode({
          'type': 'file_chunk', 'id': '${transferId}_part_$index',
          'transferId': transferId, 'index': index, 'chunkCount': count,
          'totalBytes': bytes.length, 'checksum': checksum,
          'fileName': entry['fileName']?.toString() ?? 'ملف',
          'conversationId': conversationId, 'senderId': _userId,
          'senderName': _userName, 'recipientId': requesterId,
          'relay': true, 'relayEnabled': true, 'hopCount': 0, 'hops': 0,
          'relayPath': <String>[], 'sentAt': now, 'createdAt': now,
          'data': base64Encode(bytes.sublist(start, end)),
        });
        final ratchetPacket = await PairwiseChainRatchetService.instance.encrypt(
          peerId: requesterId,
          plaintext: clearPacket,
          routingFields: <String, Object?>{
            'id': '${transferId}_part_$index', 'conversationId': conversationId,
            'transferId': transferId, 'index': index, 'chunkCount': count,
            'totalBytes': bytes.length, 'checksum': checksum,
            'relay': true, 'relayEnabled': true, 'hopCount': 0, 'hops': 0,
            'relayPath': <String>[], 'sentAt': now, 'createdAt': now,
          },
        );
        final packet = jsonEncode(ratchetPacket);
        await send(packet);
      }
    } catch (error) {
      debugPrint('Mesh missing chunk resend failed: $error');
    }
  }

  int _crc32(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? ((crc >> 1) ^ 0xEDB88320) : (crc >> 1);
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  /// Owns direct Ratchet packet consumption at application scope. The same
  /// packet may arrive over Bluetooth, Wi-Fi Aware and LAN; serialize by
  /// packet ID and persist the seen marker only after authenticated decryption
  /// and local persistence have succeeded.
  Future<void> _handleLocalPairwisePacket(
    String raw,
    String authenticatedPeerId,
    Future<void> Function(String payload) sendToPreviousHop,
  ) async {
    Map<String, dynamic> outer;
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return;
      outer = Map<String, dynamic>.from(value.map((k, v) => MapEntry(k.toString(), v)));
    } catch (_) { return; }
    if (outer['type'] != 'blousab_pair_chain_message' ||
        outer['recipientId']?.toString() != _userId ||
        outer['transferId'] != null ||
        !_isAuthenticatedPreviousHop(outer, authenticatedPeerId)) return;

    final packetId = outer['id']?.toString() ?? '';
    final senderId = outer['senderId']?.toString() ?? '';
    final conversationId = outer['conversationId']?.toString() ?? '';
    if (packetId.isEmpty || senderId.isEmpty || senderId == _userId ||
        conversationId.isEmpty || conversationId == '*') return;

    final previous = _incomingRatchetTasks[packetId];
    if (previous != null) {
      await previous;
      return;
    }
    final completer = Completer<void>();
    _incomingRatchetTasks[packetId] = completer.future;
    try {
      final prefs = await SharedPreferences.getInstance();
      final seenKey = 'blousab_ratchet_seen_$packetId';
      if (prefs.getBool(seenKey) == true) {
        final previousType = prefs.getString('blousab_ratchet_seen_type_$packetId') ?? '';
        if (previousType == 'chat' || previousType == 'text' || previousType == 'file') {
          await _sendPairwiseReceipt(
            messageId: packetId, conversationId: conversationId,
            recipientId: senderId, type: 'delivery_ack',
            sendToPreviousHop: sendToPreviousHop,
            authenticatedPeerId: authenticatedPeerId,
          );
        }
        return;
      }

      final clear = await PairwiseChainRatchetService.instance.decrypt(
        peerId: senderId, packet: outer,
      );
      final decoded = jsonDecode(clear);
      if (decoded is! Map) return;
      final inner = Map<String, dynamic>.from(decoded.map((k, v) => MapEntry(k.toString(), v)));
      if (inner['senderId']?.toString() != senderId ||
          inner['recipientId']?.toString() != _userId ||
          inner['id']?.toString() != packetId ||
          inner['conversationId']?.toString() != conversationId) return;

      final prefsForBlock = await SharedPreferences.getInstance();
      if (prefsForBlock.getBool('blousab_blocked_peer_$senderId') ?? false) return;
      final innerType = inner['type']?.toString() ?? '';
      if (innerType == 'delivery_ack' || innerType == 'read_ack') {
        final ackFor = inner['ackFor']?.toString() ?? '';
        if (ackFor.isEmpty) return;
        if (innerType == 'delivery_ack') {
          await MessageStore().markDelivered(conversationId, ackFor);
          await PendingMessageStore.instance.remove(ackFor);
          await RelayQueueStore.instance.remove(ackFor);
        } else {
          await MessageStore().markRead(conversationId, ackFor);
        }
      } else if (innerType == 'chat' || innerType == 'text' || innerType == 'file') {
        // Direct-chat payloads only. Community messages use group sender keys.
        if (await CommunityStore().findById(conversationId) != null) return;
        final text = inner['text']?.toString() ?? '';
        String? attachmentPath;
        String? attachmentName;
        if (innerType == 'file') {
          attachmentName = (inner['fileName']?.toString() ?? 'ملف مستلم');
          final encoded = inner['data']?.toString() ?? '';
          if (encoded.isEmpty || encoded.length > 6000000) return;
          final bytes = base64Decode(encoded);
          final dir = await getApplicationDocumentsDirectory();
          final safeName = attachmentName.replaceAll(RegExp(r'[^\w.\- ()\u0600-\u06FF]'), '_');
          final file = File('${dir.path}/received_${DateTime.now().microsecondsSinceEpoch}_$safeName');
          await file.writeAsBytes(bytes, flush: true);
          attachmentPath = file.path;
        } else if (text.trim().isEmpty) {
          return;
        }
        await MessageStore().saveMessage(BlousabMessage(
          id: packetId,
          conversationId: conversationId,
          senderId: senderId,
          senderName: inner['senderName']?.toString() ?? 'مستخدم',
          text: innerType == 'file' ? '📎 ${attachmentName ?? 'ملف'}' : text,
          sentAt: DateTime.tryParse(inner['sentAt']?.toString() ?? '')?.toLocal() ?? DateTime.now(),
          isMine: false,
          attachmentPath: attachmentPath,
          attachmentName: attachmentName,
        ));
        await prefs.setString('blousab_ratchet_seen_type_$packetId', innerType);
        await prefs.setBool(seenKey, true);
        await _sendPairwiseReceipt(
          messageId: packetId, conversationId: conversationId,
          recipientId: senderId, type: 'delivery_ack',
          sendToPreviousHop: sendToPreviousHop,
          authenticatedPeerId: authenticatedPeerId,
        );
      } else {
        return;
      }
      await prefs.setString('blousab_ratchet_seen_type_$packetId', innerType);
      await prefs.setBool(seenKey, true);
    } catch (error) {
      debugPrint('App-scoped Ratchet message processing failed: $error');
    } finally {
      completer.complete();
      if (identical(_incomingRatchetTasks[packetId], completer.future)) {
        _incomingRatchetTasks.remove(packetId);
      }
    }
  }

  Future<void> _sendPairwiseReceipt({
    required String messageId,
    required String conversationId,
    required String recipientId,
    required String type,
    required Future<void> Function(String payload) sendToPreviousHop,
    required String authenticatedPeerId,
  }) async {
    if (!await PairwiseChainRatchetService.instance.hasActiveSession(recipientId)) return;
    final now = DateTime.now().toUtc().toIso8601String();
    final receiptId = 'ack_${type}_${messageId}_$_userId';
    final clear = <String, Object?>{
      'type': type, 'id': receiptId, 'ackFor': messageId,
      'conversationId': conversationId, 'senderId': _userId,
      'recipientId': recipientId, 'senderName': _userName,
      'sentAt': now, 'createdAt': now,
      'relay': true, 'relayEnabled': true, 'hopCount': 0, 'hops': 0,
      'relayPath': <String>[],
    };
    final encrypted = await PairwiseChainRatchetService.instance.encrypt(
      peerId: recipientId,
      plaintext: jsonEncode(clear),
      routingFields: <String, Object?>{
        'id': receiptId, 'conversationId': conversationId,
        'senderId': _userId, 'recipientId': recipientId,
        'sentAt': now, 'createdAt': now,
        'relay': true, 'relayEnabled': true, 'hopCount': 0, 'hops': 0,
        'relayPath': <String>[],
      },
    );
    final raw = jsonEncode(encrypted);
    if (authenticatedPeerId == recipientId) {
      try { await sendToPreviousHop(raw); return; } catch (_) {}
    }
    await _queueForMeshRoute(raw);
  }

  /// Handles delivery/read receipts independently of ChatScreen. This keeps
  /// receipt return paths alive while the user navigates to other app pages.
  /// The transport peer ID is supplied by the verified Bluetooth handshake or
  /// the authenticated Wi-Fi Aware peer record; packet senderId must match it.
  Future<void> _handleMeshControlPacket(String raw, String authenticatedPeerId, [Future<void> Function(String payload)? sendReply]) async {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final type = decoded['type']?.toString() ?? '';
      if (!_isAuthenticatedPreviousHop(decoded, authenticatedPeerId)) return;
      final packetId = decoded['id']?.toString() ?? decoded['messageId']?.toString() ?? '';
      final recipientId = decoded['recipientId']?.toString() ?? '*';
      if (packetId.isEmpty) return;
      final packetHops = int.tryParse('${decoded['hopCount'] ?? decoded['hops'] ?? 0}') ?? 0;
      if (packetHops < 0 || packetHops > 5) return;

      // Ratchet session setup is handled by the app-scoped runtime as well as
      // the visible chat screen, so a peer can accept a signed offer while
      // navigating elsewhere. The answer follows the authenticated reverse hop.
      if ((type == 'blousab_ratchet_offer' || type == 'blousab_ratchet_answer') &&
          recipientId == _userId) {
        try {
          final response = await PairwiseChainRatchetService.instance.handleHandshakePacket(
            packet: decoded, localUserId: _userId,
          );
          if (response != null && sendReply != null) await sendReply(jsonEncode(response));
        } catch (error) {
          debugPrint('Ratchet handshake packet rejected: $error');
        }
        return;
      }

      // End-to-end receipts retire the original queued payload. Receipts are
      // then relayed by the same app-scoped path as other mesh packets.
      if (type == 'delivery_ack' || type == 'read_ack') {
        final ackFor = decoded['ackFor']?.toString() ?? '';
        if (ackFor.isEmpty || recipientId.isEmpty) return;
        await RelayQueueStore.instance.remove(ackFor);
        if (recipientId == _userId) {
          await PendingMessageStore.instance.remove(ackFor);
          await RelayQueueStore.instance.remove(packetId);
          return;
        }
      } else {
        // Route advertisements and profile/control handshakes are not user
        // payloads. File chunks and chat packets are, and must keep moving even
        // when no ChatScreen is mounted.
        if (type == 'mesh_route_advert' || type == 'profile_card' ||
            type == 'profile_update' || type == 'hello' || type == 'hello_ack') return;
        if (decoded['relayEnabled'] != true && decoded['relay'] != true) return;
        if (recipientId == _userId) return; // final recipient handles it locally
      }

      final created = DateTime.tryParse(
        decoded['sentAt']?.toString() ?? decoded['createdAt']?.toString() ?? '',
      );
      if (created == null || DateTime.now().difference(created) > RelayQueueStore.maxAge ||
          created.isAfter(DateTime.now().add(const Duration(minutes: 5)))) return;
      final hops = int.tryParse('${decoded['hopCount'] ?? decoded['hops'] ?? 0}') ?? 0;
      if (hops < 0 || hops >= 5) return;
      final path = decoded['relayPath'] is List
          ? (decoded['relayPath'] as List).map((value) => value.toString()).toList()
          : <String>[];
      if (path.contains(_userId)) return;
      // A group broadcast is both a local delivery and a relay candidate.
      // Persist its plaintext only on an approved member device; non-members
      // can still forward the signed ciphertext without seeing the content.
      if (type == 'blousab_group_e2e_envelope' && recipientId == '*') {
        final groupId = decoded['groupId']?.toString() ?? '';
        final senderId = decoded['senderId']?.toString() ?? '';
        final community = await CommunityStore().findById(groupId);
        if (community != null &&
            community.members.any((m) => m.id == _userId && m.status.name == 'approved') &&
            community.members.any((m) => m.id == senderId && m.status.name == 'approved')) {
          try {
            final clear = await GroupE2eCryptoService.instance.openGroupPayload(
              decoded, localUserId: _userId,
              isApprovedMember: (id) => community.members.any((m) => m.id == id && m.status.name == 'approved'),
            );
            final inner = jsonDecode(clear);
            if (inner is Map && inner['senderId']?.toString() == senderId &&
                inner['conversationId']?.toString() == groupId &&
                inner['id']?.toString() == packetId && senderId != _userId) {
              final innerType = inner['type']?.toString() ?? '';
              if (innerType == 'chat') {
                await MessageStore().saveMessage(BlousabMessage(
                  id: packetId, conversationId: groupId, senderId: senderId,
                  senderName: inner['senderName']?.toString() ?? 'مستخدم',
                  text: inner['text']?.toString() ?? '',
                  sentAt: DateTime.tryParse(inner['sentAt']?.toString() ?? '') ?? DateTime.now(),
                  isMine: false,
                ));
                // App-scoped group delivery receipt: the chat screen need not
                // be mounted for the sender to receive a confirmation.
                final now = DateTime.now().toUtc().toIso8601String();
                final ackId = 'ack_delivery_ack_${packetId}_${_userId}_runtime';
                final clearAck = <String, Object?>{
                  'type': 'delivery_ack', 'id': ackId, 'ackFor': packetId,
                  'conversationId': groupId, 'senderId': _userId,
                  'recipientId': senderId, 'senderName': _userName,
                  'sentAt': now, 'createdAt': now,
                  'relay': true, 'relayEnabled': true, 'hopCount': 0,
                  'hops': 0, 'relayPath': <String>[],
                };
                final ackEnvelope = await GroupE2eCryptoService.instance.sealGroupPayload(
                  groupId: groupId, senderId: _userId,
                  payload: jsonEncode(clearAck), messageId: ackId,
                  routingFields: <String, Object?>{
                    'conversationId': groupId, 'sentAt': now,
                    'relay': true, 'relayEnabled': true, 'hopCount': 0,
                    'hops': 0, 'relayPath': <String>[],
                  },
                );
                await _queueForMeshRoute(jsonEncode(ackEnvelope));
              } else if ((innerType == 'delivery_ack' || innerType == 'read_ack') &&
                  inner['recipientId']?.toString() == _userId) {
                final ackFor = inner['ackFor']?.toString() ?? '';
                if (ackFor.isNotEmpty) {
                  if (innerType == 'delivery_ack') {
                    await MessageStore().markDelivered(groupId, ackFor);
                    await PendingMessageStore.instance.remove(ackFor);
                    await RelayQueueStore.instance.remove(ackFor);
                  } else {
                    await MessageStore().markRead(groupId, ackFor);
                  }
                }
              }
            }
          } catch (error) {
            debugPrint('Group E2E local delivery deferred/rejected: $error');
          }
        }
      }

      // Persist the forwarded packet before marking it seen. The queue and
      // seen-ID files are separate durable records; marking first creates a
      // crash window where a restart would suppress a packet that was never
      // queued. enqueue() is idempotent by packet ID, so duplicate arrivals
      // remain safe if the process stops between these two writes.
      final forwarded = Map<String, dynamic>.from(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
      forwarded['relay'] = true;
      forwarded['relayEnabled'] = true;
      forwarded['hopCount'] = hops + 1;
      forwarded['hops'] = hops + 1;
      forwarded['relayPath'] = <String>[...path, _userId];
      await RelayQueueStore.instance.enqueue(forwarded);
      await RelayQueueStore.instance.markSeen(packetId);
      await retryQueuedRelays();
    } catch (error) {
      debugPrint('Ignored malformed mesh receipt: $error');
    }
  }

  void _acceptRoutePacket(String raw, String authenticatedPeerId) {
    try {
      final packet = jsonDecode(raw);
      if (packet is! Map || packet['type'] != 'mesh_route_advert' ||
          packet['protocol'] != 'blousab-mesh-route-v1' ||
          packet['senderId']?.toString() != authenticatedPeerId) return;
      final hints = packet['hints'];
      if (hints is! List || hints.length > 64) return;
      for (final item in hints) {
        if (item is! Map) continue;
        final destination = item['destinationId']?.toString() ?? '';
        final hops = int.tryParse('${item['hops'] ?? ''}');
        final success = int.tryParse('${item['successRate'] ?? 50}') ?? 50;
        if (destination.isEmpty || destination == _userId || hops == null ||
            hops < 0 || hops >= MeshRouteDirectory.maxAdvertisedHops) continue;
        MeshRouteDirectory.instance.learn(
          fromPeerId: authenticatedPeerId,
          destinationId: destination,
          advertisedHops: hops,
          successRate: success.clamp(0, 100).toInt(),
        );
      }
    } catch (error) {
      debugPrint('Ignored malformed mesh route packet: $error');
    }
  }

  Future<void> dispose() async {
    _relayTimer?.cancel();
    _relayTimer = null;
    await _bluetoothSub?.cancel();
    await _wifiSub?.cancel();
    await _lanSub?.cancel();
    _bluetoothSub = null;
    _wifiSub = null;
    _lanSub = null;
    _verifiedBluetooth.clear();
    _incomingFileTasks.clear();
    _started = false;
  }
}
