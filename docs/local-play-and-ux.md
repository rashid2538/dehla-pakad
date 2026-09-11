# Local Play vs Bots + Dense Table UX — Design Document

**Version:** 1.0 (decisions confirmed)
**Author:** opencode session
**Status:** Approved for implementation

---

## 1. Overview & Goals

Two related asks:

1. **Local "Play vs Bots" mode** — a player starts a game instantly against 3 bots. It must be **fully offline** and **require no login** (works on the login screen *and* the home screen).
2. **Denser table UX** — the game table should use the available screen area far more aggressively: bigger cards, richer per-player panels, more persistent textual info (trump, trick count, tens, tricks) visible at a glance without secondary screens.

This is a **design document**. It resolves ambiguity before implementation, states assumptions, and flags every open question in §9 for the review.

---

## 2. Current State (What Already Exists)

Important discovery: **bots already exist** and are battle-tested in online lobbies.

| Asset | Location | Notes |
|---|---|---|
| Bot AI (easy/medium/hard) | `lib/core/services/bot_engine.dart` | `chooseBotCard()`, `BotMemory`, full strategy for lead/follow/void/trump. |
| Bot driver | `lib/core/services/bot_controller.dart` | Watches Firestore state, plays the current bot's turn through `GameService.playCard`. |
| Bot adding | `GameService.addBot()` (`game_service.dart:199`) | Seats a bot with a name + difficulty. |
| Bot names | `lib/core/utils/bot_names.dart` | 20 themed names. |
| Pure game rules | `lib/core/utils/card_rules.dart` | `shuffleDeck()`, `dealCards()`, `trickWinner()`, `evaluateWinner()`, `claimRemaining` logic, `determineNextGameStarter()`. **No Firebase dependency.** |
| Trick/ten/victory resolution | `GameService._resolveTrick()` (`game_service.dart:434`) | Mirrored logic; currently private and Firestore-coupled. |
| Game table UI | `game_table_screen.dart` | Full seat layout, deal animations, last-trick bar, overlays. |
| Result UI | `game_result_screen.dart` | Court/Poopy banner, breakdown, tens, final hands, next-game. |

The blockers for local mode are purely *plumbing*, not game logic:

- `GameTableScreen` reads via `FirebaseAuth.instance.currentUser!.uid` and `gameServiceProvider` (Firestore streams).
- `GameState` model is a snapshot-shaped class (has `fromFirestore`), usable as-is for pure in-memory state.
- The router hard-redirects all unauthenticated traffic to `/login` (`app_router.dart:19`).

---

## 3. Proposed Feature: Local Play vs Bots

### 3.1 UX Flow (both entry points)

```
[Login screen]                           [Home screen]
   └─ ▸ "Play vs Bots"                      └─ ▸ "Play vs Bots" (prominent, above Create/Join OR beside them)

        └──▶ Local Mode Launcher (/local)
                ├─ Name input (default "You" / last used)
                ├─ Bot difficulty: Easy / Medium / Hard  (single choice applies to all 3 bots)
                └─ [▶ Play]  →  /local/play
```

- No lobby, no ready-gate, no room code, no waiting. One tap on the launcher, then straight to the table.
- The launcher screen is **skippable**: a "Quick Play" button on login/home jumps straight into a Medium difficulty game with default settings.

### 3.2 Developer Choice: one screen, two backends

The expensive, animation-heavy UI (`game_table_screen.dart`, `game_result_screen.dart`) must be **shared**, not duplicated. We introduce a thin **`LocalGameSession`** engine that speaks the same "language" the UI already understands, plus a small **session abstraction** so the shared screens render either an online or a local game.

#### 3.2.1 A new `GameSession` interface

The tables/results screens depend on a handful of capabilities. Extract them:

```dart
/// Everything the shared game UI needs, regardless of backend.
abstract class GameSession {
  String get myUid;
  int? get mySeat;
  Stream<GameState> get gameStream;
  Stream<List<String>> get handStream;      // cards *I* can see
  void playCard(int seat, String cardId);
  void resolveTrick();
  void claimRemaining(int seat);            // "run out the hand" shortcut
  void confirmNextGame(String uid, int seat);
  void startNextGame({required String hostUid});
  void publishFinalHands(String uid);
  void dispose();
}
```

