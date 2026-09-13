import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/game_session.dart';
import '../../core/models/game_state.dart';
import '../../core/models/playing_card.dart';
import '../../core/services/audio_service.dart';
import '../../core/theme.dart';
import '../../core/utils/card_rules.dart' show sortHandForDisplay;
import '../../shared_widgets/playing_card_widget.dart';
import '../../shared_widgets/result_overlays.dart';

/// Result screen for local (vs bots) games.
/// Mirrors GameResultScreen but works with a [GameSession] instead of Firestore.
class LocalResultScreen extends StatefulWidget {
  final GameSession session;
  const LocalResultScreen({super.key, required this.session});

  @override
  State<LocalResultScreen> createState() => _LocalResultScreenState();
}

class _LocalResultScreenState extends State<LocalResultScreen> {
  late final GameSession _session;
  bool _confirmed = false;
  bool _soundPlayed = false;
  bool _handsPublished = false;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
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
          stream: _session.gameStream,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(
                child: CircularProgressIndicator(color: AppColors.gold),
              );
            }
            final game = snap.data!;

            if (game.status == GameStatus.inProgress) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) context.go('/local/play');
              });
            }

            final mySeat = _session.mySeat;
            final myTeam = mySeat != null
                ? GameState.teamForSeat(mySeat)
                : null;
            final isWinner = myTeam == game.winningTeam;

            if (!_soundPlayed && game.status == GameStatus.completed) {
              _soundPlayed = true;
              if (isWinner) {
                AudioService.instance.play(GameSound.victory);
                HapticService.heavy();
              } else {
                AudioService.instance.play(GameSound.defeat);
              }
            }

            // Once only: publishing emits a new state, so calling it on every
            // build looped forever and kept restarting the result animations.
            if (!_handsPublished && game.status == GameStatus.completed) {
              _handsPublished = true;
              _session.publishFinalHands(_session.myUid);
            }

            final confirmedCount = game.players.where((p) => p.ready).length;

            return SafeArea(
              child: Stack(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 8),
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
                        const SizedBox(height: 8),
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
                                padding: EdgeInsets.only(top: 4),
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
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.maroonDark.withValues(
                                alpha: 0.6,
                              ),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: AppColors.burgundy.withValues(
                                  alpha: 0.4,
                                ),
                              ),
                            ),
                            child: Text(
                              game.endReason!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: AppColors.ivory,
                                fontSize: 13,
                                height: 1.4,
                              ),
                            ),
                          ).animate().fadeIn(delay: 300.ms),
                        ],
                        const SizedBox(height: 16),
                        // ── Breakdown + Tens in a compact card ──
                        _buildBreakdownCard(game)
                            .animate()
                            .fadeIn(delay: 300.ms)
                            .slideY(begin: 0.2, end: 0),
                        const SizedBox(height: 12),
                        // ── Final hands ──
                        _buildFinalHands(game),
                        const SizedBox(height: 12),
                        // ── Confirm status + chips ──
                        _buildConfirmSection(game, confirmedCount),
                        const SizedBox(height: 16),
                        // ── Action buttons (bigger touch targets) ──
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () {
                                  _session.dispose();
                                  context.go('/');
                                },
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                ),
                                child: const Text('Leave'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: _confirmed
                                    ? null
                                    : () => _confirm(game),
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                ),
                                child: Text(
                                  _confirmed ? 'Waiting...' : 'Play Again',
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (game.allReady) ...[
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: () => _startNext(),
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                backgroundColor: AppColors.success,
                              ),
                              child: const Text('Start Next Game'),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
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

  // ── §4.2 Dense breakdown card: stats + ten tracker combined ──

  Widget _buildBreakdownCard(GameState game) {
    final teamA = game.collectedTens.tensForTeam('teamA');
    final teamB = game.collectedTens.tensForTeam('teamB');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // Stats row
            Row(
              children: [
                _StatChip(
                  icon: Icons.card_travel,
                  label: game.trumpSuit?.symbol ?? '—',
                  sublabel:
                      game.trumpTeam?.replaceAll('team', 'Team ') ?? 'No trump',
                ),
                const SizedBox(width: 8),
                _StatChip(
                  icon: Icons.style,
                  label:
                      '${game.trickPileA.trickCount}–${game.trickPileB.trickCount}',
                  sublabel: 'Tricks',
                ),
                const SizedBox(width: 8),
                _StatChip(
                  icon: Icons.star,
                  label: '$teamA–$teamB',
                  sublabel: 'Tens',
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Ten tracker strip
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final suit in Suit.values) ...[
                  if (suit != Suit.values.first) const SizedBox(width: 6),
                  _ResultTenIcon(suit: suit, collectedTens: game.collectedTens),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── §4.2 Dense final hands: bigger thumbnails, team grouping ──

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
              'HANDS',
              style: TextStyle(
                color: AppColors.silver,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
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
    final teamColor = team == 'teamA' ? AppColors.teamA : AppColors.teamB;
    final cards = sortHandForDisplay(dealt.map(PlayingCard.fromId).toList());

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Player row with avatar + name
          Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: teamColor, width: 1.5),
                ),
                child: CircleAvatar(
                  radius: 8,
                  backgroundColor: teamColor.withValues(alpha: 0.2),
                  child: player.isBot
                      ? Icon(Icons.smart_toy, color: teamColor, size: 10)
                      : Text(
                          player.displayName[0].toUpperCase(),
                          style: TextStyle(color: teamColor, fontSize: 9),
                        ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                player.displayName,
                style: TextStyle(
                  color: teamColor,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (cards.isEmpty)
            const Text(
              '—',
              style: TextStyle(color: AppColors.silver, fontSize: 11),
            )
          else
            Wrap(
              spacing: 2,
              runSpacing: 2,
              children: [
                for (final c in cards)
                  Opacity(
                    opacity: played.contains(c.id) ? 0.28 : 1,
                    child: PlayingCardWidget(card: c, width: 28),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  // ── §4.2 Confirm section with avatar-style chips ──

  Widget _buildConfirmSection(GameState game, int confirmedCount) {
    return Column(
      children: [
        Text(
          '$confirmedCount/4 ready for next game',
          style: const TextStyle(color: AppColors.silver, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (int seat = 1; seat <= 4; seat++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _buildConfirmChip(game, seat),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildConfirmChip(GameState game, int seat) {
    final player = game.seats[seat];
    if (player == null) return const SizedBox.shrink();
    final team = GameState.teamForSeat(seat);
    final teamColor = team == 'teamA' ? AppColors.teamA : AppColors.teamB;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Avatar with ready indicator
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: player.ready
                      ? AppColors.success
                      : teamColor.withValues(alpha: 0.4),
                  width: 2,
                ),
              ),
              child: CircleAvatar(
                radius: 13,
                backgroundColor: teamColor.withValues(alpha: 0.2),
                child: player.isBot
                    ? Icon(Icons.smart_toy, color: teamColor, size: 14)
                    : Text(
                        player.displayName[0].toUpperCase(),
                        style: TextStyle(color: teamColor, fontSize: 12),
                      ),
              ),
            ),
            if (player.ready)
              const Positioned(
                right: -2,
                bottom: -2,
                child: Icon(
                  Icons.check_circle,
                  color: AppColors.success,
                  size: 14,
                ),
              ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          player.displayName.split(' ').first,
          style: const TextStyle(color: AppColors.silver, fontSize: 9),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  void _confirm(GameState game) {
    final seat = _session.mySeat;
    if (seat == null) return;
    setState(() => _confirmed = true);
    _session.confirmNextGame(_session.myUid, seat);
  }

  void _startNext() {
    _session.startNextGame(hostUid: _session.myUid);
  }
}

// ── §4.2 Helper widgets for dense result screen ──

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.sublabel,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.maroonDark.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.burgundy.withValues(alpha: 0.4)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.gold, size: 16),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                color: AppColors.gold,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              sublabel,
              style: TextStyle(
                color: AppColors.silver.withValues(alpha: 0.7),
                fontSize: 9,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultTenIcon extends StatelessWidget {
  final Suit suit;
  final CollectedTens collectedTens;

  const _ResultTenIcon({required this.suit, required this.collectedTens});

  @override
  Widget build(BuildContext context) {
    final team = collectedTens.tens['10${suit.letter}'];
    final isRed = suit == Suit.hearts || suit == Suit.diamonds;
    final collected = team != null;
    final teamColor = team == 'teamA'
        ? AppColors.teamA
        : team == 'teamB'
        ? AppColors.teamB
        : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        color: collected
            ? teamColor!.withValues(alpha: 0.2)
            : AppColors.maroonDark.withValues(alpha: 0.5),
        border: Border.all(
          color: collected
              ? teamColor!.withValues(alpha: 0.6)
              : AppColors.burgundy.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '10${suit.symbol}',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: collected
                  ? (isRed ? AppColors.suitRed : AppColors.ivory)
                  : AppColors.silver.withValues(alpha: 0.4),
            ),
          ),
          Text(
            collected ? (team == 'teamA' ? 'A' : 'B') : '—',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: teamColor ?? AppColors.silver.withValues(alpha: 0.3),
            ),
          ),
        ],
      ),
    );
  }
}
