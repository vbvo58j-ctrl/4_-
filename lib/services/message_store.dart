
import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/blousab_message.dart';

class MessageStore {
  static final StreamController<String> _updates = StreamController<String>.broadcast();
  static Future<void> _writeTail = Future<void>.value();
  static Stream<String> get updates => _updates.stream;

  Future<void> _serializeWrite(Future<void> Function() action) {
    final next = _writeTail.then((_) => action());
    _writeTail = next.catchError((_) {});
    return next;
  }

  String _storageKey(String conversationId) =>
      'wasl_messages_$conversationId';

  Future<List<BlousabMessage>> getMessages(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey(conversationId));

    if (raw == null || raw.isEmpty) {
      return [];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final messages = decoded
          .map(
            (item) => BlousabMessage.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();

      messages.sort((a, b) => a.sentAt.compareTo(b.sentAt));
      return messages;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveMessage(BlousabMessage message) => _serializeWrite(() async {
    final prefs = await SharedPreferences.getInstance();
    final messages = await getMessages(message.conversationId);
    if (messages.any((item) => item.id == message.id)) return;
    messages.add(message);
    await prefs.setString(
      _storageKey(message.conversationId),
      jsonEncode(messages.map((item) => item.toJson()).toList()),
    );
    _updates.add(message.conversationId);
  });

  Future<void> markSent(String conversationId, String messageId) async =>
      _updateStatus(conversationId, messageId, 'sent');

  Future<void> markDelivered(String conversationId, String messageId) async =>
      _updateStatus(conversationId, messageId, 'delivered');

  Future<void> markRead(String conversationId, String messageId) async =>
      _updateStatus(conversationId, messageId, 'read');

  Future<void> _updateStatus(String conversationId, String messageId, String status) => _serializeWrite(() async {
    final prefs = await SharedPreferences.getInstance();
    final messages = await getMessages(conversationId);
    final index = messages.indexWhere((item) => item.id == messageId && item.isMine);
    if (index < 0) return;
    final old = messages[index];
    int rank(String value) => switch (value) {
      'read' => 3, 'delivered' => 2, 'sent' => 1, _ => 0,
    };
    if (rank(status) <= rank(old.deliveryStatus)) return;
    messages[index] = BlousabMessage(
      id: old.id, conversationId: old.conversationId, senderId: old.senderId,
      senderName: old.senderName, text: old.text, sentAt: old.sentAt,
      isMine: old.isMine, isSent: status == 'sent' || status == 'delivered' || status == 'read' || old.isSent,
      isDelivered: status == 'delivered' || status == 'read' || old.isDelivered,
      isRead: status == 'read' || old.isRead, deliveryStatus: status,
      attachmentPath: old.attachmentPath, attachmentName: old.attachmentName,
    );
    await prefs.setString(_storageKey(conversationId),
      jsonEncode(messages.map((item) => item.toJson()).toList()));
    _updates.add(conversationId);
  });

  Future<void> clearMessages(String conversationId) => _serializeWrite(() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey(conversationId));
    _updates.add(conversationId);
  });
}