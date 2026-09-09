import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

final authServiceProvider = Provider((ref) => AuthService());

class AuthService {
  final _auth = FirebaseAuth.instance;
  final _firestore = FirebaseFirestore.instance;
  bool _googleInitialized = false;

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<UserCredential> signInWithGoogle() async {
    final UserCredential result;

    if (kIsWeb) {
      final provider = GoogleAuthProvider();
      result = await _auth.signInWithPopup(provider);
    } else {
      await _ensureGoogleInitialized();
      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      final credential = GoogleAuthProvider.credential(idToken: idToken);
      result = await _auth.signInWithCredential(credential);
    }

    final user = result.user!;
    await _firestore.doc('users/${user.uid}').set({
      'email': user.email,
      'displayName': user.displayName ?? 'Player',
      'photoUrl': user.photoURL,
      'lastLoginAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    return result;
  }

  Future<void> updateDisplayName(String name) async {
    final user = _auth.currentUser;
    if (user == null) return;
    await user.updateDisplayName(name);
    await user.reload();
    await _firestore.doc('users/${user.uid}').update({
      'displayName': name,
    });
  }

  Future<void> signOut() async {
    if (!kIsWeb) {
      await _ensureGoogleInitialized();
      await GoogleSignIn.instance.signOut();
    }
    await _auth.signOut();
  }

  Future<void> _ensureGoogleInitialized() async {
    if (_googleInitialized) return;
    await GoogleSignIn.instance.initialize();
    _googleInitialized = true;
  }
}
