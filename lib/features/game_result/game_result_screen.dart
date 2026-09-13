import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/game_state.dart';
import '../../core/models/playing_card.dart';
import '../../core/services/audio_service.dart';
import '../../core/services/game_service.dart';
import '../../core/theme.dart';
import '../../core/utils/card_rules.dart' show sortHandForDisplay;
import '../../shared_widgets/playing_card_widget.dart';
import '../../shared_widgets/result_overlays.dart';

class GameResultScreen extends ConsumerStatefulWidget {
  final String gameId;
  const GameResultScreen({super.key, required this.gameId});

  @override
  ConsumerState<GameResultScreen> createState() => _GameResultScreenState();
}

class _GameResultScreenState extends ConsumerState<GameResultScreen> {
  late final String _uid;
  late final Stream<GameState> _gameStream;
  bool _confirmed = false;
  bool _soundPlayed = false;
  bool _handsPublished = false;

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser!.uid;
    _gameStream = ref.read(gameServiceProvider).gameStream(widget.gameId);
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
        child: StreamBuilder<GameState>(
          stream: _gameStream,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(
                child: CircularProgressIndicator(color: AppColors.gold),
              );
            }
            final game = snap.data!;

            if (game.status == GameStatus.inProgress) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) context.go('/game/${widget.gameId}');
              });
            }

            final mySeat = game.seatForUid(_uid);
            final myTeam = mySeat != null
                ? GameState.teamForSeat(mySeat.seat)
                : null;
            final isWinner = myTeam == game.winningTeam;

            if (!_handsPublished && game.status == GameStatus.completed) {
              _handsPublished = true;
              ref
                  .read(gameServiceProvider)
                  .publishFinalHands(widget.gameId, _uid);
            }

            if (!_soundPlayed && game.status == GameStatus.completed) {
              _soundPlayed = true;
              if (isWinner) {
                AudioService.instance.play(GameSound.victory);
                HapticService.heavy();
              } else {
                AudioService.instance.play(GameSound.defeat);
              }
            }
            final isHost = game.hostId == _uid;
            final confirmedCount = game.players.where((p) => p.ready).length;

            return SafeArea(
              child: Stack(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 16),
                        Text(
                              isWinner
                                  ? switch (game.victoryType) {
                                      VictoryType.court => '👑 Court Victory!',
                                      VictoryType.poopy => '💥 Poopy Victory!',
                                      _ => '🏆 Victory!',
                                    }
                                  : game.victoryType == VictoryType.poopy
                                  ? '💩 Poopy Defeat!'
                                  : '😞 Defeat!',
                              style: Theme.of(context).textTheme.headlineLarge,
                              textAlign: TextAlign.center,
                            )
                            .animate()
                            .fadeIn(duration: 400.ms)
                            .scale(
                              begin: const Offset(0.5, 0.5),
                              end: const Offset(1, 1),
                              duration: 500.ms,
                              curve: Curves.elasticOut,
                            ),
                        const SizedBox(height: 16),
                        Text(
                          '${game.winningTeam?.replaceAll("team", "Team ")} Wins!',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: game.winningTeam == 'teamA'
                                ? AppColors.teamA
                                : AppColors.teamB,
                          ),
                        ).animate().fadeIn(delay: 200.ms),
                        if (isWinner)
                          const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text(
                                  '🎉 You Won!',
                                  style: TextStyle(
                                    color: AppColors.gold,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              )
                              .animate()
                              .fadeIn(delay: 400.ms)
                              .shimmer(
                                duration: 800.ms,
                                color: AppColors.gold.withValues(alpha: 0.3),
                              ),
                        if (game.endReason != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            game.endReason!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppColors.ivory,
                              fontSize: 14,
                              height: 1.4,
                            ),
                          ).animate().fadeIn(delay: 300.ms),
                        ],
                        const SizedBox(height: 32),
                        _buildBreakdown(game)
                            .animate()
                            .fadeIn(delay: 300.ms)
                            .slideY(begin: 0.2, end: 0),
                        const SizedBox(height: 32),
                        _buildTensDisplay(game),
                        const SizedBox(height: 24),
                        _buildFinalHands(game),
                        const SizedBox(height: 24),
                        Text(
                          '$confirmedCount/4 ready for next game',
                          style: const TextStyle(
                            color: AppColors.silver,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (int seat = 1; seat <= 4; seat++)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: _buildConfirmChip(game, seat),
                              ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            OutlinedButton(
                              onPressed: () => context.go('/'),
                              child: const Text('Leave'),
                            ),
                            const SizedBox(width: 16),
                            ElevatedButton(
                              onPressed: _confirmed
                                  ? null
                                  : () => _confirm(game),
                              child: Text(
                                _confirmed ? 'Waiting...' : 'Play Again',
                              ),
                            ),
                          ],
                        ),
                        if (isHost && game.allReady) ...[
                          const SizedBox(height: 12),
                          ElevatedButton(
                            onPressed: _startNext,
                            child: const Text('Start Next Game'),
                          ),
                        ],
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                  // Overlays paint above the content; they ignore touches.
                  if (isWinner) const ConfettiOverlay(),
                  if (!isWinner && game.victoryType == VictoryType.poopy)
                    const PoopOverlay(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildBreakdown(GameState game) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _row('Trump', game.trumpSuit?.symbol ?? 'Never set'),
            _row(
              'Trump Team',
              game.trumpTeam?.replaceAll('team', 'Team ') ?? '—',
            ),
            _row(
              'Tricks',
              'A: ${game.trickPileA.trickCount}  B: ${game.trickPileB.trickCount}',
            ),
            _row(
              'Tens',
              'A: ${game.collectedTens.tensForTeam("teamA")}  '
                  'B: ${game.collectedTens.tensForTeam("teamB")}',
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppColors.silver)),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.gold,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTensDisplay(GameState game) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final suit in Suit.values) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: AppColors.maroonDark,
              border: Border.all(color: AppColors.burgundy),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '10${suit.symbol}',
                  style: TextStyle(
                    fontSize: 16,
                    color: (suit == Suit.hearts || suit == Suit.diamonds)
                        ? AppColors.suitRed
                        : AppColors.ivory,
                  ),
                ),
                () {
                  final team = game.collectedTens.tens['10${suit.letter}'];
                  return Text(
                    team?.replaceAll('team', '') ?? '?',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: team == 'teamA'
                          ? AppColors.teamA
                          : team == 'teamB'
                          ? AppColors.teamB
                          : AppColors.silver,
                    ),
                  );
                }(),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Every player's dealt hand, with the cards they actually played dimmed —
  /// what was left when the game ended stays bright.
  Widget _buildFinalHands(GameState game) {
    if (game.finalHands.isEmpty) return const SizedBox.shrink();
    final played = {
      ...game.trickPileA.cards,
      ...game.trickPileB.cards,
      ...?game.currentTrick?.plays.map((p) => p.card.id),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Hands',
              style: TextStyle(
                color: AppColors.silver,
                fontSize: 12,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 4),
            for (int seat = 1; seat <= 4; seat++)
              if (game.seats[seat] != null)
                _handRow(game, seat, game.finalHands[seat] ?? const [], played),
          ],
        ),
      ),
    );
  }

  Widget _handRow(
    GameState game,
    int seat,
    List<String> dealt,
    Set<String> played,
  ) {
    final player = game.seats[seat]!;
    final team = GameState.teamForSeat(seat);
    final cards = sortHandForDisplay(dealt.map(PlayingCard.fromId).toList());

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            player.displayName,
            style: TextStyle(
              color: team == 'teamA' ? AppColors.teamA : AppColors.teamB,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          if (cards.isEmpty)
            const Text('—', style: TextStyle(color: AppColors.silver))
          else
            Wrap(
              spacing: 2,
              runSpacing: 2,
              children: [
                for (final c in cards)
                  Opacity(
                    opacity: played.contains(c.id) ? 0.28 : 1,
                    child: PlayingCardWidget(card: c, width: 22),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildConfirmChip(GameState game, int seat) {
    final player = game.seats[seat];
    if (player == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          player.ready ? Icons.check_circle : Icons.circle_outlined,
          color: player.ready ? AppColors.success : AppColors.silver,
          size: 24,
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (player.isBot)
              const Icon(Icons.smart_toy, color: AppColors.silver, size: 10),
            Text(
              player.displayName.split(' ').first,
              style: const TextStyle(color: AppColors.silver, fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ],
    );
  }

  int? _mySeat;

  Future<void> _confirm(GameState game) async {
    final seat = _mySeat ??= game.seatForUid(_uid)?.seat;
    if (seat == null) return;
    setState(() => _confirmed = true);
    try {
      await ref
          .read(gameServiceProvider)
          .confirmNextGame(widget.gameId, _uid, seat: seat);
    } catch (e) {
      if (mounted) {
        setState(() => _confirmed = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _startNext() async {
    try {
      await ref.read(gameServiceProvider).startNextGame(widget.gameId, _uid);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }
}
