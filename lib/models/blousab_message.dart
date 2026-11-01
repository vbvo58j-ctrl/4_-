class BlousabMessage {
  final String id;
  final String conversationId;
  final String senderId;
  final String senderName;
  final String text;
  final DateTime sentAt;
  final bool isMine;
  final bool isSent;
  final bool isDelivered;
  final bool isRead;
  final String deliveryStatus;
  final String? attachmentPath;
  final String? attachmentName;

  const BlousabMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.sentAt,
    required this.isMine,
    this.isSent = false,
    this.isDelivered = false,
    this.isRead = false,
    this.deliveryStatus = 'pending',
    this.attachmentPath,
    this.attachmentName,
  });

  BlousabMessage copyWith({bool? isSent, bool? isDelivered, bool? isRead, String? deliveryStatus}) => BlousabMessage(
    id: id, conversationId: conversationId, senderId: senderId, senderName: senderName,
    text: text, sentAt: sentAt, isMine: isMine,
    isSent: isSent ?? this.isSent,
    isDelivered: isDelivered ?? this.isDelivered,
    isRead: isRead ?? this.isRead,
    deliveryStatus: deliveryStatus ?? this.deliveryStatus,
    attachmentPath: attachmentPath, attachmentName: attachmentName,
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'conversationId': conversationId, 'senderId': senderId,
    'senderName': senderName, 'text': text, 'sentAt': sentAt.toIso8601String(),
    'isMine': isMine, 'isSent': isSent, 'isDelivered': isDelivered,
    'isRead': isRead, 'deliveryStatus': deliveryStatus,
    'attachmentPath': attachmentPath, 'attachmentName': attachmentName,
  };

  factory BlousabMessage.fromJson(Map<String, dynamic> json) {
    final status = json['deliveryStatus'] as String? ?? ((json['isRead'] as bool? ?? false) ? 'read' : ((json['isDelivered'] as bool? ?? false) ? 'delivered' : 'pending'));
    return BlousabMessage(
      id: json['id'] as String,
      conversationId: json['conversationId'] as String,
      senderId: json['senderId'] as String,
      senderName: json['senderName'] as String,
      text: json['text'] as String,
      sentAt: DateTime.parse(json['sentAt'] as String),
      isMine: json['isMine'] as bool? ?? false,
      isSent: json['isSent'] as bool? ?? (status == 'sent' || status == 'delivered' || status == 'read'),
      isDelivered: json['isDelivered'] as bool? ?? (status == 'delivered' || status == 'read'),
      isRead: json['isRead'] as bool? ?? status == 'read',
      deliveryStatus: status,
      attachmentPath: json['attachmentPath'] as String?,
      attachmentName: json['attachmentName'] as String?,
    );
  }
}