- `OnlineGameSession` — thin adapter over the existing `GameService` + `FirebaseAuth` (current behavior, zero logic change).
- `LocalGameSession` — brand-new in-memory engine (§3.3).

`GameTableScreen`, `GameResultScreen`, and `LobbyScreen` are refactored to receive a `GameSession`. The router wires up the right implementation per route. Result: **one UI codebase** for both modes; online behavior is byte-for-byte identical.

> **Fallback (if the abstraction feels too heavy):** build a separate, simplified `LocalGameTableScreen` by reusing the shared widgets (`PlayingCardWidget`, overlays, bot engine) but skipping the online-only streams. This avoids refactoring stable online screens but duplicates table layout. **Recommended: the abstraction — see §9 Q1.**

#### 3.2.2 Routing & auth

- New routes:
  - `/local` → `LocalModeLauncherScreen` (difficulty/name; also fine to gate nothing)
  - `/local/play` → `GameTableScreen(session: LocalGameSession)`
- Router `redirect` logic updated to whitelist `/local*` for anonymous users (currently everything redirects to `/login`).
- Local mode touches **zero Firebase** — works in airplane mode. No user profile write, no Firestore reads.

### 3.3 The `LocalGameSession` engine (in-memory)

Single-owner class, no Firestore, no network. Owns *all* five pieces of state:

```text
mutable GameState  (exact existing model — no schema change)
Map<seat, List<PlayingCard>> hands   // 4 hands; only mine is exposed downstream
BotMemory                            // shared inference across all 3 bots
List<String> botUids (3)
StreamController<GameState>          // broadcast; UI listens like today
```

Behavioral rules (all reuse pure logic from `card_rules.dart` + `bot_engine.dart`):

1. **Start** — shuffle via `shuffleDeck()`, deal via `dealCards()`, pick random starting seat, set 4 seats = [you] + 3 bots with the chosen difficulty and themed names.
2. **Human turn** — `playCard(seat, card)` validates with the same checks `GameService.playCard` does (turn, ownership, follow-suit — §16-equivalent), then commits:
   - remove card from hand, append to `currentTrick`, set `leadSuit` on first play, set trump on first off-suit play,
   - if 4th card → run in-memory trick resolution (below), else advance `currentTurnSeat`.
3. **Trick resolution** — port of `GameService._resolveTrick()` logic, but driven by the pure helpers already in `card_rules.dart` (`trickWinner`, `evaluateWinner`) instead of Firestore writes. Updates `trickPileA/B`, `collectedTens`, checks victory (all-4-tens / 3-1 / 2-2-with-majority / trick-13), sets `winningTeam`, `victoryType` (court vs poopy), `endReason`.
4. **Bot turns** — after any commit, if `currentTurnSeat` is a bot, schedule its move after a short delay (400–800 ms for feel) using `chooseBotCard(...)` with `BotMemory`. Mirrors `BotController` but reads the engine's own in-memory hands — **no Firestore round-trips**.
   - Bot claims remaining tricks when `canClaimRemaining` holds (same "run it out" shortcut the online bots use).
5. **Victory → result** — `GameStatus.completed` emitted; auto-ready the 3 bots; `publishFinalHands` publishes from the engine's own hands (no Firestore).
6. **Play again** — `startNextGame` uses `determineNextGameStarter` (partner-leads if trump team won, next-clockwise-opponent otherwise, random if no trump) and re-deals. All bots auto-ready.
7. **Leave** — dispose stream; nothing persists.

Because there's no concurrency, **no Firestore transactions needed** — a single synchronous commit per action plus an emitted snapshot is sufficient and simpler to reason about.

### 3.4 What local mode does NOT include (v1)

- No match history / stats (no persistence layer exists yet).
- No resume after app kill (session-scoped state only).
- No "watch the other 3 hands" feature.

These are listed as future work in §8.

---

## 4. UX: Fill the Table

### 4.1 Design Principles

