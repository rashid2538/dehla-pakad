import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dehla_pakad/core/models/game_state.dart';
import 'package:dehla_pakad/core/models/playing_card.dart';
import 'package:dehla_pakad/core/services/local_game_session.dart';
import 'package:dehla_pakad/core/utils/card_rules.dart' show getLegalCards;
import 'package:dehla_pakad/features/game_table/game_table_screen.dart';
import 'package:dehla_pakad/shared_widgets/playing_card_widget.dart';

/// Smoke test for the online table: it accepts any GameSession, so drive it
/// with an in-memory one and play real tricks at phone and desktop sizes.
/// Any layout overflow or build exception fails the test.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  for (final size in const [Size(400, 820), Size(1200, 900)]) {
    testWidgets('online table plays tricks at ${size.width.toInt()}px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final session = LocalGameSession(
        myUid: 'local_human',
        mySeat: 1,
        playerName: 'You',
      );
      GameState? state;
      var hand = <PlayingCard>[];
      session.gameStream.listen((g) => state = g);
      session.handStream.listen(
        (h) => hand = h.map(PlayingCard.fromId).toList(),
      );
      session.start();

      var reachedResult = false;
      final router = GoRouter(
        initialLocation: '/game',
        routes: [
          GoRoute(
            path: '/game',
            builder: (_, _) =>
                GameTableScreen(session: session, gameId: 'local'),
          ),
          GoRoute(
            path: '/result/:gameId',
            builder: (_, _) {
              reachedResult = true;
              return const SizedBox();
            },
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(child: MaterialApp.router(routerConfig: router)),
      );
      await tester.pump();

      try {
        expect(find.text('TENS '), findsOneWidget);
        expect(find.text('1/13'), findsOneWidget);

        for (var i = 0; i < 400 && !reachedResult; i++) {
          final g = state;
          if (g != null &&
              g.status == GameStatus.inProgress &&
              g.currentTurnSeat == 1) {
            final lead = g.currentTrick?.plays.isEmpty == true
                ? null
                : g.leadSuit;
            await session.playCard(1, getLegalCards(hand, lead).first.id);
          }
          await tester.pump(const Duration(milliseconds: 250));
          if ((state?.trickNumber ?? 0) >= 4) break;
        }

        expect(reachedResult || state!.trickNumber >= 4, isTrue);
        if (!reachedResult) {
          expect(find.byType(PlayingCardWidget), findsWidgets);
        }
      } finally {
        session.dispose();
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpWidget(const SizedBox());
      }
    });
  }
}
