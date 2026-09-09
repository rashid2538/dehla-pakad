import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/friend_service.dart';
import '../../core/services/game_service.dart';
import '../../core/theme.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String? _nameOverride;

  void _showNameEditDialog(String currentName) {
    final controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.maroonDark,
        title: const Text('Edit Name', style: TextStyle(color: AppColors.gold)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: AppColors.ivory),
          decoration: const InputDecoration(
            hintText: 'Enter your name',
            hintStyle: TextStyle(color: AppColors.silver),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.burgundy),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.gold),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                const Text('Cancel', style: TextStyle(color: AppColors.silver)),
          ),
          TextButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isNotEmpty && name != currentName) {
                await ref.read(authServiceProvider).updateDisplayName(name);
                setState(() => _nameOverride = name);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save', style: TextStyle(color: AppColors.gold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authStateProvider).value;
    final displayName = _nameOverride ?? user?.displayName ?? 'Player';

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
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Row(
                  children: [
                    if (user?.photoURL != null)
                      CircleAvatar(
                        backgroundImage: NetworkImage(user!.photoURL!),
                        radius: 20,
                      )
                    else
                      const CircleAvatar(
                        backgroundColor: AppColors.burgundy,
                        radius: 20,
                        child: Icon(Icons.person, color: AppColors.gold),
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _showNameEditDialog(displayName),
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                displayName,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(Icons.edit,
                                color: AppColors.gold, size: 16),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.logout, color: AppColors.gold),
                      onPressed: () => ref.read(authServiceProvider).signOut(),
                    ),
                  ],
                ),
                if (user != null)
                  _GameInviteBanner(uid: user.uid, displayName: displayName),
                const Spacer(),
                Text(
                  '♠ ♥ ♦ ♣',
                  style: TextStyle(
                    fontSize: 40,
                    color: AppColors.gold.withValues(alpha: 0.3),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Dehla Pakad',
                    style: Theme.of(context).textTheme.headlineLarge),
                const SizedBox(height: 8),
                Text(
                  'Grab all the Tens!',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 48),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => context.push('/create'),
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('Create Room'),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => context.push('/join'),
                    icon: const Icon(Icons.login),
                    label: const Text('Join Room'),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => context.push('/friends'),
                    icon: const Icon(Icons.people_outline),
                    label: const Text('Friends'),
                  ),
                ),
                const Spacer(flex: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GameInviteBanner extends ConsumerWidget {
  final String uid;
  final String displayName;
  const _GameInviteBanner({required this.uid, required this.displayName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: ref.read(friendServiceProvider).gameInvitesStream(uid),
      builder: (context, snap) {
        final invites = snap.data ?? [];
        if (invites.isEmpty) return const SizedBox.shrink();
        return Column(
          children: [
            const SizedBox(height: 12),
            for (final inv in invites)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.gold.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.gold.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.mail, color: AppColors.gold, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${inv['senderName']} invited you to room ${inv['roomCode']}',
                        style: const TextStyle(color: AppColors.ivory, fontSize: 13),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        try {
                          final user = FirebaseAuth.instance.currentUser!;
                          final gameId = await ref.read(gameServiceProvider).joinRoom(
                            inv['roomCode'],
                            user.uid,
                            displayName,
                            photoUrl: user.photoURL,
                          );
                          await ref.read(friendServiceProvider).dismissInvite(uid, inv['id']);
                          if (context.mounted) context.go('/lobby/$gameId');
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('$e')),
                            );
                          }
                        }
                      },
                      child: const Text('Join', style: TextStyle(color: AppColors.gold)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: AppColors.silver, size: 18),
                      onPressed: () => ref.read(friendServiceProvider).dismissInvite(uid, inv['id']),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
