import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dehla_pakad/core/models/game_state.dart';
import 'package:dehla_pakad/core/models/playing_card.dart';
import 'package:dehla_pakad/core/services/local_game_session.dart';
import 'package:dehla_pakad/core/utils/card_rules.dart' show getLegalCards;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  LocalGameSession newSession() => LocalGameSession(
        myUid: 'local_human',
        mySeat: 1,
        playerName: 'You',
      );

  test('fresh session survives JSON save/restore round-trip', () {
    final session = newSession();
    session.start();

    final encoded = jsonEncode(session.toSavedGame());
    final restored = LocalGameSession.fromSavedGame(
        jsonDecode(encoded) as Map<String, dynamic>);

    expect(restored, isNotNull);
    expect(restored!.mySeat, 1);
    expect(restored.myUid, 'local_human');
    // Full deep round-trip: identical save maps before/after restore.
    expect(restored.toSavedGame(), session.toSavedGame());
  });

  test('corrupt save or wrong version restores to null', () {
    expect(LocalGameSession.fromSavedGame({'version': 999}), isNull);
    expect(LocalGameSession.fromSavedGame(const {'game': <String, dynamic>{}}),
        isNull);
  });

  test('start() writes a resumable save to SharedPreferences', () async {
    final session = newSession();
    session.start();

    // _emitState → _persist is fire-and-forget; give the async write a beat.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(LocalGameSession.savedGameKey);
    expect(saved, isNotNull);
    final decoded = jsonDecode(saved!) as Map<String, dynamic>;
    expect(decoded['version'], 1);
    expect((decoded['game'] as Map<String, dynamic>)['status'], 'inProgress');
  });

  test('clearSavedGame removes the resume save', () async {
    final session = newSession();
    session.start();
    await session.clearSavedGame();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(LocalGameSession.savedGameKey), isFalse);
  });

  // ── Bot progress / stuck-bot reproduction ──
  //
  // Drives the session the same way the live UI does: the session's own
  // resolve timer (600ms) plus a separate UI `resolveTrick()` call, in both
  // possible timer orderings. If a bot ever lands on turn and the turn stops
  // advancing, the game has wedged — previously observed as a bot showing
  // "thinking..." forever after a trick completed.
  testWidgets('bots always keep the game moving to completion', (tester) async {
    for (var game = 0; game < 6; game++) {
      final session = LocalGameSession(
        myUid: 'local_human',
        mySeat: 1,
        playerName: 'You',
      );
      GameState? state;
      List<PlayingCard> myHand = const [];
      final trace = <String>[];
      session.gameStream.listen((g) {
        state = g;
        trace.add('T${g.trickNumber} turn=${g.currentTurnSeat} '
            'plays=${g.currentTrick?.plays.length} '
            'lead=${g.leadSuit?.letter} '
            'pileA=${g.trickPileA.trickCount} pileB=${g.trickPileB.trickCount} '
            's=${g.status.name}');
        if (trace.length > 2000) trace.removeAt(0);
      });
      session.handStream
          .listen((h) => myHand = h.map(PlayingCard.fromId).toList());
      session.start();

      var iterations = 0;
      var stalled = 0;
      int? lastTurn;
      while (iterations < 600) {
        iterations++;
        await tester.pump(const Duration(milliseconds: 25));
        final g = state;
        if (g == null || g.status != GameStatus.inProgress) break;
        final turn = g.currentTurnSeat;

        if (turn != null && turn == lastTurn) {
          stalled++;
          if (stalled > 20) {
            fail('Game $game: game froze with turn on seat $turn '
                '(${g.seats[turn]?.displayName}), trick ${g.trickNumber}, '
                '${g.currentTrick?.plays.length}/4 played '
                '(status ${g.status}), lastTurn $lastTurn\n'
                'RECENT EMISSIONS:\n${trace.take(12).join("\n")}');
          }
        } else {
          stalled = 0;
          lastTurn = turn;
        }

        if (turn == null && g.currentTrick?.plays.length == 4) {
          // Trick complete — simulate the UI's resolve callback, alternating
          // which timer (session's 600ms vs UI's) gets to run first.
          if (iterations.isEven) {
            await tester.pump(const Duration(milliseconds: 250));
            session.resolveTrick();
            await tester.pump(const Duration(milliseconds: 400));
          } else {
            await tester.pump(const Duration(milliseconds: 600));
            session.resolveTrick();
          }
          continue;
        }

        if (turn == session.mySeat) {
          final lead =
              g.currentTrick?.plays.isEmpty == true ? null : g.leadSuit;
          final legal = getLegalCards(myHand, lead);
          expect(legal, isNotEmpty,
              reason: 'Game $game: human on turn with an empty legal set');
          session.playCard(session.mySeat, legal.first.id);
        } else {
          // Bot on turn (or the trick-resolution gap) — let session timers run.
          await tester.pump(const Duration(milliseconds: 550));
        }
      }

      expect(state?.status, GameStatus.completed,
          reason: 'Game $game never completed — final state: '
              'status=${state?.status}, turn=${state?.currentTurnSeat}, '
              'trick=${state?.trickNumber}, '
              'plays=${state?.currentTrick?.plays.length}/4, '
              'pileA=${state?.trickPileA.trickCount}, '
              'pileB=${state?.trickPileB.trickCount}');
      session.dispose();
      await tester.pump(const Duration(milliseconds: 50));
    }
  });

  // Variant that relies ONLY on the session's internal 600ms resolve timer —
  // no UI resolveTrick() call at all. Proves the live game resolves of its
  // own accord (the symptom "table never clears / no score" indicates the
  // OPPOSITE — resolution never ran, which this guards against).
  testWidgets('session resolves tricks autonomously, without any UI resolve',
      (tester) async {
    final session = LocalGameSession(
      myUid: 'local_human',
      mySeat: 1,
      playerName: 'You',
    );
    GameState? state;
    List<PlayingCard> myHand = const [];
    session.gameStream.listen((g) => state = g);
    session.handStream
        .listen((h) => myHand = h.map(PlayingCard.fromId).toList());
    session.start();

    var iterations = 0;
    while (iterations < 900) {
      iterations++;
      await tester.pump(const Duration(milliseconds: 25));
      final g = state;
      if (g == null || g.status != GameStatus.inProgress) break;
      if (g.currentTurnSeat == session.mySeat) {
        final lead =
            g.currentTrick?.plays.isEmpty == true ? null : g.leadSuit;
        final legal = getLegalCards(myHand, lead);
        expect(legal, isNotEmpty);
        await session.playCard(session.mySeat, legal.first.id);
      } else {
        await tester.pump(const Duration(milliseconds: 550));
      }
    }

    expect(state?.status, GameStatus.completed,
        reason: 'session did not resolve autonomously; final state: '
            'status=${state?.status}, turn=${state?.currentTurnSeat}, '
            'trick=${state?.trickNumber}, plays='
            '${state?.currentTrick?.plays.length}/4, '
            'pileA=${state?.trickPileA.trickCount}, '
            'pileB=${state?.trickPileB.trickCount}, '
            'winning=${state?.winningTeam ?? "none"}');
    // Score must have advanced (>= 2 tricks if the game finished on all-4-
    // tens early, full 13 otherwise). Proves resolution ran autonomously.
    expect(state!.trickPileA.trickCount + state!.trickPileB.trickCount,
        greaterThanOrEqualTo(2),
        reason: 'no trick ever resolved: score never moved from zero');

    session.dispose();
    await tester.pump(const Duration(milliseconds: 50));
  });
}