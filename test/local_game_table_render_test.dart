import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dehla_pakad/core/models/game_state.dart';
import 'package:dehla_pakad/core/models/playing_card.dart';
import 'package:dehla_pakad/core/services/local_game_session.dart';
import 'package:dehla_pakad/core/utils/card_rules.dart' show getLegalCards;
import 'package:dehla_pakad/features/game_table/local_game_table_screen.dart';
import 'package:dehla_pakad/shared_widgets/playing_card_widget.dart';

/// Renders the real LocalGameTableScreen and walks it across a trick
/// boundary, asserting that no face-up card from the previous trick lingers
/// in the center once a new trick starts.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Set<String> renderedFaceUpIds(WidgetTester tester) {
    final ids = <String>{};
    for (final w in tester.widgetList<PlayingCardWidget>(
        find.byType(PlayingCardWidget))) {
      if (w.card != null) ids.add(w.card!.id);
    }
    return ids;
  }

  /// Drives a fresh game until trick 2 has one card on the table. Returns
  /// the 4 trick-1 card ids, or null if the game ended before inspection
  /// (random all-4-tens finishes in the first 2 tricks).
  Future<List<String>?> driveToInspection(
    WidgetTester tester,
  ) async {
    final session = LocalGameSession(
      myUid: 'local_human',
      mySeat: 1,
      playerName: 'You',
    );
    try {
      GameState? state;
      List<PlayingCard> myHand = const [];
      List<String>? trick1Ids;

      session.gameStream.listen((g) => state = g);
      session.handStream
          .listen((h) => myHand = h.map(PlayingCard.fromId).toList());
      session.start();
      await tester.pumpWidget(
        MaterialApp(home: LocalGameTableScreen(session: session)),
      );
      await tester.pump();

      for (var iterations = 0; iterations < 500; iterations++) {
        await tester.pump(const Duration(milliseconds: 25));
        final g = state;
        if (g == null) continue;
        if (g.status != GameStatus.inProgress) break;

        // Snapshot trick 1's four cards while they are all visible.
        if (trick1Ids == null &&
            g.trickNumber == 1 &&
            g.currentTrick?.plays.length == 4) {
          trick1Ids = g.currentTrick!.plays.map((p) => p.card.id).toList();
        }

        final plays = g.currentTrick?.plays.length ?? 0;

        if (g.currentTurnSeat == null && plays == 4) {
          await tester.pump(const Duration(milliseconds: 650));
          session.resolveTrick();
          await tester.pump(const Duration(milliseconds: 250));
          continue;
        }

        // Once trick 2 has started, poll the render until it converges on
        // the correct table (new trick visible, old trick gone). The UI lags
        // the broadcast stream by a frame or two, but the BUG under test is
        // persistence: previous trick cards never clearing.
        if (g.trickNumber == 2 && plays == 1) {
          var cleared = false;
          List<String>? lastOld;
          Set<String>? lastCenter;
          for (var i = 0; i < 30 && !cleared; i++) {
            await tester.pump(const Duration(milliseconds: 50));
            final eff = state!;
            lastCenter = eff.currentTrick!.plays
                .map((p) => p.card.id)
                .toSet();
            lastOld = trick1Ids;
            final r = renderedFaceUpIds(tester);
            cleared = r.isNotEmpty &&
                r.containsAll(lastCenter) &&
                r.intersection(lastOld!.toSet()).isEmpty;
          }
          expect(cleared, isTrue,
              reason: 'previous trick cards never cleared after the new '
                  'trick started: rendered ${renderedFaceUpIds(tester)}, '
                  'trick2 plays=$lastCenter, old trick=$lastOld');
          return trick1Ids;
        }

        if (g.currentTurnSeat == session.mySeat) {
          final lead =
              g.currentTrick?.plays.isEmpty == true ? null : g.leadSuit;
          final legal = getLegalCards(myHand, lead);
          expect(legal, isNotEmpty);
          await session.playCard(session.mySeat, legal.first.id);
          await tester.pump(const Duration(milliseconds: 25));
        } else {
          await tester.pump(const Duration(milliseconds: 550));
        }
      }
    } finally {
      // Flush the screen's overlay timers (trump banner etc.) and the
      // session's resolve timer before teardown.
      await tester.pump(const Duration(seconds: 3));
      session.dispose();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(const SizedBox());
    }
    return null;
  }

  testWidgets('previous trick cards vanish when the next trick starts',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (var attempt = 0; attempt < 5; attempt++) {
      final result = await driveToInspection(tester);
      if (result != null) return; // inspected successfully
    }
    fail('game completed before trick 2 across 5 random deals; '
        'no inspection performed');
  });
}