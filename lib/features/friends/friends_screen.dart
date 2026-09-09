import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/friend_service.dart';
import '../../core/services/game_service.dart';
import '../../core/theme.dart';

class FriendsScreen extends ConsumerStatefulWidget {
  final String? gameId;
  const FriendsScreen({super.key, this.gameId});

  @override
  ConsumerState<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends ConsumerState<FriendsScreen> {
  final _emailCtrl = TextEditingController();
  bool _sending = false;

  late final String _uid;
  late final String _name;
  late final String? _photo;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser!;
    _uid = user.uid;
    _name = user.displayName ?? 'Player';
    _photo = user.photoURL;
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = ref.read(friendServiceProvider);
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.maroon, AppColors.maroonDeep],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildAppBar(),
              _buildAddFriend(svc),
              Expanded(
                child: DefaultTabController(
                  length: 2,
                  child: Column(
                    children: [
                      const TabBar(
                        indicatorColor: AppColors.gold,
                        labelColor: AppColors.gold,
                        unselectedLabelColor: AppColors.silver,
                        tabs: [
                          Tab(text: 'Friends'),
                          Tab(text: 'Requests'),
                        ],
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            _buildFriendsList(svc),
                            _buildRequestsList(svc),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: AppColors.gold),
            onPressed: () => context.go('/'),
          ),
          Text('Friends', style: Theme.of(context).textTheme.headlineSmall),
        ],
      ),
    );
  }

  Widget _buildAddFriend(FriendService svc) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _emailCtrl,
              decoration: const InputDecoration(
                hintText: 'Add friend by email',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              keyboardType: TextInputType.emailAddress,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: _sending
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gold),
                  )
                : const Icon(Icons.person_add, color: AppColors.gold),
            onPressed: _sending ? null : () => _sendRequest(svc),
          ),
        ],
      ),
    );
  }

  Widget _buildFriendsList(FriendService svc) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: svc.friendsStream(_uid),
      builder: (context, snap) {
        final friends = snap.data ?? [];
        if (friends.isEmpty) {
          return const Center(
            child: Text('No friends yet.\nAdd someone by email above!',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.silver)),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: friends.length,
          itemBuilder: (context, i) {
            final f = friends[i];
            return _FriendTile(
              name: f['displayName'] ?? 'Player',
              photoUrl: f['photoUrl'] as String?,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.gameId != null)
                    IconButton(
                      icon: const Icon(Icons.mail_outline, color: AppColors.gold, size: 20),
                      tooltip: 'Invite to game',
                      onPressed: () => _inviteToGame(svc, f['uid']),
                    ),
                  IconButton(
                    icon: const Icon(Icons.person_remove, color: AppColors.silver, size: 20),
                    tooltip: 'Remove',
                    onPressed: () => svc.removeFriend(_uid, f['uid']),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildRequestsList(FriendService svc) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: svc.requestsStream(_uid),
      builder: (context, snap) {
        final requests = snap.data ?? [];
        if (requests.isEmpty) {
          return const Center(
            child: Text('No pending requests',
                style: TextStyle(color: AppColors.silver)),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: requests.length,
          itemBuilder: (context, i) {
            final r = requests[i];
            return _FriendTile(
              name: r['displayName'] ?? 'Player',
              photoUrl: r['photoUrl'] as String?,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.check_circle, color: AppColors.success, size: 24),
                    onPressed: () => svc.acceptRequest(
                      _uid, _name, _photo,
                      r['uid'], r['displayName'] ?? 'Player', r['photoUrl'] as String?,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.cancel, color: AppColors.error, size: 24),
                    onPressed: () => svc.declineRequest(_uid, r['uid']),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _sendRequest(FriendService svc) async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) return;
    setState(() => _sending = true);
    try {
      await svc.sendRequest(_uid, _name, _photo, email);
      _emailCtrl.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Friend request sent!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _inviteToGame(FriendService svc, String friendUid) async {
    try {
      final gameSvc = ref.read(gameServiceProvider);
      final gameSnap = await gameSvc.gameStream(widget.gameId!).first;
      await svc.inviteToGame(friendUid, _name, widget.gameId!, gameSnap.roomCode);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invite sent!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }
}

class _FriendTile extends StatelessWidget {
  final String name;
  final String? photoUrl;
  final Widget trailing;

  const _FriendTile({
    required this.name,
    this.photoUrl,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.maroonDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.burgundy),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.burgundy,
            backgroundImage: photoUrl != null ? NetworkImage(photoUrl!) : null,
            child: photoUrl == null
                ? Text(name[0].toUpperCase(),
                    style: const TextStyle(color: AppColors.gold))
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(name,
                style: const TextStyle(color: AppColors.ivory, fontSize: 14)),
          ),
          trailing,
        ],
      ),
    );
  }
}
