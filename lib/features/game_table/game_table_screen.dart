import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/game_state.dart';
import '../../core/models/playing_card.dart';
import '../../core/services/anti_cheat.dart';
import '../../core/services/audio_service.dart';
import '../../core/services/bot_controller.dart';
import '../../core/services/game_service.dart';
import '../../core/theme.dart';
import '../../core/utils/card_rules.dart' show getLegalCards;
import '../../shared_widgets/playing_card_widget.dart';

class GameTableScreen extends ConsumerStatefulWidget {
  final String gameId;
  const GameTableScreen({super.key, required this.gameId});

  @override
  ConsumerState<GameTableScreen> createState() => _GameTableScreenState();
}

class _GameTableScreenState extends ConsumerState<GameTableScreen>
    with WidgetsBindingObserver, AntiCheatMixin {
  late final String _uid;
  late final Stream<GameState> _gameStream;
  late final Stream<List<String>> _handStream;
  bool _playing = false;
  bool _resolvingTrick = false;
  BotController? _botController;
  Timer? _trickWatchTimer;
  GameState? _lastGame;

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
    _uid = FirebaseAuth.instance.currentUser!.uid;
    final svc = ref.read(gameServiceProvider);
    _gameStream = svc.gameStream(widget.gameId);
    _handStream = svc.handStream(widget.gameId, _uid);

    // Sticky trick-watcher: guaranteed fallback that resolves any trick whose
    // 4th card has been played but which hasn't been resolved yet (e.g. UI
    // callbacks dropped because the widget was unmounted mid-play).
    _trickWatchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final game = _lastGame;
      if (game == null || !mounted) return;
      if (game.status != GameStatus.inProgress) return;
      if (game.currentTurnSeat != null) return;
      if (game.currentTrick?.plays.length != 4) return;
      _scheduleResolveTrick(game, isTransition: false);
    });
  }

  @override
  void dispose() {
    _trickWatchTimer?.cancel();
    _botController?.dispose();
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

  Future<void> _playCard(int mySeat, String cardId) async {
    if (_playing) return;
    setState(() => _playing = true);
    AudioService.instance.play(GameSound.cardPlay);
    HapticService.selection();
    try {
      await ref
          .read(gameServiceProvider)
          .playCard(widget.gameId, _uid, mySeat, cardId);
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
    _lastGame = game;
    // Lazily create bot controller when host has bots
    if (game.hostId == _uid &&
        game.players.any((p) => p.isBot)) {
      final svc = ref.read(gameServiceProvider);
      _botController ??= BotController(svc, widget.gameId);
      // Seed cached hands when a new round starts
      if (svc.lastDealtHands != null) {
        _botController!.seedHands(svc.lastDealtHands!, game);
        svc.lastDealtHands = null;
      }
    }
    _botController?.onGameStateChanged(game);

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

    // Remote card played (local plays are handled in _playCard)
    final prevPlays = prev.currentTrick?.plays.length ?? 0;
    final nextPlays = game.currentTrick?.plays.length ?? 0;
    if (nextPlays > prevPlays && nextPlays > 0) {
      final lastPlay = game.currentTrick!.plays.last;
      if (lastPlay.seat != mySeat) {
        AudioService.instance.play(GameSound.cardPlay, volume: 0.4);
      }
    }

    // 4th card played — let animation run, then resolve.
    // Schedule resolution on the transition (prevPlays < 4) AND as a safety
    // net for any later emission where the trick is complete but still
    // awaiting resolution (covers dropped/raced callbacks).
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
      setState(() => _showTrumpBanner = true);
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _showTrumpBanner = false);
      });
    }

    // Trick resolved — trickNumber incremented, winner is currentTurnSeat
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
      setState(() => _showTrickWin = true);
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
        setState(() => _showTenCollected = true);
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
      if (game.winningTeam == myTeam) {
        AudioService.instance.play(GameSound.victory);
        HapticService.heavy();
      } else {
        AudioService.instance.play(GameSound.defeat);
      }
    }
  }

  /// Schedules [GameService.resolveTrick] after a short visual delay so the
  /// 4th card animation can play. [isTransition] is true when the current
  /// state is a fresh 4th-card emission — those get the full animation delay.
  void _scheduleResolveTrick(GameState game, {required bool isTransition}) {
    if (_resolvingTrick) return;
    _resolvingTrick = true;
    final plays = game.currentTrick?.plays ?? const [];
    final allBotTrick =
        plays.isNotEmpty && plays.every((p) => game.seats[p.seat]?.isBot == true);
    final delay =
        isTransition ? (allBotTrick ? 200 : 600) : 100;
    Future.delayed(Duration(milliseconds: delay), () {
      _resolvingTrick = false;
      if (!mounted) return;
      ref.read(gameServiceProvider).resolveTrick(widget.gameId);
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
            stream: _gameStream,
            builder: (context, gameSnap) {
              if (!gameSnap.hasData) {
                return const Center(
                  child: CircularProgressIndicator(color: AppColors.gold),
                );
              }
              final game = gameSnap.data!;
              final mySeat = game.seatForUid(_uid)?.seat;

              if (mySeat != null) {
                _handleGameUpdate(game, mySeat);
              }

              if (game.status == GameStatus.completed) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) context.go('/result/${widget.gameId}');
                });
              }

              if (mySeat == null) {
                return const Center(
                  child: Text(
                    'Not in this game',
                    style: TextStyle(color: AppColors.ivory),
                  ),
                );
              }

              final isMyTurn = game.currentTurnSeat == mySeat;

              return StreamBuilder<List<String>>(
                stream: _handStream,
                builder: (context, handSnap) {
                  final handIds = handSnap.data ?? [];
                  final hand = handIds.map(PlayingCard.fromId).toList();
                  final leadSuit = game.currentTrick?.plays.isEmpty == true
                      ? null
                      : game.leadSuit;
                  final legalCards = isMyTurn
                      ? getLegalCards(hand, leadSuit).map((c) => c.id).toSet()
                      : <String>{};

                  return SafeArea(
                    child: Stack(
                      children: [
                        Column(
                          children: [
                            _buildTopBar(game),
                            if (_lastTrickPlays != null)
                              _buildLastTrickBar(),
                            Expanded(
                              child: _buildTable(
                                game,
                                mySeat,
                                hand,
                                legalCards,
                              ),
                            ),
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

  Widget _buildTopBar(GameState game) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppColors.maroonDark.withValues(alpha: 0.8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.burgundy),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              game.roomCode,
              style: const TextStyle(
                color: AppColors.gold,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: game.trumpSuit != null
                  ? AppColors.gold.withValues(alpha: 0.15)
                  : Colors.transparent,
              border: Border.all(
                color: game.trumpSuit != null
                    ? AppColors.gold
                    : AppColors.burgundy,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: game.trumpSuit != null
                ? Text(
                    'Trump ${game.trumpSuit!.symbol}',
                    style: TextStyle(
                      color:
                          (game.trumpSuit == Suit.hearts ||
                              game.trumpSuit == Suit.diamonds)
                          ? AppColors.suitRed
                          : AppColors.ivory,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                : const Text(
                    'No Trump',
                    style: TextStyle(color: AppColors.silver, fontSize: 12),
                  ),
          ),
          const Spacer(),
          _buildTeamScore(game),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () async {
              await AudioService.instance.toggleMute();
              setState(() {});
            },
            onLongPress: () => _showVolumeDialog(),
            child: Icon(
              AudioService.instance.muted ? Icons.volume_off : Icons.volume_up,
              color: AppColors.gold,
              size: 20,
            ),
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

  Widget _buildTeamScore(GameState game) {
    final tricksA = game.trickPileA.trickCount;
    final tricksB = game.trickPileB.trickCount;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'T${game.trickNumber}/13',
          style: const TextStyle(color: AppColors.silver, fontSize: 13),
        ),
        const SizedBox(width: 8),
        _scoreChip('A', tricksA, game.collectedTens, 'teamA', AppColors.teamA),
        const SizedBox(width: 4),
        _scoreChip('B', tricksB, game.collectedTens, 'teamB', AppColors.teamB),
      ],
    );
  }

  Widget _scoreChip(
    String label,
    int tricks,
    CollectedTens collected,
    String team,
    Color color,
  ) {
    final capturedTens = collected.tens.entries
        .where((e) => e.value == team)
        .map((e) {
      final suit = Suit.fromLetter(e.key.substring(2));
      return suit;
    }).toList();

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
              fontSize: 14,
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
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLastTrickBar() {
    final plays = _lastTrickPlays!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: AppColors.maroonDark.withValues(alpha: 0.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
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

  Widget _buildOpponentArea(
    GameState game,
    int seat,
    Alignment alignment,
    EdgeInsets padding,
    double cardW,
  ) {
    final player = game.seats[seat];
    final isActive = game.currentTurnSeat == seat;
    final hasPlayed = game.currentTrick?.plays.any((p) => p.seat == seat) ?? false;
    final cardCount = 13 - game.trickNumber + 1 - (hasPlayed ? 1 : 0);

    return Align(
      alignment: alignment,
      child: Padding(
        padding: padding,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: isActive
                ? Border.all(color: AppColors.gold, width: 2)
                : null,
            color: isActive
                ? AppColors.gold.withValues(alpha: 0.08)
                : Colors.transparent,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (player?.isBot == true)
                    Padding(
                      padding: const EdgeInsets.only(right: 3),
                      child: Icon(
                        Icons.smart_toy,
                        color: isActive ? AppColors.gold : AppColors.silver,
                        size: 11,
                      ),
                    ),
                  Flexible(
                    child: Text(
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
                  ),
                ],
              ),
              if (player?.isBot == true && isActive)
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
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < (cardCount.clamp(0, 5)); i++)
                    Padding(
                      padding: EdgeInsets.only(left: i > 0 ? -cardW * 0.5 : 0),
                      child: PlayingCardWidget(width: cardW * 0.55),
                    ),
                  if (cardCount > 5)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        '+${cardCount - 5}',
                        style: const TextStyle(
                          color: AppColors.silver,
                          fontSize: 10,
                        ),
                      ),
                    ),
                ],
              ),
              Text(
                player != null
                    ? GameState.teamForSeat(seat).replaceAll('team', 'Team ')
                    : '',
                style: TextStyle(
                  color: player != null
                      ? (GameState.teamForSeat(seat) == 'teamA'
                            ? AppColors.teamA
                            : AppColors.teamB)
                      : AppColors.silver,
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTrickArea(GameState game, int mySeat, double cardW) {
    final trick = game.currentTrick;
    if (trick == null) return const SizedBox.shrink();

    final plays = trick.plays;
    final positions = <int, Offset>{
      mySeat: Offset(0, cardW * 0.8),
      _relativeSeat(mySeat, 1): Offset(cardW * 0.9, 0),
      _relativeSeat(mySeat, 2): Offset(0, -cardW * 0.8),
      _relativeSeat(mySeat, 3): Offset(-cardW * 0.9, 0),
    };
    // Cards fly in from 3x the final offset (player's edge direction)
    final flyFrom = <int, Offset>{
      mySeat: Offset(0, cardW * 2.5),
      _relativeSeat(mySeat, 1): Offset(cardW * 2.5, 0),
      _relativeSeat(mySeat, 2): Offset(0, -cardW * 2.5),
      _relativeSeat(mySeat, 3): Offset(-cardW * 2.5, 0),
    };

    return SizedBox(
      width: cardW * 3,
      height: cardW * 3,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(
            child: Container(
              width: cardW * 2.5,
              height: cardW * 2.5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.burgundy.withValues(alpha: 0.3),
                border: Border.all(
                  color: AppColors.gold.withValues(alpha: 0.15),
                ),
              ),
              child: game.leadSuit != null && trick.plays.isNotEmpty
                  ? Center(
                      child: Text(
                        game.leadSuit!.symbol,
                        style: TextStyle(
                          fontSize: cardW * 0.5,
                          color: (game.leadSuit == Suit.hearts ||
                                  game.leadSuit == Suit.diamonds)
                              ? AppColors.suitRed.withValues(alpha: 0.3)
                              : AppColors.ivory.withValues(alpha: 0.2),
                        ),
                      ),
                    )
                  : null,
            ),
          ),
          for (var i = 0; i < plays.length; i++)
            () {
              final seat = plays[i].seat;
              final from = flyFrom[seat] ?? Offset.zero;
              final to = positions[seat] ?? Offset.zero;
              final dx = from.dx - to.dx;
              final dy = from.dy - to.dy;
              return Center(
                child: Transform.translate(
                  offset: to,
                  child: PlayingCardWidget(
                          card: plays[i].card, width: cardW * 0.85)
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

  Widget _buildHand(
    List<PlayingCard> hand,
    Set<String> legalCards,
    int mySeat,
    bool isMyTurn,
  ) {
    final sorted = List.of(hand)
      ..sort((a, b) {
        final suitCmp = a.suit.index.compareTo(b.suit.index);
        return suitCmp != 0 ? suitCmp : b.rank.value.compareTo(a.rank.value);
      });

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
            // Empty hand: render a placeholder rectangle so the deck area
            // still looks like a card slot.
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
          // Cards overlap: visible fraction ~35% per stacked card
          const visibleFrac = 0.35;
          final cardW = (availW / (1 + (n - 1) * visibleFrac)).clamp(50.0, 100.0);
          final cardH = cardW * 1.4;
          final step = n > 1
              ? ((availW - cardW) / (n - 1)).clamp(0.0, cardW * 0.65)
              : 0.0;
          final totalW = cardW + step * (n - 1);
          final startX = (availW - totalW) / 2;

          return SizedBox(
            height: cardH + 16, // extra space for lifted cards
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
