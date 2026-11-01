
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/blousab_community.dart';

class CommunityStore {
  static const String _storageKey = 'wasl_communities_v1';

  Future<List<BlousabCommunity>> getCommunities() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);

    if (raw == null || raw.isEmpty) {
      return [];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;

      return decoded
          .map(
            (item) => BlousabCommunity.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();
    } catch (_) {
      // Recover from an older or partially corrupted local cache so creation is not blocked.
      await prefs.remove(_storageKey);
      return [];
    }
  }

  Future<void> _save(List<BlousabCommunity> communities) async {
    final prefs = await SharedPreferences.getInstance();

    final raw = jsonEncode(
      communities.map((community) => community.toJson()).toList(),
    );

    final saved = await prefs.setString(_storageKey, raw);

    if (!saved) {
      throw Exception('تعذر حفظ بيانات المجتمعات.');
    }
  }

  String _generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();

    return List.generate(
      8,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }

  Future<BlousabCommunity> createCommunity({
    required String name,
    required String ownerId,
    required String ownerName,
  }) async {
    final cleanName = name.trim();
    // Recover a missing owner ID defensively instead of failing community creation.
    final effectiveOwnerId = ownerId.trim().isEmpty
        ? 'owner_${DateTime.now().microsecondsSinceEpoch}'
        : ownerId.trim();

    if (cleanName.isEmpty) {
      throw ArgumentError('أدخل اسم المجتمع.');
    }

    final communities = await getCommunities();

    String code;
    do {
      code = _generateCode();
    } while (communities.any((c) => c.joinCode == code));

    final community = BlousabCommunity(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: cleanName,
      ownerId: effectiveOwnerId,
      joinCode: code,
      members: [
        BlousabMember(
          id: effectiveOwnerId,
          name: ownerName.trim().isEmpty ? 'المنشئ' : ownerName.trim(),
          status: MemberStatus.approved,
          isOwner: true,
        ),
      ],
    );

    communities.add(community);
    await _save(communities);

    return community;
  }

  Future<BlousabCommunity?> findByJoinCode(String code) async {
    final normalized = code.trim().toUpperCase();

    if (normalized.isEmpty) return null;

    final communities = await getCommunities();

    for (final community in communities) {
      if (community.joinCode == normalized) {
        return community;
      }
    }

    return null;
  }

  Future<void> requestJoin({
    required String joinCode,
    required String memberId,
    required String memberName,
  }) async {
    final communities = await getCommunities();
    final index = communities.indexWhere(
      (c) => c.joinCode == joinCode.trim().toUpperCase(),
    );

    if (index == -1) {
      throw Exception('رمز المجتمع غير صحيح.');
    }

    final community = communities[index];

    if (memberId.trim().isEmpty || memberName.trim().isEmpty) {
      throw ArgumentError('أدخل معرّف العضو واسمه.');
    }

    if (community.members.any((m) => m.id == memberId)) {
      throw Exception('هذا العضو مسجل في المجتمع بالفعل.');
    }

    community.members.add(
      BlousabMember(
        id: memberId,
        name: memberName.trim(),
        status: MemberStatus.pending,
      ),
    );

    await _save(communities);
  }


  /// Imports a community received from its owner after the owner approves a
  /// join request. The local user's membership is marked approved.
  Future<void> saveJoinedCommunity({
    required Map<String, dynamic> communityJson,
    required String localUserId,
    required String localUserName,
  }) async {
    final incoming = BlousabCommunity.fromJson(communityJson);
    if (incoming.id.isEmpty || incoming.joinCode.isEmpty) {
      throw Exception('بيانات المجتمع المستلمة غير صالحة.');
    }
    final communities = await getCommunities();
    final existingIndex = communities.indexWhere((c) => c.id == incoming.id);
    final localMemberIndex = incoming.members.indexWhere((m) => m.id == localUserId);
    if (localMemberIndex >= 0) {
      incoming.members[localMemberIndex].name = localUserName;
      incoming.members[localMemberIndex].status = MemberStatus.approved;
    } else {
      incoming.members.add(BlousabMember(
        id: localUserId,
        name: localUserName,
        status: MemberStatus.approved,
      ));
    }
    if (existingIndex >= 0) {
      communities[existingIndex] = incoming;
    } else {
      communities.add(incoming);
    }
    await _save(communities);
  }

  Future<BlousabCommunity?> findById(String id) async {
    for (final community in await getCommunities()) {
      if (community.id == id) return community;
    }
    return null;
  }

  Future<void> setMemberStatus({
    required String communityId,
    required String ownerId,
    required String memberId,
    required MemberStatus status,
  }) async {
    if (status == MemberStatus.pending) {
      throw ArgumentError('لا يمكن تغيير الحالة إلى قيد الانتظار.');
    }

    final communities = await getCommunities();
    final index = communities.indexWhere((c) => c.id == communityId);

    if (index == -1) {
      throw Exception('المجتمع غير موجود.');
    }

    final community = communities[index];

    if (community.ownerId != ownerId) {
      throw Exception('فقط منشئ المجتمع يمكنه إدارة الأعضاء.');
    }

    final memberIndex = community.members.indexWhere(
      (m) => m.id == memberId,
    );

    if (memberIndex == -1) {
      throw Exception('العضو غير موجود.');
    }

    if (community.members[memberIndex].isOwner) {
      throw Exception('لا يمكن تغيير حالة منشئ المجتمع.');
    }

    community.members[memberIndex].status = status;
    await _save(communities);
  }

  Future<void> renameCommunity({
    required String communityId,
    required String ownerId,
    required String newName,
  }) async {
    final cleanName = newName.trim();

    if (cleanName.isEmpty) {
      throw ArgumentError('أدخل اسمًا جديدًا.');
    }

    final communities = await getCommunities();
    final index = communities.indexWhere((c) => c.id == communityId);

    if (index == -1) {
      throw Exception('المجتمع غير موجود.');
    }

    if (communities[index].ownerId != ownerId) {
      throw Exception('فقط منشئ المجتمع يمكنه تغيير اسمه.');
    }

    communities[index].name = cleanName;
    await _save(communities);
  }

  Future<void> renameMember({
    required String communityId,
    required String ownerId,
    required String memberId,
    required String newName,
  }) async {
    final cleanName = newName.trim();

    if (cleanName.isEmpty) {
      throw ArgumentError('أدخل اسمًا جديدًا للعضو.');
    }

    final communities = await getCommunities();
    final index = communities.indexWhere((c) => c.id == communityId);

    if (index == -1) {
      throw Exception('المجتمع غير موجود.');
    }

    final community = communities[index];

    if (community.ownerId != ownerId) {
      throw Exception('فقط منشئ المجتمع يمكنه تغيير أسماء الأعضاء.');
    }

    final memberIndex = community.members.indexWhere(
      (m) => m.id == memberId,
    );

    if (memberIndex == -1) {
      throw Exception('العضو غير موجود.');
    }

    community.members[memberIndex].name = cleanName;
    await _save(communities);
  }
}