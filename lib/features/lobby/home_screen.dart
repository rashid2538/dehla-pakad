import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/game_state.dart';
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
                const SizedBox(height: 16),
                Text('Dehla Pakad',
                    style: Theme.of(context).textTheme.headlineLarge),
                const SizedBox(height: 8),
                Text(
                  'Grab all the Tens!',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () => context.push('/create'),
                        icon: const Icon(Icons.add_circle_outline),
                        label: const Text('Create'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => context.push('/join'),
                        icon: const Icon(Icons.login),
                        label: const Text('Join'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => context.push('/friends'),
                    icon: const Icon(Icons.people_outline),
                    label: const Text('Friends'),
                  ),
                ),
                const SizedBox(height: 24),
                if (user != null)
                  Expanded(
                    child: _MyRoomsList(uid: user.uid),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MyRoomsList extends ConsumerWidget {
  final String uid;
  const _MyRoomsList({required this.uid});

  void _navigateToRoom(BuildContext context, GameState game) {
    switch (game.status) {
      case GameStatus.lobby:
        context.push('/lobby/${game.gameId}');
      case GameStatus.inProgress || GameStatus.dealing:
        context.push('/game/${game.gameId}');
      case GameStatus.completed:
        context.push('/result/${game.gameId}');
      default:
        context.push('/lobby/${game.gameId}');
    }
  }

  void _showRenameDialog(
      BuildContext context, WidgetRef ref, GameState game) {
    final controller = TextEditingController(text: game.roomCode);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.maroonDark,
        title:
            const Text('Rename Room', style: TextStyle(color: AppColors.gold)),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          maxLength: 10,
          style: const TextStyle(
            color: AppColors.gold,
            fontSize: 20,
            letterSpacing: 4,
          ),
          decoration: const InputDecoration(
            counterText: '',
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
              final code = controller.text.trim();
              if (code.isNotEmpty && code != game.roomCode) {
                await ref
                    .read(gameServiceProvider)
                    .renameRoom(game.gameId, uid, code);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save', style: TextStyle(color: AppColors.gold)),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(
      BuildContext context, WidgetRef ref, GameState game) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.maroonDark,
        title: const Text('Delete Room?',
            style: TextStyle(color: AppColors.gold)),
        content: Text(
          'Room ${game.roomCode} and all its game data will be permanently deleted.',
          style: const TextStyle(color: AppColors.ivory),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                const Text('Cancel', style: TextStyle(color: AppColors.silver)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await ref
                    .read(gameServiceProvider)
                    .deleteRoom(game.gameId, uid);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
                }
              }
            },
            child:
                const Text('Delete', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('My Rooms', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Expanded(
          child: StreamBuilder<List<GameState>>(
            stream: ref.read(gameServiceProvider).myRoomsStream(uid),
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(
                  child: Text(
                    'Could not load rooms',
                    style: TextStyle(
                        color: AppColors.silver.withValues(alpha: 0.5)),
                  ),
                );
              }
              if (!snap.hasData) {
                return const Center(
                  child: CircularProgressIndicator(color: AppColors.gold),
                );
              }
              final rooms = snap.data!;
              if (rooms.isEmpty) {
                return Center(
                  child: Text(
                    'No rooms yet',
                    style: TextStyle(
                        color: AppColors.silver.withValues(alpha: 0.5)),
                  ),
                );
              }
              return ListView.builder(
                itemCount: rooms.length,
                itemBuilder: (context, i) {
                  final game = rooms[i];
                  final statusLabel = switch (game.status) {
                    GameStatus.lobby => 'Waiting',
                    GameStatus.inProgress || GameStatus.dealing => 'Playing',
                    GameStatus.completed => 'Finished',
                    _ => game.status.name,
                  };
                  final statusColor = switch (game.status) {
                    GameStatus.lobby => AppColors.gold,
                    GameStatus.inProgress || GameStatus.dealing =>
                      Colors.green,
                    GameStatus.completed => AppColors.silver,
                    _ => AppColors.silver,
                  };
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: AppColors.maroonDark,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppColors.burgundy.withValues(alpha: 0.6),
                      ),
                    ),
                    child: ListTile(
                      onTap: () => _navigateToRoom(context, game),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12),
                      title: Text(
                        game.roomCode,
                        style: const TextStyle(
                          color: AppColors.gold,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 3,
                        ),
                      ),
                      subtitle: Text(
                        '${game.playerCount}/4 players',
                        style: TextStyle(
                          color: AppColors.silver.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              statusLabel,
                              style: TextStyle(
                                  color: statusColor, fontSize: 11),
                            ),
                          ),
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert,
                                color: AppColors.silver, size: 20),
                            color: AppColors.maroonDark,
                            onSelected: (v) {
                              if (v == 'rename') {
                                _showRenameDialog(context, ref, game);
                              } else if (v == 'delete') {
                                _confirmDelete(context, ref, game);
                              } else if (v == 'reset') {
                                ref
                                    .read(gameServiceProvider)
                                    .resetToLobby(game.gameId, uid);
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'rename',
                                child: Text('Rename',
                                    style:
                                        TextStyle(color: AppColors.ivory)),
                              ),
                              if (game.status != GameStatus.lobby)
                                const PopupMenuItem(
                                  value: 'reset',
                                  child: Text('Reset to Lobby',
                                      style: TextStyle(
                                          color: AppColors.ivory)),
                                ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete',
                                    style:
                                        TextStyle(color: AppColors.error)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
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
