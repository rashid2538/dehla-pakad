class UserProfile {
  final String uid;
  final String email;
  final String displayName;
  final String? photoUrl;

  const UserProfile({
    required this.uid,
    required this.email,
    required this.displayName,
    this.photoUrl,
  });

  Map<String, dynamic> toFirestore() => {
        'email': email,
        'displayName': displayName,
        'photoUrl': photoUrl,
      };

  factory UserProfile.fromFirestore(Map<String, dynamic> m, String uid) =>
      UserProfile(
        uid: uid,
        email: m['email'] as String? ?? '',
        displayName: m['displayName'] as String? ?? 'Player',
        photoUrl: m['photoUrl'] as String?,
      );
}
