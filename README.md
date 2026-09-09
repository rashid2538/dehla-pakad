# Dehla Pakad 🃏

A real-time multiplayer Indian trick-taking card game built with Flutter and Firebase. **Grab all the Tens!**

[Play Online](https://dehla-pakad-game.web.app) · [Download APK](https://github.com/rashid2538/dehla-pakad/releases/latest)

![Dehla Pakad](site/public/assets/hero.png)

## About the Game

**Dehla Pakad** (दहला पकड़ — "Catch the Tens") is a classic 4-player partnership card game popular across India. Two teams of two compete to collect all four Tens from the deck. The team that captures all four Tens — or holds more Tens after 13 tricks — wins the round.

### Key Rules

- **4 players, 2 teams** — partners sit across from each other (seats 1 & 3 vs 2 & 4)
- **Trump is set** by the first player who can't follow suit — their played card's suit becomes trump
- **Follow suit** is mandatory — play any card if void
- **Victory conditions:**
  - All 4 Tens → immediate win
  - After 13 tricks: 3-1 Tens → team with more wins
  - After 13 tricks: 2-2 Tens → team with more tricks wins
- **Court Victory** if the winning team set the trump; **Poopy Victory** otherwise

## Features

- **Real-time Multiplayer** — play with friends via room codes, powered by Firestore real-time sync
- **Bot Players** — add AI opponents with medium-difficulty strategy (suit following, Ten protection, trump management)
- **No Server Required** — runs entirely on Firebase free tier (Spark plan), no Cloud Functions
- **Royal Indian Theme** — deep maroon, gold accents, Mughal-inspired UI
- **Cross-Platform** — Android APK + PWA (web)
- **Persistent Rooms** — seamless "Play Again" flow with automatic re-deal

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Frontend | Flutter (Dart) |
| Auth | Firebase Auth (Google Sign-In) |
| Database | Cloud Firestore (real-time) |
| Hosting | Firebase Hosting |
| State | Riverpod |
| Routing | GoRouter |
| CI/CD | GitHub Actions |

## Architecture

Client-authoritative with Firestore Security Rules as guard rails:

```
Flutter Client
├── Pure game logic (card_rules.dart) — validation & state computation
├── Firestore transactions — atomic card plays & trick resolution
├── Security Rules — enforce hand privacy, turn order, access control
└── Bot engine — runs on host client, same validation pipeline
```

- **No Cloud Functions** — all logic is client-side to stay on Firebase free tier
- **Hand privacy** — each player's hand stored in `/games/{id}/privateHands/{uid}`, readable only by owner (bots readable by host via security rule exception)
- **Bot system** — host client executes bot turns with realistic delay, using the same `playCard` transaction as humans

## Getting Started

### Prerequisites

- Flutter SDK (≥ 3.13)
- Firebase project with Auth + Firestore enabled
- Android SDK (for APK builds)

### Setup

```bash
# Clone
git clone https://github.com/rashid2538/dehla-pakad.git
cd dehla-pakad

# Add your Firebase config files (not in repo):
#   android/app/google-services.json
#   ios/Runner/GoogleService-Info.plist
#   lib/firebase_options.dart

# Run
flutter pub get
flutter run -d chrome
```

### Firebase Configuration

1. Create a Firebase project at [console.firebase.google.com](https://console.firebase.google.com)
2. Enable **Google Sign-In** in Authentication
3. Enable **Cloud Firestore**
4. Deploy security rules: `firebase deploy --only firestore:rules`
5. Add your platform config files (see `.gitignore` for what's excluded)

## Project Structure

```
lib/
├── core/
│   ├── models/          # PlayingCard, GameState, PlayerSeat
│   ├── services/        # GameService, AuthService, BotEngine, BotController
│   ├── utils/           # card_rules.dart (pure game logic), bot_names.dart
│   └── theme.dart       # Royal Indian color palette
├── features/
│   ├── lobby/           # Home, create/join room, lobby
│   ├── game_table/      # Main game screen
│   └── game_result/     # Victory screen
├── shared_widgets/      # PlayingCardWidget (CustomPainter)
└── router/              # GoRouter with auth gate
```

## Contributing

Contributions are welcome! Please open an issue first to discuss what you'd like to change.

## License

[MIT](LICENSE)

## Credits

Built by [Rashid Mohamad](https://github.com/rashid2538).
