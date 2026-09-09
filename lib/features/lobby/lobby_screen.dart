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
                      onKick: (seat) => ref
                          .read(gameServiceProvider)
                          .kickPlayer(widget.gameId, _uid, seat),
                      onNameEdit: () => _showNameEditDialog(game),
                    ),
                    const Spacer(),
                    _BottomControls(
                      game: game,
                      uid: _uid,
                      isHost: isHost,
                      myPlayer: myPlayer,
                      onReady: () => ref
                          .read(gameServiceProvider)
                          .toggleReady(widget.gameId, _uid),
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
                      onAddBot: () => ref
                          .read(gameServiceProvider)
                          .addBot(widget.gameId, _uid),
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
  final void Function(int seat) onKick;
  final VoidCallback onNameEdit;

  const _SeatTable({
    required this.game,
    required this.currentUid,
    required this.isHost,
    required this.onKick,
    required this.onNameEdit,
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
          // Seat 1 — North (top center)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Center(
              child: _SeatCard(
                player: game.seats[1],
                seatNum: 1,
                label: seatLabels[1]!,
                team: 'teamA',
                isMe: game.seats[1]?.uid == currentUid,
                isHost: isHost,
                canKick: isHost && game.seats[1]?.uid != currentUid,
                onKick: () => onKick(1),
                onNameEdit: onNameEdit,
              ),
            ),
          ),
          // Seat 2 — East (right center)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Center(
              child: _SeatCard(
                player: game.seats[2],
                seatNum: 2,
                label: seatLabels[2]!,
                team: 'teamB',
                isMe: game.seats[2]?.uid == currentUid,
                isHost: isHost,
                canKick: isHost && game.seats[2]?.uid != currentUid,
                onKick: () => onKick(2),
                onNameEdit: onNameEdit,
              ),
            ),
          ),
          // Seat 3 — South (bottom center)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Center(
              child: _SeatCard(
                player: game.seats[3],
                seatNum: 3,
                label: seatLabels[3]!,
                team: 'teamA',
                isMe: game.seats[3]?.uid == currentUid,
                isHost: isHost,
                canKick: isHost && game.seats[3]?.uid != currentUid,
                onKick: () => onKick(3),
                onNameEdit: onNameEdit,
              ),
            ),
          ),
          // Seat 4 — West (left center)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Center(
              child: _SeatCard(
                player: game.seats[4],
                seatNum: 4,
                label: seatLabels[4]!,
                team: 'teamB',
                isMe: game.seats[4]?.uid == currentUid,
                isHost: isHost,
                canKick: isHost && game.seats[4]?.uid != currentUid,
                onKick: () => onKick(4),
                onNameEdit: onNameEdit,
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
  final VoidCallback onKick;
  final VoidCallback onNameEdit;

  const _SeatCard({
    required this.player,
    required this.seatNum,
    required this.label,
    required this.team,
    required this.isMe,
    required this.isHost,
    required this.canKick,
    required this.onKick,
    required this.onNameEdit,
  });

  @override
  Widget build(BuildContext context) {
    final teamColor = team == 'teamA' ? AppColors.gold : AppColors.silver;
    final isEmpty = player == null;

    return Container(
      width: 90,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      decoration: BoxDecoration(
        color: isEmpty
            ? AppColors.maroonDark.withValues(alpha: 0.6)
            : AppColors.maroonDark,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isMe
              ? AppColors.gold
              : isEmpty
                  ? AppColors.burgundy.withValues(alpha: 0.5)
                  : teamColor.withValues(alpha: 0.6),
          width: isMe ? 2 : 1,
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
            if (canKick && player != null)
              GestureDetector(
                onTap: onKick,
                child: const Icon(Icons.close,
                    color: AppColors.error, size: 14),
              ),
          ],
        ],
      ),
    );
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