1. **Every pixel is an information surface.** No empty void in the middle; the only "blank" is decorative table felt.
2. **One-glance readability** (already in the spec's §20 goal): at any moment you can answer — *whose turn, what's trump, which tens are where, trick count, trick score* — without opening anything.
3. **Bigger is better** — card sizes scale with available width/height via `LayoutBuilder`, not fixed 40–65px.
4. **Reuse the existing animation system** (flutter_animate + PlayingCardWidget) unchanged.

### 4.2 Target Layout (portrait, Scale by available space)

```
┌──────────────────────────────────────────────┐
│ TURN/TRI CK TRUMP  SCORE A  SCORE B  🔊 SND  │  top information rail (dense chips)
├──────────────────────────────────────────────┤
│  TEAM PANEL A                ┌────────┐      │
│  Avatar+A  Party: 3 bot out  │  OPPONENT top  │  opponent stacks face-down
│  🂠 6x  tens:♠♥              │   ▲    │      │  with team color + count + avatar
│                              └────────┘      │
│  LEFT OPP  ◄  ┌─────────────┐  ►  RIGHT OPP  │
│              │    TABLE     │                │  center: lead-suit glow,
│              │  ♠ lead-suit │                │  played cards 4-way,
│              │  (deck fan)  │                │  subtle deck glyph
│              └─────────────┘                │
├──────────────────────────────────────────────┤
│  TENS: [10♠ A] [10♥ A] [10♦ —] [10♣ B]      │  ten-tracker strip (always visible)
│  Team A: 6 tricks   Team B: 4 tricks         │  trick/score strip
├──────────────────────────────────────────────┤
│          🂠🂠🂠🂠🂠🂠🂠🂠  (your hand, fanned  │  big overlapping cards, 40–120px
│                                 > tap to play│  sort by suit, legal=lifted/glowing
└──────────────────────────────────────────────┘
```

Concrete changes over the current table:

| Area | Current | Proposed |
|---|---|---|
| Top bar | room code + No Trump/trump + 2 chips + sound | Dense chips: **Turn** (whose turn), **Trick N/13**, **Trump ♠** (or "No Trump"), **A score with tens**, **B score with tens**, sound. Hide room code in local mode. |
| Opponent areas | small 11px labels, ≤5 tiny back-cards | Full **edge panels**: avatar + name + bot icon + difficulty, **card count** (big number), stacked face-down backs sized to the edge, team-colored ring, animated "thinking…" stays. |
| Center | `cardW*3` circle area | Bigger (scales to max available), **lead-suit watermark**, **played cards at compass positions**, plus a **face-down deck fan** that shrinks as cards are dealt/played, plus the current trick's winner hint. |
| Ten tracker | folded into score chips (suit symbols) | Dedicated **4-10 icons strip** below the table — grey until a team collects, then that team's color — mirrors the spec §20 row of 4 ten icons. |
| Your hand | 50–100px, 35% overlap | Scale clamp **up to ~120px**, denser fanned fit, legal-move lift + gold glow preserved, optional suit-sorted **small index strip** on desktop/wide screens. |
| Empty home-seat space | n/a | Bottom area also shows **your team's leader label** ("You are Team A, partner: 10 Ka Baadshah") + **remaining cards**. |
| Result screen | compact scroll | Keep, but stack tens + final hands + "Play Again (bots auto-ready)" directly; bigger touch targets. |

### 4.3 Textual info rules

- **Persistent**: trump suit, trick N/13, both teams' trick counts, ten ownership, whose turn, your win condition (e.g. "Need 10♥, 10♦ to sweep").
- **Transient overlays (existing, keep)**: trump-set banner, trick-won toast, ten-collected toast, victory confetti.
- **Local-mode specific**: a small "Playing vs 3 Bots" badge, and a **quit-to-menu** affordance (replaces room code / leave-room flow).

### 4.4 Responsiveness

- Portrait phones (primary): as above.
- Wide/short windows (web/desktop): cap card size by **height** instead of width; put opponent panels on long edges; the info rail becomes two rows if needed.
- Reuse `flutter_animate` for deal/play/collect so the "fill the space" change doesn't degrade motion polish.

---

## 5. Persistence & Data

| Concern | Decision |
|---|---|
| Local game state | **Memory only** (session-scoped). `shared_preferences` already a dependency; optional v2 "resume" persists the last-enough state. |
| Player name | Remember last used **name** + chosen difficulty via `shared_preferences` (nice-to-have, cheap). |
| Firestore | **Not touched** in local mode. No reads, no writes, no auth. |
| Online mode | Unchanged (Firestore remains server of record). |

---

## 6. Implementation Plan (proposed order)

**Phase A — Foundation (land mines cleared)**
1. Extract `GameSession` interface + `OnlineGameSession` adapter; refactor `GameTableScreen`/`GameResultScreen`/`LobbyScreen` to consume it. Verify online play is byte-identical (run app, play a turn).
2. Router: whitelist `/local*` without login.

**Phase B — Local engine**
3. `LocalGameSession` (in-memory `GameState`, hands, bot scheduling, trick/victory resolution port, next-game logic).
4. `LocalModeLauncherScreen` (name + difficulty + quick play).
5. Entries on `LoginScreen` + `HomeScreen`.
6. Local result flow via shared `GameResultScreen`.

**Phase C — Dense UX**
7. Rework `game_table_screen.dart` layout along §4.2 (LayoutBuilder-driven sizes, edge panels, ten-tracker, deck fan, dense info rail).
8. Apply same density principles to `game_result_screen.dart`.
9. Responsive checks on web + phones.

**Phase D — Hardening**
10. Unit tests for `LocalGameSession` (reuse pattern of `test/card_rules_test.dart`): deal counts, follow-suit enforcement, trump set once, trick winner, every victory type, next-game starter, bot edge hands.
11. Manual offline test: airplane mode → local game end-to-end, plus quit/re-enter.

---

## 7. Testing Strategy

- **Logic:** `LocalGameSession` is pure Dart — full unit coverage of every state transition, mirroring the existing `card_rules_test.dart` approach. This also backstops `GameService` where logic is duplicated.
- **UI:** widget tests assert the table renders opponents' card counts, ten-tracker reflects `collectedTens`, and local badge shows in local mode.
- **Integration/manual:** online flows unchanged (regression), local flow in airplane mode (no exceptions, no Firebase calls), result screen next-game loops.

---

## 8. Future Work (explicitly out of scope for v1)

- Local match history + win/loss streaks (needs a local persistence layer).
- Resume in-progress local game.
- Adjustable bot count (e.g., 1-on-1 drill vs a single bot, or 2 bots + spectator) — the engine restricts to exactly 4 seats today (spec §2).
- Difficulty mix per-bot (v1: one difficulty for all three).

---

## 9. Decisions (confirmed in review)

| # | Decision | Ruling |
|---|---|---|
| Q1 | UI reuse strategy | **`GameSession` abstraction** — shared `GameTableScreen`/`GameResultScreen`/`LobbyScreen` for online + local. |
| Q2 | Quick Play vs launcher | **Launcher + Quick Play** — name input + difficulty + one-tap "Quick Play" fast-path at Medium. |
| Q3 | Seat assignment | **Random each game** — teams vary, partner changes. |
| Q4 | UX density scope | **Both modes** — the denser layout applies to online multiplayer too (shared UI). |
| Q5 | Board layout direction | Portrait-first (primary device); responsive on wide/short windows via height-based scaling. |
| Q6 | Name/difficulty persistence | **In scope** — remember last name + difficulty via `shared_preferences`. |
| Q7 | Deck fan in center | **Yes** — animated face-down deck fan that shrinks as cards are played. |

---

## 10. Summary

- **Local Play vs Bots** is a plumbing problem, not a game-logic problem: the rules engine and bot AI already exist and are pure. We add an in-memory `LocalGameSession` that emits the same `GameState` model, a `GameSession` shim so online + local share the polished table/result screens, router whitelisting for `/local*`, and two entry buttons. Zero Firebase in local mode, works fully offline.
- **Dense UX** reworks the table into a structure where every region carries information: a dense info rail, full opponent edge-panels, a bigger center with lead-suit + deck fan, an always-visible ten tracker, and a larger fanned hand — all scaling to available space.