import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/game_state.dart';
import '../../core/models/player.dart';
import '../../core/services/audio_service.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/game_service.dart';
import '../../core/theme.dart';
import '../../shared_widgets/team_stats_dialog.dart';

class LobbyScreen extends ConsumerStatefulWidget {
  final String gameId;
  const LobbyScreen({super.key, required this.gameId});

  @override
  ConsumerState<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends ConsumerState<LobbyScreen> {
  late final String _uid;
  late final Stream<GameState> _gameStream;
  GameState? _prevGame;
  int? _selectedSwapSeat;

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser!.uid;
    _gameStream = ref.read(gameServiceProvider).gameStream(widget.gameId);
  }

  void _handleLobbyUpdate(GameState game) {
    final prev = _prevGame;
    _prevGame = game;
    if (prev == null) return;

    if (game.playerCount > prev.playerCount) {
      AudioService.instance.play(GameSound.playerJoin);
      HapticService.light();
    } else if (game.playerCount < prev.playerCount) {
      AudioService.instance.play(GameSound.playerLeave);
    }

    if (prev.status == GameStatus.lobby &&
        game.status == GameStatus.inProgress) {
      AudioService.instance.play(GameSound.gameStart);
      HapticService.medium();
    }
  }

  void _showBotDifficultyPicker(GameState game) {
    final openSeat = [1, 2, 3, 4].cast<int?>().firstWhere(
          (s) => game.seats[s!] == null,
          orElse: () => null,
        );
    if (openSeat == null) return;
    final usedNames = game.players.map((p) => p.displayName).toSet();

    showModalBottomSheet<BotDifficulty>(
      context: context,
      backgroundColor: AppColors.maroonDeep,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Bot Difficulty',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            for (final d in BotDifficulty.values)
              ListTile(
                leading: Icon(
                  d == BotDifficulty.easy
                      ? Icons.sentiment_satisfied
                      : d == BotDifficulty.medium
                          ? Icons.psychology
                          : Icons.local_fire_department,
                  color: AppColors.gold,
                ),
                title: Text(d.name[0].toUpperCase() + d.name.substring(1)),
                subtitle: Text(
                  d == BotDifficulty.easy
                      ? 'Plays randomly, friendly for beginners'
                      : d == BotDifficulty.medium
                          ? 'Solid strategy, avoids blunders'
                          : 'Tracks voids, conserves trump',
                ),
                onTap: () => Navigator.pop(ctx, d),
              ),
          ],
        ),
      ),
    ).then((difficulty) {
      if (difficulty != null) {
        ref.read(gameServiceProvider).addBot(
              widget.gameId,
              _uid,
              seat: openSeat,
              usedNames: usedNames,
              difficulty: difficulty,
            );
      }
    });
  }

  void _showTeamStatsDialog(GameState game) {
    showDialog(
      context: context,
      builder: (_) => TeamStatsDialog(game: game),
    );
  }

  void _showNameEditDialog(GameState game) {
    final myPlayer = game.seatForUid(_uid);
    if (myPlayer == null) return;
    final controller = TextEditingController(text: myPlayer.displayName);
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
              if (name.isNotEmpty && name != myPlayer.displayName) {
                await ref
                    .read(authServiceProvider)
                    .updateDisplayName(name);
                await ref
                    .read(gameServiceProvider)
                    .updatePlayerName(widget.gameId, _uid, name);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child:
                const Text('Save', style: TextStyle(color: AppColors.gold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
          child: StreamBuilder<GameState>(
            stream: _gameStream,
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(
                  child: Text('Error: ${snap.error}',
                      style: const TextStyle(color: AppColors.ivory)),
                );
              }
              if (!snap.hasData) {
                return const Center(
                  child: CircularProgressIndicator(color: AppColors.gold),
                );
              }

              final game = snap.data!;
              _handleLobbyUpdate(game);

              // Auto-navigate when game starts
              if (game.status == GameStatus.inProgress ||
                  game.status == GameStatus.dealing) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (context.mounted) context.go('/game/${widget.gameId}');
                });
              }

              final myPlayer = game.seatForUid(_uid);
              final isHost = game.hostId == _uid;

              return Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back,
                              color: AppColors.gold),
                          onPressed: () async {
                            final leave = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                backgroundColor: AppColors.maroonDark,
                                title: const Text('Leave Room?',
                                    style: TextStyle(color: AppColors.gold)),
                                content: const Text(
                                  'You will be removed from this room.',
                                  style: TextStyle(color: AppColors.ivory),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('Stay',
                                        style:
                                            TextStyle(color: AppColors.silver)),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('Leave',
                                        style:
                                            TextStyle(color: AppColors.error)),
                                  ),
                                ],
                              ),
                            );
                            if (leave == true && context.mounted) {
                              await ref
                                  .read(gameServiceProvider)
                                  .leaveRoom(widget.gameId, _uid);
                              if (context.mounted) context.go('/');
                            }
                          },
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.emoji_events,
                              color: AppColors.gold),
                          tooltip: 'Room stats',
                          onPressed: () => _showTeamStatsDialog(game),
                        ),
                      ],
                    ),
                    _RoomCodeBar(roomCode: game.roomCode),
                    const SizedBox(height: 8),
                    Text(
                      '${game.playerCount}/4 Players',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const Spacer(),
                    _SeatTable(
                      game: game,
                      currentUid: _uid,
                      isHost: isHost,
                      selectedSwapSeat: _selectedSwapSeat,
                      onKick: (seat) => ref
                          .read(gameServiceProvider)
                          .kickPlayer(widget.gameId, _uid, seat),
                      onNameEdit: () => _showNameEditDialog(game),
                      onSeatTap: !isHost ? null : (seat) {
                        if (_selectedSwapSeat == null) {
                          setState(() => _selectedSwapSeat = seat);
                        } else if (_selectedSwapSeat == seat) {
                          setState(() => _selectedSwapSeat = null);
                        } else {
                          ref.read(gameServiceProvider).swapSeats(
                            widget.gameId, _uid, _selectedSwapSeat!, seat,
                          );
                          setState(() => _selectedSwapSeat = null);
                        }
                      },
                    ),
                    const Spacer(),
                    _BottomControls(
                      game: game,
                      uid: _uid,
                      isHost: isHost,
                      myPlayer: myPlayer,
                      onReady: () => ref
                          .read(gameServiceProvider)
                          .toggleReady(widget.gameId, _uid,
                              seat: myPlayer!.seat,
                              currentlyReady: myPlayer.ready),
                      onStart: () => ref
                          .read(gameServiceProvider)
                          .startGame(widget.gameId, _uid),
                      onLeave: () async {
                        await ref
                            .read(gameServiceProvider)
                            .leaveRoom(widget.gameId, _uid);
                        if (context.mounted) context.go('/');
                      },
                      onInviteFriends: () =>
                          context.push('/friends?gameId=${widget.gameId}'),
                      onAddBot: () => _showBotDifficultyPicker(game),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RoomCodeBar extends StatelessWidget {
  final String roomCode;
  const _RoomCodeBar({required this.roomCode});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('ROOM ', style: Theme.of(context).textTheme.bodySmall),
        Text(
          roomCode,
          style: const TextStyle(
            color: AppColors.gold,
            fontSize: 28,
            fontWeight: FontWeight.bold,
            letterSpacing: 6,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.copy, color: AppColors.gold, size: 20),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: roomCode));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Room code copied!'),
                duration: Duration(seconds: 1),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _SeatTable extends StatelessWidget {
  final GameState game;
  final String currentUid;
  final bool isHost;
  final int? selectedSwapSeat;
  final void Function(int seat) onKick;
  final VoidCallback onNameEdit;
  final void Function(int seat)? onSeatTap;

  const _SeatTable({
    required this.game,
    required this.currentUid,
    required this.isHost,
    this.selectedSwapSeat,
    required this.onKick,
    required this.onNameEdit,
    this.onSeatTap,
  });

  @override
  Widget build(BuildContext context) {
    // Compass layout: seat 1=N(top), 2=E(right), 3=S(bottom), 4=W(left)
    const seatLabels = {1: 'N', 2: 'E', 3: 'S', 4: 'W'};

    return SizedBox(
      width: 280,
      height: 280,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Center table
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: AppColors.burgundy.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
            ),
            child: Center(
              child: Text(
                '♠♥\n♦♣',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  color: AppColors.gold.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
          for (final entry in {
            1: (Alignment.topCenter, const EdgeInsets.only(top: 0)),
            2: (Alignment.centerRight, const EdgeInsets.only(right: 0)),
            3: (Alignment.bottomCenter, const EdgeInsets.only(bottom: 0)),
            4: (Alignment.centerLeft, const EdgeInsets.only(left: 0)),
          }.entries)
            Positioned.fill(
              child: Align(
                alignment: entry.value.$1,
                child: _SeatCard(
                  player: game.seats[entry.key],
                  seatNum: entry.key,
                  label: seatLabels[entry.key]!,
                  team: GameState.teamForSeat(entry.key),
                  isMe: game.seats[entry.key]?.uid == currentUid,
                  isHost: isHost,
                  canKick: isHost && game.seats[entry.key]?.uid != currentUid,
                  isSwapSelected: selectedSwapSeat == entry.key,
                  isSwapTarget: selectedSwapSeat != null && selectedSwapSeat != entry.key,
                  onKick: () => onKick(entry.key),
                  onNameEdit: onNameEdit,
                  onSwapTap: onSeatTap != null ? () => onSeatTap!(entry.key) : null,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SeatCard extends StatelessWidget {
  final PlayerSeat? player;
  final int seatNum;
  final String label;
  final String team;
  final bool isMe;
  final bool isHost;
  final bool canKick;
  final bool isSwapSelected;
  final bool isSwapTarget;
  final VoidCallback onKick;
  final VoidCallback onNameEdit;
  final VoidCallback? onSwapTap;

  const _SeatCard({
    required this.player,
    required this.seatNum,
    required this.label,
    required this.team,
    required this.isMe,
    required this.isHost,
    required this.canKick,
    this.isSwapSelected = false,
    this.isSwapTarget = false,
    required this.onKick,
    required this.onNameEdit,
    this.onSwapTap,
  });

  @override
  Widget build(BuildContext context) {
    final teamColor = team == 'teamA' ? AppColors.gold : AppColors.silver;
    final isEmpty = player == null;

    return GestureDetector(
      onTap: onSwapTap,
      child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 90,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      decoration: BoxDecoration(
        color: isSwapSelected
            ? AppColors.gold.withValues(alpha: 0.2)
            : isEmpty
                ? AppColors.maroonDark.withValues(alpha: 0.6)
                : AppColors.maroonDark,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSwapSelected
              ? AppColors.gold
              : isSwapTarget
                  ? AppColors.gold.withValues(alpha: 0.5)
                  : isMe
                      ? AppColors.gold
                      : isEmpty
                          ? AppColors.burgundy.withValues(alpha: 0.5)
                          : teamColor.withValues(alpha: 0.6),
          width: isSwapSelected || isMe ? 2 : 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isEmpty) ...[
            Icon(Icons.person_outline,
                color: AppColors.burgundy.withValues(alpha: 0.5), size: 28),
            Text(label,
                style: TextStyle(
                    color: AppColors.burgundy.withValues(alpha: 0.5),
                    fontSize: 10)),
          ] else ...[
            Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: teamColor.withValues(alpha: 0.3),
                  backgroundImage:
                      player!.photoUrl != null && !player!.isBot
                          ? NetworkImage(player!.photoUrl!)
                          : null,
                  child: player!.isBot
                      ? Icon(Icons.smart_toy, color: teamColor, size: 18)
                      : player!.photoUrl == null
                          ? Text(
                              player!.displayName[0].toUpperCase(),
                              style:
                                  TextStyle(color: teamColor, fontSize: 14),
                            )
                          : null,
                ),
                if (player!.ready)
                  const Positioned(
                    right: -4,
                    bottom: -2,
                    child: Icon(Icons.check_circle,
                        color: AppColors.gold, size: 14),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            GestureDetector(
              onTap: isMe && !player!.isBot ? onNameEdit : null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      player!.displayName,
                      style: TextStyle(color: teamColor, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  if (isMe && !player!.isBot)
                    Icon(Icons.edit, color: teamColor, size: 10),
                ],
              ),
            ),
            if (player!.isBot && player!.botDifficulty != null)
              Text(
                player!.botDifficulty!.name.toUpperCase(),
                style: TextStyle(
                  color: teamColor.withValues(alpha: 0.6),
                  fontSize: 8,
                  letterSpacing: 1,
                ),
              ),
            if (canKick && player != null)
              GestureDetector(
                onTap: onKick,
                child: const Icon(Icons.close,
                    color: AppColors.error, size: 14),
              ),
          ],
          if (isSwapSelected)
            const Icon(Icons.swap_horiz, color: AppColors.gold, size: 16),
        ],
      ),
    ));
  }
}

class _BottomControls extends StatelessWidget {
  final GameState game;
  final String uid;
  final bool isHost;
  final PlayerSeat? myPlayer;
  final VoidCallback onReady;
  final VoidCallback onStart;
  final VoidCallback onLeave;
  final VoidCallback onInviteFriends;
  final VoidCallback onAddBot;

  const _BottomControls({
    required this.game,
    required this.uid,
    required this.isHost,
    required this.myPlayer,
    required this.onReady,
    required this.onStart,
    required this.onLeave,
    required this.onInviteFriends,
    required this.onAddBot,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (myPlayer != null) ...[
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onReady,
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    myPlayer!.ready ? AppColors.burgundy : AppColors.gold,
                foregroundColor:
                    myPlayer!.ready ? AppColors.ivory : AppColors.maroonDeep,
              ),
              child: Text(myPlayer!.ready ? 'Not Ready' : 'Ready'),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (isHost && game.allReady) ...[
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onStart,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start Game'),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (game.playerCount < 4) ...[
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onInviteFriends,
                  icon: const Icon(Icons.person_add),
                  label: const Text('Invite'),
                ),
              ),
              if (isHost) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onAddBot,
                    icon: const Icon(Icons.smart_toy),
                    label: const Text('Add Bot'),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
        ],
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: onLeave,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.silver,
              side: const BorderSide(color: AppColors.burgundy),
            ),
            child: const Text('Leave Room'),
          ),
        ),
      ],
    );
  }
}
