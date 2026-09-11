import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/providers.dart';
import '../core/services/game_service.dart';
import '../core/services/online_game_session.dart';
import '../core/theme.dart';
import '../features/auth/login_screen.dart';
import '../features/friends/friends_screen.dart';
import '../features/lobby/home_screen.dart';
import '../features/lobby/create_room_screen.dart';
import '../features/lobby/join_room_screen.dart';
import '../features/lobby/lobby_screen.dart';
import '../features/lobby/local_mode_launcher_screen.dart';
import '../features/game_table/game_table_screen.dart';
import '../features/game_table/local_game_table_screen.dart';
import '../features/game_result/game_result_screen.dart';
import '../features/game_result/local_result_screen.dart';

/// Routes that are accessible without authentication (local play vs bots).
const _publicRoutes = {'/login', '/local', '/local/play', '/local/result'};

final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authStateProvider);

  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      final isLoggedIn = authState.value != null;
      final location = state.matchedLocation;
      final isLoginRoute = location == '/login';
      final isPublicRoute = _publicRoutes.contains(location);

      // Allow public routes (local mode) and login without auth
      if (!isLoggedIn && !isLoginRoute && !isPublicRoute) return '/login';
      if (isLoggedIn && isLoginRoute) return '/';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/create',
        builder: (context, state) => const CreateRoomScreen(),
      ),
      GoRoute(
        path: '/join',
        builder: (context, state) => const JoinRoomScreen(),
      ),
      GoRoute(
        path: '/lobby/:gameId',
        builder: (context, state) => LobbyScreen(
          gameId: state.pathParameters['gameId']!,
        ),
      ),
      GoRoute(
        path: '/game/:gameId',
        builder: (context, state) {
          final gameId = state.pathParameters['gameId']!;
          return GameTableScreen(
            session: OnlineGameSession(
              gameId: gameId,
              service: ref.read(gameServiceProvider),
            ),
            gameId: gameId,
          );
        },
      ),
      GoRoute(
        path: '/result/:gameId',
        builder: (context, state) => GameResultScreen(
          gameId: state.pathParameters['gameId']!,
        ),
      ),
      GoRoute(
        path: '/friends',
        builder: (context, state) => FriendsScreen(
          gameId: state.uri.queryParameters['gameId'],
        ),
      ),
      // ── Local Play vs Bots routes ──
      GoRoute(
        path: '/local',
        builder: (context, state) => const LocalModeLauncherScreen(),
      ),
      GoRoute(
        path: '/local/play',
        builder: (context, state) {
          final session = activeLocalSession;
          if (session == null) {
            // No active session — redirect to launcher
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) context.go('/local');
            });
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(color: AppColors.gold),
              ),
            );
          }
          return LocalGameTableScreen(session: session);
        },
      ),
      GoRoute(
        path: '/local/result',
        builder: (context, state) {
          final session = activeLocalSession;
          if (session == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) context.go('/local');
            });
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(color: AppColors.gold),
              ),
            );
          }
          return LocalResultScreen(session: session);
        },
      ),
    ],
  );
});
