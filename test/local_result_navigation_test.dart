import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dehla_pakad/core/models/game_state.dart';
import 'package:dehla_pakad/core/models/playing_card.dart';
import 'package:dehla_pakad/core/services/local_game_session.dart';
import 'package:dehla_pakad/core/utils/card_rules.dart' show getLegalCards;
import 'package:dehla_pakad/features/game_result/local_result_screen.dart';
import 'package:dehla_pakad/features/game_table/local_game_table_screen.dart';

/// Reproduces the live completion flow: LocalGameTableScreen navigates to
/// /local/result on game-over, and LocalResultScreen must render the winner
/// instead of its loading indicator.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('game over navigates to a rendered result screen, not a spinner',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final session = LocalGameSession(
      myUid: 'local_human',
      mySeat: 1,
      playerName: 'You',
    );

    // Minimal router mirroring app_router.dart's local routes.
    final router = GoRouter(
      initialLocation: '/local/play',
      routes: [
        GoRoute(
          path: '/local/play',
          builder: (context, state) => LocalGameTableScreen(session: session),
        ),
        GoRoute(
          path: '/local/result',
          builder: (context, state) => LocalResultScreen(session: session),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();

    GameState? g;
    List<PlayingCard> myHand = const [];
    session.gameStream.listen((s) => g = s);
    session.handStream
        .listen((h) => myHand = h.map(PlayingCard.fromId).toList());
    session.start();

    // Drive the game to completion, letting bots play on their own timers.
    for (var iterations = 0; iterations < 1200; iterations++) {
      await tester.pump(const Duration(milliseconds: 25));
      final state = g;
      if (state == null || state.status != GameStatus.inProgress) break;
      if (state.currentTurnSeat == session.mySeat) {
        final lead =
            state.currentTrick?.plays.isEmpty == true ? null : state.leadSuit;
        final legal = getLegalCards(myHand, lead);
        expect(legal, isNotEmpty);
        await session.playCard(session.mySeat, legal.first.id);
      } else {
        await tester.pump(const Duration(milliseconds: 550));
      }
    }

    // Give the completed-state navigation time to run.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(g?.status, GameStatus.completed,
        reason: 'game did not reach completion, got ${g?.status.name}');

    expect(router.routerDelegate.currentConfiguration.uri.path,
        '/local/result',
        reason: 'table did not navigate to the result route');

    // The result screen must be showing the actual result, NOT the spinner.
    final spinner = find.byType(CircularProgressIndicator);
    expect(spinner, findsNothing,
        reason: 'result screen is stuck on the loading indicator');

    final result = find.byType(LocalResultScreen);
    expect(result, findsOneWidget);

    // Flush the result screen's animation timers (cascading card particles
    // use delays up to ~5s) before disposing the session.
    await tester.pump(const Duration(seconds: 7));
    session.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });
}