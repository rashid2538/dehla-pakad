import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final friendServiceProvider = Provider((ref) => FriendService());

class FriendService {
  final _firestore = FirebaseFirestore.instance;

  Stream<List<Map<String, dynamic>>> friendsStream(String uid) => _firestore
      .collection('users/$uid/friends')
      .snapshots()
      .map((s) => s.docs.map((d) => {'uid': d.id, ...d.data()}).toList());

  Stream<List<Map<String, dynamic>>> requestsStream(String uid) => _firestore
      .collection('users/$uid/friendRequests')
      .snapshots()
      .map((s) => s.docs.map((d) => {'uid': d.id, ...d.data()}).toList());

  Stream<List<Map<String, dynamic>>> gameInvitesStream(String uid) => _firestore
      .collection('users/$uid/gameInvites')
      .snapshots()
      .map((s) => s.docs.map((d) => {'id': d.id, ...d.data()}).toList());

  Future<void> sendRequest(String myUid, String myName, String? myPhoto, String friendEmail) async {
    final query = await _firestore
        .collection('users')
        .where('email', isEqualTo: friendEmail.trim().toLowerCase())
        .limit(1)
        .get();
    if (query.docs.isEmpty) throw Exception('No user found with that email');

    final friendDoc = query.docs.first;
    final friendUid = friendDoc.id;
    if (friendUid == myUid) throw Exception("Can't add yourself");

    final existing = await _firestore.doc('users/$myUid/friends/$friendUid').get();
    if (existing.exists) throw Exception('Already friends');

    final pendingCheck = await _firestore.doc('users/$friendUid/friendRequests/$myUid').get();
    if (pendingCheck.exists) throw Exception('Request already sent');

    await _firestore.doc('users/$friendUid/friendRequests/$myUid').set({
      'displayName': myName,
      'photoUrl': myPhoto,
      'sentAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> acceptRequest(String myUid, String myName, String? myPhoto, String friendUid, String friendName, String? friendPhoto) async {
    final batch = _firestore.batch();
    batch.set(_firestore.doc('users/$myUid/friends/$friendUid'), {
      'displayName': friendName,
      'photoUrl': friendPhoto,
      'addedAt': FieldValue.serverTimestamp(),
    });
    batch.set(_firestore.doc('users/$friendUid/friends/$myUid'), {
      'displayName': myName,
      'photoUrl': myPhoto,
      'addedAt': FieldValue.serverTimestamp(),
    });
    batch.delete(_firestore.doc('users/$myUid/friendRequests/$friendUid'));
    await batch.commit();
  }

  Future<void> declineRequest(String myUid, String friendUid) async {
    await _firestore.doc('users/$myUid/friendRequests/$friendUid').delete();
  }

  Future<void> removeFriend(String myUid, String friendUid) async {
    final batch = _firestore.batch();
    batch.delete(_firestore.doc('users/$myUid/friends/$friendUid'));
    batch.delete(_firestore.doc('users/$friendUid/friends/$myUid'));
    await batch.commit();
  }

  Future<void> inviteToGame(String friendUid, String senderName, String gameId, String roomCode) async {
    await _firestore.doc('users/$friendUid/gameInvites/$gameId').set({
      'senderName': senderName,
      'roomCode': roomCode,
      'gameId': gameId,
      'sentAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> dismissInvite(String uid, String inviteId) async {
    await _firestore.doc('users/$uid/gameInvites/$inviteId').delete();
  }
}
