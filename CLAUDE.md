# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Dehla Pakad** is a multiplayer Indian trick-taking card game (4 players, 2 teams) built with Flutter + Firebase. The objective is to collect all four 10s. Full game specification lives in `docs/dehla-pakad-spec.md`.

**Architecture:** Client-authoritative with Firestore Security Rules as guard rails. No Cloud Functions (Spark/free plan). The active player's client validates and commits game state changes via Firestore transactions. Security rules enforce turn order, card ownership, and hand privacy.

## Commands

```bash
flutter run -d chrome              # Run web (primary dev target)
flutter run                        # Run on connected device
flutter test                       # Run all tests
flutter test test/card_rules_test.dart  # Run game logic tests
flutter analyze                    # Lint
firebase deploy --only firestore:rules  # Deploy security rules
firebase deploy --only firestore:indexes
```

## Architecture

```
Flutter Client (game logic runs locally)
├── Riverpod providers → Firestore real-time streams
├── Firestore batch writes/transactions → play card, deal, resolve trick
├── Firestore Security Rules → enforce access control
└── Firebase Auth (Google Sign-In)
```

### Key Design Decisions

- **No Cloud Functions** — all game logic is client-side to stay on Firebase free tier. Security rules prevent reading other players' hands and enforce turn order. Follow-suit is UI-enforced (acceptable for friends-only games).
- **Server of record is Firestore** — game state at `/games/{gameId}`, private hands at `/games/{gameId}/privateHands/{uid}` (readable only by hand owner).
- **Riverpod over Bloc** — the app is mostly "reflect Firestore stream + derive UI booleans." Riverpod's StreamProvider fits this shape with less ceremony.
- **No freezed/codegen** — plain Dart classes with factory constructors. Simpler iteration, fewer moving parts.

### Data Flow for Card Play

1. Player taps card → client validates (turn, hand, follow-suit) via pure functions in `card_rules.dart`
2. Client runs Firestore transaction: read game + hand → validate → write play + remove card from hand
3. If 4th card in trick: client also computes trick winner, updates trickPiles/collectedTens, checks victory
4. All other clients receive update via Firestore real-time listener → UI rebuilds

### Victory Conditions (No Draws)

- All 4 tens to one team → immediate win
- After 13 tricks, tens 3-1 → team with more tens wins
- After 13 tricks, tens 2-2 → team with more tricks wins (13 is odd, always a winner)
- Court Victory = ten-holder is trump-setter's team; Poopy Victory = otherwise

### Next Game Starter

- Trump-setting team won → trump-setter's partner leads next game
- Trump-setting team lost → opponent next clockwise from trump-setter leads
- No trump was set → random

## Code Layout

| Path | Purpose |
|------|---------|
| `lib/core/models/` | Dart models: PlayingCard, GameState, PlayerSeat, UserProfile |
| `lib/core/services/auth_service.dart` | Google Sign-In + Firestore user profile |
| `lib/core/services/game_service.dart` | All Firestore game operations (create/join room, deal, play card, resolve trick, next game) |
| `lib/core/utils/card_rules.dart` | Pure game logic functions (no Firebase) — used for UI hints AND state computation |
| `lib/core/theme.dart` | Royal Indian theme — maroon/gold/Mughal palette |
| `lib/features/lobby/` | Home, create room, join room, lobby screens |
| `lib/features/game_table/` | Main game table screen + card widgets |
| `lib/features/game_result/` | Victory screen with next-game confirmation |
| `lib/shared_widgets/` | PlayingCardWidget (CustomPainter) |
| `lib/router/app_router.dart` | GoRouter with auth gate |
| `firestore.rules` | Firestore security rules |
| `docs/dehla-pakad-spec.md` | Complete game specification |

## Firebase

- **Project:** `dehla-pakad-game`
- **App ID (Android):** `com.himachalminds.dehlapakad`
- **Firestore paths:** `/games/{gameId}`, `/games/{gameId}/privateHands/{uid}`, `/users/{uid}`
- **Auth:** Google Sign-In (must be enabled in Firebase Console)
- **No Cloud Functions, no Blaze plan**

## Theme

Royal Indian: deep maroon (#5C1A2A → #2A0A14), gold (#D4AF37) accents, burgundy (#7B2D3F) surfaces, ivory text, Cinzel headers. See `lib/core/theme.dart` for the full palette.
