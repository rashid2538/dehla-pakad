import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/game_session.dart';
import '../../core/models/game_state.dart';
import '../../core/models/playing_card.dart';
import '../../core/services/audio_service.dart';
import '../../core/services/anti_cheat.dart';
import '../../core/theme.dart';
import '../../core/utils/card_rules.dart'
    show canClaimRemaining, getLegalCards, sortHandForDisplay, unseenCards;
import '../../shared_widgets/playing_card_widget.dart';

/// Shared game table UI that works with any [GameSession] backend.
///
/// Used for both local play vs bots and (eventually) online multiplayer.
class LocalGameTableScreen extends StatefulWidget {
  final GameSession session;
  const LocalGameTableScreen({super.key, required this.session});

  @override
  State<LocalGameTableScreen> createState() => _LocalGameTableScreenState();
}

class _LocalGameTableScreenState extends State<LocalGameTableScreen>
    with WidgetsBindingObserver, AntiCheatMixin {
  late final GameSession _session;
  bool _playing = false;
  bool _resolvingTrick = false;
  int? _claimedTrick;

  GameState? _prevGame;
  bool _showTrumpBanner = false;
  bool _showTrickWin = false;
  int? _trickWinnerSeat;
  bool _showTenCollected = false;
  String? _collectedTenId;
  String? _collectedTenTeam;
  List<TrickPlay>? _lastTrickPlays;
  String? _lastTrickWinnerName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = widget.session;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    onVisibilityChanged(
      state == AppLifecycleState.hidden || state == AppLifecycleState.paused,
    );
  }

  int _relativeSeat(int mySeat, int offset) => ((mySeat - 1 + offset) % 4) + 1;

  void _onCardTap(int mySeat, String cardId) {
    if (_playing) return;
    _showPlayConfirmation(mySeat, cardId);
  }

  void _showPlayConfirmation(int mySeat, String cardId) {
    final card = PlayingCard.fromId(cardId);
    final suitColor = (card.suit == Suit.hearts || card.suit == Suit.diamonds)
        ? AppColors.suitRed
        : AppColors.suitBlack;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.maroonDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.gold, width: 2),
        ),
        title: const Text(
          'Play this card?',
          style: TextStyle(
            color: AppColors.gold,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PlayingCardWidget(card: card, width: 60),
            const SizedBox(width: 16),
            Text(
              '${card.rank.symbol}${card.suit.symbol}',
              style: TextStyle(
                color: suitColor,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.silver, fontSize: 14),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.gold,
              foregroundColor: AppColors.maroonDark,
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              _playCard(mySeat, cardId);
            },
            child: const Text(
              'Play',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _maybeClaimRest(GameState game, List<PlayingCard> hand, int mySeat) {
    if (_claimedTrick == game.trickNumber) return;
    if (game.status != GameStatus.inProgress) return;
    if (game.currentTrick?.plays.isEmpty != true) return;
    if (!canClaimRemaining(
      hand: hand,
      unseen: unseenCards(game, hand),
      trump: game.trumpSuit,
    )) {
      return;
    }
    _claimedTrick = game.trickNumber;
    _session.claimRemaining(mySeat);
  }

  Future<void> _playCard(int mySeat, String cardId) async {
    if (_playing) return;
    setState(() => _playing = true);
    AudioService.instance.play(GameSound.cardPlay);
    HapticService.selection();
    try {
      await _session.playCard(mySeat, cardId);
    } catch (e) {
      AudioService.instance.play(GameSound.error);
      HapticService.medium();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  void _handleGameUpdate(GameState game, int mySeat) {
    final prev = _prevGame;
    _prevGame = game;
    if (prev == null) return;

    // New round started — clear all stale overlay state
    if (prev.status == GameStatus.completed &&
        game.status == GameStatus.inProgress) {
      _lastTrickPlays = null;
      _lastTrickWinnerName = null;
      _showTrickWin = false;
      _showTenCollected = false;
      _showTrumpBanner = false;
    }

    final myTeam = GameState.teamForSeat(mySeat);

    // Remote card played
    final prevPlays = prev.currentTrick?.plays.length ?? 0;
    final nextPlays = game.currentTrick?.plays.length ?? 0;
    if (nextPlays > prevPlays && nextPlays > 0) {
      final lastPlay = game.currentTrick!.plays.last;
      if (lastPlay.seat != mySeat) {
        AudioService.instance.play(GameSound.cardPlay, volume: 0.4);
      }
    }

    // 4th card played
    if (game.status == GameStatus.inProgress &&
        game.currentTurnSeat == null &&
        game.currentTrick?.plays.length == 4) {
      _scheduleResolveTrick(game, isTransition: prevPlays < 4);
    }

    // My turn started
    if (game.currentTurnSeat == mySeat && prev.currentTurnSeat != mySeat) {
      AudioService.instance.play(GameSound.turnStart);
      HapticService.light();
    }

    // Trump declared
    if (game.trumpSuit != null && prev.trumpSuit == null) {
      AudioService.instance.play(GameSound.trumpDeclared);
      HapticService.medium();
      // _handleGameUpdate runs during build: mutate fields directly instead
      // of setState (which would assert), the current build picks them up.
      _showTrumpBanner = true;
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _showTrumpBanner = false);
      });
    }

    // Trick resolved
    if (game.trickNumber > prev.trickNumber &&
        prev.trickNumber > 0 &&
        game.currentTurnSeat != null) {
      _lastTrickPlays = prev.currentTrick?.plays;
      _lastTrickWinnerName =
          game.seats[game.currentTurnSeat]?.displayName ?? '?';
      final winnerTeam = GameState.teamForSeat(game.currentTurnSeat!);
      _trickWinnerSeat = game.currentTurnSeat;
      if (winnerTeam == myTeam) {
        AudioService.instance.play(GameSound.trickWon);
        HapticService.light();
      } else {
        AudioService.instance.play(GameSound.trickLost);
      }
      // In-build mutation, see trump-declared comment.
      _showTrickWin = true;
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) setState(() => _showTrickWin = false);
      });
    }

    // Ten collected
    for (final tenId in ['10S', '10H', '10D', '10C']) {
      if (prev.collectedTens.tens[tenId] == null &&
          game.collectedTens.tens[tenId] != null) {
        final team = game.collectedTens.tens[tenId]!;
        _collectedTenId = tenId;
        _collectedTenTeam = team;
        if (team == myTeam) {
          AudioService.instance.play(GameSound.tenCollected);
          HapticService.medium();
        }
        // In-build mutation, see trump-declared comment.
        _showTenCollected = true;
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (mounted) setState(() => _showTenCollected = false);
        });
        break;
      }
    }

    // All 4 tens collected
    final prevAllA = prev.collectedTens.allCollectedBy('teamA');
    final prevAllB = prev.collectedTens.allCollectedBy('teamB');
    if (!prevAllA && !prevAllB) {
      if (game.collectedTens.allCollectedBy('teamA') ||
          game.collectedTens.allCollectedBy('teamB')) {
        AudioService.instance.play(GameSound.allTens);
        HapticService.heavy();
      }
    }

    // Game completed
    if (prev.status != GameStatus.completed &&
        game.status == GameStatus.completed) {
      // Victory/defeat sound plays on the result screen, which owns the
      // end-of-game feedback; playing it here too doubled it.
      _session.publishFinalHands(_session.myUid);
    }
  }

  void _scheduleResolveTrick(GameState game, {required bool isTransition}) {
    if (_resolvingTrick) return;
    _resolvingTrick = true;
    final plays = game.currentTrick?.plays ?? const [];
    final allBotTrick =
        plays.isNotEmpty &&
        plays.every((p) => game.seats[p.seat]?.isBot == true);
    final delay = isTransition ? (allBotTrick ? 200 : 600) : 100;
    Future.delayed(Duration(milliseconds: delay), () {
      _resolvingTrick = false;
      if (!mounted) return;
      _session.resolveTrick();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AntiCheatOverlay(
        obscured: isObscured,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.maroon, AppColors.maroonDeep],
            ),
          ),
          child: StreamBuilder<GameState>(
            stream: _session.gameStream,
            builder: (context, gameSnap) {
              if (!gameSnap.hasData) {
                return const Center(
                  child: CircularProgressIndicator(color: AppColors.gold),
                );
              }
              final game = gameSnap.data!;
              final mySeat = _session.mySeat!;

              _handleGameUpdate(game, mySeat);

              if (game.status == GameStatus.completed) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) context.go('/local/result');
                });
              }

              final isMyTurn = game.currentTurnSeat == mySeat;

              return StreamBuilder<List<String>>(
                stream: _session.handStream,
                builder: (context, handSnap) {
                  final handIds = handSnap.data ?? [];
                  final hand = handIds.map(PlayingCard.fromId).toList();
                  final leadSuit = game.currentTrick?.plays.isEmpty == true
                      ? null
                      : game.leadSuit;
                  final legalCards = isMyTurn
                      ? getLegalCards(hand, leadSuit).map((c) => c.id).toSet()
                      : <String>{};

                  if (isMyTurn) _maybeClaimRest(game, hand, mySeat);

                  return SafeArea(
                    child: Stack(
                      children: [
                        Column(
                          children: [
                            _buildInfoRail(game, mySeat),
                            if (_lastTrickPlays != null) _buildLastTrickBar(),
                            Expanded(
                              child: _buildTable(
                                game,
                                mySeat,
                                hand,
                                legalCards,
                              ),
                            ),
                            _buildTenTracker(game),
                            _buildHand(hand, legalCards, mySeat, isMyTurn),
                          ],
                        ),
                        if (_showTrumpBanner) _buildTrumpBanner(game),
                        if (_showTrickWin) _buildTrickWinOverlay(game, mySeat),
                        if (_showTenCollected) _buildTenCollectedOverlay(),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTrumpBanner(GameState game) {
    final suit = game.trumpSuit;
    if (suit == null) return const SizedBox.shrink();
    return Positioned(
      top: 80,
      left: 0,
      right: 0,
      child: Center(
        child:
            Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.maroonDark.withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.gold, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.gold.withValues(alpha: 0.3),
                        blurRadius: 20,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: Text(
                    '${suit.symbol} Trump is ${suit.name}!',
                    style: TextStyle(
                      color: (suit == Suit.hearts || suit == Suit.diamonds)
                          ? AppColors.suitRed
                          : AppColors.ivory,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                )
                .animate()
                .fadeIn(duration: 200.ms)
                .scale(begin: const Offset(0.8, 0.8), end: const Offset(1, 1))
                .then()
                .shimmer(
                  duration: 600.ms,
                  color: AppColors.gold.withValues(alpha: 0.3),
                ),
      ),
    );
  }

  Widget _buildTrickWinOverlay(GameState game, int mySeat) {
    final winnerName = _trickWinnerSeat != null
        ? game.seats[_trickWinnerSeat]?.displayName ?? ''
        : '';
    final winnerTeam = _trickWinnerSeat != null
        ? GameState.teamForSeat(_trickWinnerSeat!)
        : null;
    final isMyTeam = winnerTeam == GameState.teamForSeat(mySeat);
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.maroonDark.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isMyTeam ? AppColors.gold : AppColors.silver,
              ),
            ),
            child: Text(
              '$winnerName wins the trick!',
              style: TextStyle(
                color: isMyTeam ? AppColors.gold : AppColors.silver,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ).animate().fadeIn(duration: 200.ms).fadeOut(delay: 600.ms),
        ),
      ),
    );
  }

  Widget _buildTenCollectedOverlay() {
    if (_collectedTenId == null) return const SizedBox.shrink();
    final suit = Suit.fromLetter(_collectedTenId!.substring(2));
    final isTeamA = _collectedTenTeam == 'teamA';
    return Positioned(
      top: 120,
      left: 0,
      right: 0,
      child: Center(
        child:
            Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.maroonDark.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isTeamA ? AppColors.teamA : AppColors.teamB,
                    ),
                  ),
                  child: Text(
                    '10${suit.symbol} collected by ${isTeamA ? "Team A" : "Team B"}!',
                    style: TextStyle(
                      color: isTeamA ? AppColors.teamA : AppColors.teamB,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                )
                .animate()
                .fadeIn(duration: 200.ms)
                .scale(begin: const Offset(0.9, 0.9), end: const Offset(1, 1))
                .then()
                .fadeOut(delay: 800.ms),
      ),
    );
  }

  // ── §4.2 Dense info rail: Turn · Trick · Trump · Scores · Sound · Quit ──

  Widget _buildInfoRail(GameState game, int mySeat) {
    final turnSeat = game.currentTurnSeat;
    final turnName = turnSeat != null
        ? (game.seats[turnSeat]?.displayName ?? '?')
        : '—';
    final isMyTurn = turnSeat == mySeat;
    final myTeam = GameState.teamForSeat(mySeat);
    final partnerSeat = GameState.partnerSeat(mySeat);
    final partner = game.seats[partnerSeat];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: AppColors.maroonDark.withValues(alpha: 0.9),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row 1: Turn · Trick · Trump · Sound · Quit
          Row(
            children: [
              // Turn chip
              _InfoChip(
                icon: isMyTurn ? Icons.person : Icons.smart_toy,
                label: isMyTurn ? 'Your turn' : turnName,
                color: isMyTurn ? AppColors.gold : AppColors.silver,
                glow: isMyTurn,
              ),
              const SizedBox(width: 6),
              // Trick chip
              _InfoChip(
                icon: null,
                label: '${game.trickNumber}/13',
                color: AppColors.ivory,
              ),
              const SizedBox(width: 6),
              // Trump chip
              _InfoChip(
                icon: null,
                label: game.trumpSuit != null
                    ? 'Trump ${game.trumpSuit!.symbol}'
                    : 'No Trump',
                color: game.trumpSuit != null
                    ? ((game.trumpSuit == Suit.hearts ||
                              game.trumpSuit == Suit.diamonds)
                          ? AppColors.suitRed
                          : AppColors.gold)
                    : AppColors.silver,
              ),
              const Spacer(),
              // Sound
              GestureDetector(
                onTap: () async {
                  await AudioService.instance.toggleMute();
                  setState(() {});
                },
                onLongPress: () => _showVolumeDialog(),
                child: Icon(
                  AudioService.instance.muted
                      ? Icons.volume_off
                      : Icons.volume_up,
                  color: AppColors.gold,
                  size: 18,
                ),
              ),
              const SizedBox(width: 8),
              // Quit
              GestureDetector(
                onTap: () => _showQuitDialog(),
                child: const Icon(
                  Icons.close,
                  color: AppColors.silver,
                  size: 18,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Row 2: Team scores with tens
          Row(
            children: [
              // Partner info
              Expanded(
                child: Text(
                  partner != null ? 'Partner: ${partner.displayName}' : '',
                  style: TextStyle(
                    color:
                        (myTeam == 'teamA' ? AppColors.teamA : AppColors.teamB)
                            .withValues(alpha: 0.6),
                    fontSize: 10,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              _ScoreChipDense(
                label: 'A',
                tricks: game.trickPileA.trickCount,
                tens: game.collectedTens,
                team: 'teamA',
                color: AppColors.teamA,
              ),
              const SizedBox(width: 6),
              _ScoreChipDense(
                label: 'B',
                tricks: game.trickPileB.trickCount,
                tens: game.collectedTens,
                team: 'teamB',
                color: AppColors.teamB,
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showVolumeDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.maroonDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Sound Settings',
                style: TextStyle(
                  color: AppColors.gold,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text(
                    'Volume',
                    style: TextStyle(color: AppColors.ivory),
                  ),
                  Expanded(
                    child: Slider(
                      value: AudioService.instance.volume,
                      activeColor: AppColors.gold,
                      inactiveColor: AppColors.burgundy,
                      onChanged: (v) {
                        AudioService.instance.setVolume(v);
                        setSheetState(() {});
                        setState(() {});
                      },
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                title: const Text(
                  'Mute',
                  style: TextStyle(color: AppColors.ivory),
                ),
                value: AudioService.instance.muted,
                activeThumbColor: AppColors.gold,
                onChanged: (v) async {
                  await AudioService.instance.toggleMute();
                  setSheetState(() {});
                  setState(() {});
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _showQuitDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.maroonDark,
        title: const Text(
          'Quit Game?',
          style: TextStyle(color: AppColors.gold),
        ),
        content: const Text(
          'Leave this game and return to the menu?',
          style: TextStyle(color: AppColors.ivory),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Stay',
              style: TextStyle(color: AppColors.silver),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _session.dispose();
              context.go('/');
            },
            child: const Text('Quit', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  // ── §4.2 Ten tracker strip ──

  Widget _buildTenTracker(GameState game) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: AppColors.maroonDark.withValues(alpha: 0.7),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'TENS ',
            style: TextStyle(
              color: AppColors.silver,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          for (final suit in Suit.values) ...[
            const SizedBox(width: 6),
            _TenIcon(suit: suit, collectedTens: game.collectedTens),
          ],
        ],
      ),
    );
  }

  Widget _buildLastTrickBar() {
    final plays = _lastTrickPlays!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: AppColors.maroonDark.withValues(alpha: 0.5),
      // Long player names would overflow narrow screens; shrink instead.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Last: ',
              style: TextStyle(color: AppColors.silver, fontSize: 11),
            ),
            for (final p in plays)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  '${p.card.rank.symbol}${p.card.suit.symbol}',
                  style: TextStyle(
                    color: p.seat == _trickWinnerSeat
                        ? (p.card.suit == Suit.hearts ||
                                  p.card.suit == Suit.diamonds)
                              ? AppColors.suitRed
                              : AppColors.ivory
                        : AppColors.silver,
                    fontSize: 12,
                    fontWeight: p.seat == _trickWinnerSeat
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              ),
            const SizedBox(width: 6),
            Text(
              '→ $_lastTrickWinnerName',
              style: const TextStyle(
                color: AppColors.gold,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTable(
    GameState game,
    int mySeat,
    List<PlayingCard> hand,
    Set<String> legalCards,
  ) {
    final rightSeat = _relativeSeat(mySeat, 1);
    final topSeat = _relativeSeat(mySeat, 2);
    final leftSeat = _relativeSeat(mySeat, 3);

    return LayoutBuilder(
      builder: (context, constraints) {
        final cardW = (constraints.maxWidth * 0.12).clamp(40.0, 65.0);

        return Stack(
          children: [
            _buildOpponentArea(
              game,
              topSeat,
              Alignment.topCenter,
              const EdgeInsets.only(top: 8),
              cardW,
            ),
            _buildOpponentArea(
              game,
              leftSeat,
              Alignment.centerLeft,
              const EdgeInsets.only(left: 8),
              cardW,
            ),
            _buildOpponentArea(
              game,
              rightSeat,
              Alignment.centerRight,
              const EdgeInsets.only(right: 8),
              cardW,
            ),
            Center(child: _buildTrickArea(game, mySeat, cardW)),
          ],
        );
      },
    );
  }

  // ── §4.2 Full opponent edge panels ──

  Widget _buildOpponentArea(
    GameState game,
    int seat,
    Alignment alignment,
    EdgeInsets padding,
    double cardW,
  ) {
    final player = game.seats[seat];
    final isActive = game.currentTurnSeat == seat;
    final hasPlayed =
        game.currentTrick?.plays.any((p) => p.seat == seat) ?? false;
    final cardCount = 13 - game.trickNumber + 1 - (hasPlayed ? 1 : 0);
    final teamColor = GameState.teamForSeat(seat) == 'teamA'
        ? AppColors.teamA
        : AppColors.teamB;
    final stackCount = cardCount.clamp(0, 6);

    return Align(
      alignment: alignment,
      child: Padding(
        padding: padding,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isActive
                  ? AppColors.gold
                  : teamColor.withValues(alpha: 0.4),
              width: isActive ? 2 : 1,
            ),
            color: isActive
                ? AppColors.gold.withValues(alpha: 0.08)
                : AppColors.maroonDark.withValues(alpha: 0.6),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Avatar + Name row
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Avatar with team ring
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: teamColor, width: 2),
                    ),
                    child: CircleAvatar(
                      radius: 12,
                      backgroundColor: teamColor.withValues(alpha: 0.2),
                      child: player?.isBot == true
                          ? Icon(Icons.smart_toy, color: teamColor, size: 14)
                          : Text(
                              (player?.displayName ?? '?')[0].toUpperCase(),
                              style: TextStyle(
                                color: teamColor,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Name + difficulty
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        player?.displayName ?? 'Empty',
                        style: TextStyle(
                          color: isActive ? AppColors.gold : AppColors.ivory,
                          fontSize: 11,
                          fontWeight: isActive
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (player?.isBot == true)
                        Text(
                          (player!.botDifficulty?.name ?? 'medium')
                              .toUpperCase(),
                          style: TextStyle(
                            color: teamColor.withValues(alpha: 0.6),
                            fontSize: 8,
                            letterSpacing: 0.5,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              if (player?.isBot == true && isActive)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child:
                      Text(
                            'thinking...',
                            style: TextStyle(
                              color: AppColors.gold.withValues(alpha: 0.6),
                              fontSize: 9,
                              fontStyle: FontStyle.italic,
                            ),
                          )
                          .animate(onPlay: (c) => c.repeat())
                          .fadeIn(duration: 600.ms)
                          .then()
                          .fadeOut(duration: 600.ms),
                ),
              const SizedBox(height: 4),
              // Card count (big number) + stack
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Stacked face-down cards
                  SizedBox(
                    width: cardW * 0.45 * 2.2,
                    height: cardW * 0.45 * 1.4,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (var i = 0; i < stackCount; i++)
                          Positioned(
                            left: i * 4.0,
                            top: i * 1.5,
                            child: PlayingCardWidget(width: cardW * 0.45),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  // Big card count
                  Text(
                    '$cardCount',
                    style: TextStyle(
                      color: isActive ? AppColors.gold : teamColor,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── §4.2 Bigger center trick area with lead-suit watermark + deck fan ──

  Widget _buildTrickArea(GameState game, int mySeat, double cardW) {
    final trick = game.currentTrick;
    final playCount = trick?.plays.length ?? 0;
    final cardsRemaining = 52 - (game.trickNumber - 1) * 4 - playCount;
    final deckFanCount = (cardsRemaining / 4).ceil().clamp(0, 8);

    // Bigger center: scale to min(available width, available height)
    final centerSize = cardW * 3.5;

    final positions = <int, Offset>{
      mySeat: Offset(0, centerSize * 0.22),
      _relativeSeat(mySeat, 1): Offset(centerSize * 0.25, 0),
      _relativeSeat(mySeat, 2): Offset(0, -centerSize * 0.22),
      _relativeSeat(mySeat, 3): Offset(-centerSize * 0.25, 0),
    };
    final flyFrom = <int, Offset>{
      mySeat: Offset(0, centerSize * 0.6),
      _relativeSeat(mySeat, 1): Offset(centerSize * 0.6, 0),
      _relativeSeat(mySeat, 2): Offset(0, -centerSize * 0.6),
      _relativeSeat(mySeat, 3): Offset(-centerSize * 0.6, 0),
    };

    return SizedBox(
      width: centerSize,
      height: centerSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Deck fan (face-down cards in center, shrinks as game progresses)
          if (deckFanCount > 0 && playCount < 4)
            for (var i = 0; i < deckFanCount; i++)
              Center(
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..translateByDouble(
                      -centerSize * 0.15 + i * 3.0,
                      -centerSize * 0.05 + i * 1.0,
                      0,
                      1,
                    )
                    ..rotateZ(-0.08 + i * 0.02),
                  child: PlayingCardWidget(width: cardW * 0.55)
                      .animate()
                      .fadeIn(
                        delay: Duration(milliseconds: i * 50),
                        duration: 200.ms,
                      ),
                ),
              ),
          // Lead-suit watermark glow
          Center(
            child: Container(
              width: centerSize * 0.75,
              height: centerSize * 0.75,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: game.leadSuit != null && playCount > 0
                    ? RadialGradient(
                        colors: [
                          (game.leadSuit == Suit.hearts ||
                                  game.leadSuit == Suit.diamonds)
                              ? AppColors.suitRed.withValues(alpha: 0.12)
                              : AppColors.ivory.withValues(alpha: 0.08),
                          Colors.transparent,
                        ],
                      )
                    : null,
                color: game.leadSuit == null || playCount == 0
                    ? AppColors.burgundy.withValues(alpha: 0.2)
                    : null,
                border: Border.all(
                  color: AppColors.gold.withValues(alpha: 0.1),
                ),
              ),
              child: game.leadSuit != null && playCount > 0
                  ? Center(
                      child: Text(
                        game.leadSuit!.symbol,
                        style: TextStyle(
                          fontSize: centerSize * 0.15,
                          color:
                              (game.leadSuit == Suit.hearts ||
                                  game.leadSuit == Suit.diamonds)
                              ? AppColors.suitRed.withValues(alpha: 0.25)
                              : AppColors.ivory.withValues(alpha: 0.15),
                        ),
                      ),
                    )
                  : null,
            ),
          ),
          // Played cards at compass positions
          if (trick != null)
            for (var i = 0; i < trick.plays.length; i++)
              () {
                final seat = trick.plays[i].seat;
                final from = flyFrom[seat] ?? Offset.zero;
                final to = positions[seat] ?? Offset.zero;
                final dx = from.dx - to.dx;
                final dy = from.dy - to.dy;
                return Center(
                  child: Transform.translate(
                    offset: to,
                    child:
                        PlayingCardWidget(
                              card: trick.plays[i].card,
                              width: cardW * 0.9,
                            )
                            .animate()
                            .moveX(
                              begin: dx,
                              end: 0,
                              duration: 300.ms,
                              curve: Curves.easeOutCubic,
                            )
                            .moveY(
                              begin: dy,
                              end: 0,
                              duration: 300.ms,
                              curve: Curves.easeOutCubic,
                            )
                            .fadeIn(duration: 150.ms),
                  ),
                );
              }(),
        ],
      ),
    );
  }

  // ── §4.2 Bigger hand: 40–120px, denser fan, legal lift + gold glow ──

  Widget _buildHand(
    List<PlayingCard> hand,
    Set<String> legalCards,
    int mySeat,
    bool isMyTurn,
  ) {
    final sorted = sortHandForDisplay(hand);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        color: AppColors.maroonDark.withValues(alpha: 0.9),
        border: Border(
          top: BorderSide(
            color: isMyTurn ? AppColors.gold : AppColors.burgundy,
            width: isMyTurn ? 2 : 1,
          ),
        ),
        boxShadow: isMyTurn
            ? [
                BoxShadow(
                  color: AppColors.gold.withValues(alpha: 0.2),
                  blurRadius: 12,
                  offset: const Offset(0, -4),
                ),
              ]
            : null,
      ),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final n = sorted.length;
          if (n == 0) {
            final cardW = (constraints.maxWidth * 0.18).clamp(50.0, 100.0);
            final cardH = cardW * 1.4;
            return Center(
              child: Container(
                width: cardW,
                height: cardH,
                decoration: BoxDecoration(
                  color: AppColors.maroonDark.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(cardW * 0.12),
                  border: Border.all(
                    color: AppColors.burgundy.withValues(alpha: 0.7),
                    width: 1.5,
                  ),
                ),
              ),
            );
          }
          final availW = constraints.maxWidth;
          // §4.2: Scale clamp up to ~120px, denser fanned fit
          const visibleFrac = 0.32;
          final cardW = (availW / (1 + (n - 1) * visibleFrac)).clamp(
            40.0,
            120.0,
          );
          final cardH = cardW * 1.4;
          final step = n > 1
              ? ((availW - cardW) / (n - 1)).clamp(0.0, cardW * 0.6)
              : 0.0;
          final totalW = cardW + step * (n - 1);
          final startX = (availW - totalW) / 2;

          return SizedBox(
            height: cardH + 16,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (var i = 0; i < n; i++)
                  Positioned(
                    left: startX + step * i,
                    bottom: 0,
                    child: _buildHandCard(
                      sorted[i],
                      cardW,
                      isLegal: isMyTurn && legalCards.contains(sorted[i].id),
                      onTap: () => _onCardTap(mySeat, sorted[i].id),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHandCard(
    PlayingCard card,
    double width, {
    required bool isLegal,
    required VoidCallback onTap,
  }) {
    return Transform.translate(
      offset: Offset(0, isLegal ? -12 : 0),
      child: PlayingCardWidget(
        key: ValueKey(card.id),
        card: card,
        width: width,
        enabled: isLegal,
        highlighted: isLegal,
        onTap: onTap,
      ),
    );
  }
}

// ── §4.2 Helper widgets for dense info rail ──

class _InfoChip extends StatelessWidget {
  final IconData? icon;
  final String label;
  final Color color;
  final bool glow;

  const _InfoChip({
    this.icon,
    required this.label,
    required this.color,
    this.glow = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: glow ? color.withValues(alpha: 0.15) : Colors.transparent,
        border: Border.all(
          color: glow ? color : color.withValues(alpha: 0.4),
          width: glow ? 1.5 : 1,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: color, size: 12),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScoreChipDense extends StatelessWidget {
  final String label;
  final int tricks;
  final CollectedTens tens;
  final String team;
  final Color color;

  const _ScoreChipDense({
    required this.label,
    required this.tricks,
    required this.tens,
    required this.team,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final capturedTens = tens.tens.entries
        .where((e) => e.value == team)
        .map((e) => Suit.fromLetter(e.key.substring(2)))
        .toList();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: $tricks',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          for (final suit in capturedTens)
            Text(
              suit.symbol,
              style: TextStyle(
                color: (suit == Suit.hearts || suit == Suit.diamonds)
                    ? AppColors.suitRed
                    : AppColors.ivory,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }
}

class _TenIcon extends StatelessWidget {
  final Suit suit;
  final CollectedTens collectedTens;

  const _TenIcon({required this.suit, required this.collectedTens});

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
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
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
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: collected
                  ? (isRed ? AppColors.suitRed : AppColors.ivory)
                  : AppColors.silver.withValues(alpha: 0.4),
            ),
          ),
          Text(
            collected ? (team == 'teamA' ? 'A' : 'B') : '—',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: teamColor ?? AppColors.silver.withValues(alpha: 0.3),
            ),
          ),
        ],
      ),
    );
  }
}
