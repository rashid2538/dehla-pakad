import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dehla_pakad/core/models/game_session.dart';
import 'package:dehla_pakad/core/models/game_state.dart';
import 'package:dehla_pakad/core/models/player.dart';
import 'package:dehla_pakad/features/game_result/local_result_screen.dart';
import 'package:dehla_pakad/shared_widgets/result_overlays.dart';

/// Emits on publish like the real LocalGameSession, so a result screen that
/// publishes on every build would loop here too.
class _FakeSession implements GameSession {
  _FakeSession(this.game);

  GameState game;
  final _games = StreamController<GameState>.broadcast();
  int publishCalls = 0;
  int confirmCalls = 0;

  void emit() => _games.add(game);

  @override
  String get myUid => 'me';
  @override
  int? get mySeat => 1; // Team A
  @override
  Stream<GameState> get gameStream async* {
    yield game;
    yield* _games.stream;
  }

  @override
  Stream<List<String>> get handStream => const Stream.empty();
  @override
  void publishFinalHands(String uid) {
    publishCalls++;
    emit();
  }

  @override
  void confirmNextGame(String uid, int seat) => confirmCalls++;
  @override
  Future<void> playCard(int seat, String cardId) async {}
  @override
  void resolveTrick() {}
  @override
  void claimRemaining(int seat) {}
  @override
  void startNextGame({required String hostUid}) {}
  @override
  void dispose() => _games.close();
}

GameState _finished({required String winner, required VictoryType type}) =>
    GameState(
      gameId: 'g',
      status: GameStatus.completed,
      roomCode: 'ROOM',
      hostId: 'me',
      seats: {
        1: const PlayerSeat(uid: 'me', displayName: 'You', seat: 1),
        2: const PlayerSeat(
          uid: 'b2',
          displayName: 'Bot Two',
          seat: 2,
          isBot: true,
        ),
        3: const PlayerSeat(
          uid: 'b3',
          displayName: 'Bot Three',
          seat: 3,
          isBot: true,
        ),
        4: const PlayerSeat(
          uid: 'b4',
          displayName: 'Bot Four',
          seat: 4,
          isBot: true,
        ),
      },
      trumpTeam: 'teamA',
      winningTeam: winner,
      victoryType: type,
      endReason: 'Game over.',
      collectedTens: CollectedTens(
        tens: {'10S': winner, '10H': winner, '10D': winner, '10C': winner},
      ),
    );

Future<_FakeSession> _pumpResult(WidgetTester tester, GameState game) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final session = _FakeSession(game);
  await tester.pumpWidget(
    MaterialApp(home: LocalResultScreen(session: session)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  return session;
}

Future<void> _finish(WidgetTester tester, _FakeSession session) async {
  await tester.pump(const Duration(seconds: 10)); // let every effect finish
  await tester.pumpWidget(const SizedBox());
  session.dispose();
}

void main() {
  testWidgets('poopy defeat: poops splat on top, stay put, buttons work', (
    tester,
  ) async {
    final session = await _pumpResult(
      tester,
      _finished(winner: 'teamB', type: VictoryType.poopy),
    );

    expect(find.text('💩 Poopy Defeat!'), findsOneWidget);
    expect(find.byType(PoopOverlay), findsOneWidget);
    expect(find.byType(ConfettiOverlay), findsNothing);
    final poops = find.text('\u{1F4A9}');
    expect(poops, findsNWidgets(18));

    // Publishing hands emits a state; it must not trigger another publish.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(session.publishCalls, 1);

    // Overlay paints above the result content.
    final stack = tester.widget<Stack>(
      find
          .ancestor(of: find.byType(PoopOverlay), matching: find.byType(Stack))
          .first,
    );
    expect(stack.children.last, isA<PoopOverlay>());

    // Mid-splat, a state update (e.g. a player confirming) must neither move
    // the poops nor restart their animation.
    await tester.pump(const Duration(milliseconds: 900));
    List<Offset> spots() => [
      for (var i = 0; i < 18; i++) tester.getTopLeft(poops.at(i)),
    ];
    final before = spots();
    session.emit();
    await tester.pump();
    expect(spots(), before);

    // After sticking, poops slide down the screen.
    await tester.pump(const Duration(milliseconds: 3000));
    final after = spots();
    var slid = 0;
    for (var i = 0; i < 18; i++) {
      if (after[i].dy > before[i].dy + 20) slid++;
    }
    expect(slid, greaterThan(9));

    // IgnorePointer: the overlay does not swallow taps.
    await tester.ensureVisible(find.text('Play Again'));
    await tester.tap(find.text('Play Again'));
    expect(session.confirmCalls, 1);

    await _finish(tester, session);
  });

  testWidgets('poopy victory shows confetti, not poop', (tester) async {
    final session = await _pumpResult(
      tester,
      _finished(winner: 'teamA', type: VictoryType.poopy),
    );
    expect(find.text('💥 Poopy Victory!'), findsOneWidget);
    expect(find.byType(ConfettiOverlay), findsOneWidget);
    expect(find.byType(PoopOverlay), findsNothing);
    await _finish(tester, session);
  });

  testWidgets('court victory shows confetti on top', (tester) async {
    final session = await _pumpResult(
      tester,
      _finished(winner: 'teamA', type: VictoryType.court),
    );
    expect(find.text('👑 Court Victory!'), findsOneWidget);
    final stack = tester.widget<Stack>(
      find
          .ancestor(
            of: find.byType(ConfettiOverlay),
            matching: find.byType(Stack),
          )
          .first,
    );
    expect(stack.children.last, isA<ConfettiOverlay>());
    await _finish(tester, session);
  });

  testWidgets('plain defeat shows neither overlay', (tester) async {
    final session = await _pumpResult(
      tester,
      _finished(winner: 'teamB', type: VictoryType.victory),
    );
    expect(find.text('😞 Defeat!'), findsOneWidget);
    expect(find.byType(PoopOverlay), findsNothing);
    expect(find.byType(ConfettiOverlay), findsNothing);
    await _finish(tester, session);
  });
}
