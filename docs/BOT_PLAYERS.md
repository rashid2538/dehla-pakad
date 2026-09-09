## Task: Add Intelligent Bot Players to the Multiplayer Dehla Pakad Game

Implement a **bot-player system** in the existing Flutter + Firebase multiplayer **Dehla Pakad** card game.

The objective is to allow a human player who creates a room to fill empty seats with AI-controlled bot players when real players are unavailable, so that a complete 4-player game can be started and played normally.

Do not create a separate or simplified game implementation. **Integrate bots into the existing room, player, game-state, turn, card-play, trick, trump, and victory systems.**

First inspect the existing codebase and understand how players, rooms, Firebase state, turns, cards, tricks, teams, and game events are currently implemented. Then implement the bot system using the existing architecture.

---

# 1. Bot Seats in the Lobby

After creating a room, the human host should be able to fill empty seats with bots.

For example:

```text
┌─────────────────────────────┐
│        GAME ROOM            │
│                             │
│  Player 1   [Human]         │
│  Player 2   [🤖 Bot]        │
│  Player 3   [🤖 Bot]        │
│  Player 4   [Empty]         │
│                             │
│  [+ Add Bot]                │
│  [Start Game]               │
└─────────────────────────────┘
```

Requirements:

* Only the room host can add/remove bots.
* A bot occupies a normal player seat.
* Bots count toward the minimum 4-player requirement.
* A bot can only be added to an empty seat.
* The host can remove a bot before the game starts.
* Bots should be distinguishable from human players through a small bot indicator.
* Once the game starts, the seat configuration becomes locked.
* Do not allow more than four players/bots in a room.

If a human player joins an empty seat currently occupied by a bot, define and implement a sensible behavior—preferably allowing the host to remove the bot first, or automatically replacing the bot only before the game starts if this can be done safely.

---

# 2. Funny & Fancy Bot Identities

Create a collection of fun, memorable bot names rather than generic names such as:

```text
Bot 1
Bot 2
Bot 3
```

Use names with a playful Indian/card-game personality, for example:

```text
Sheru
Ustad Ji
Chaudhary Cardwala
10 Ka Baadshah
Chikna Joker
Munna Trumpwala
Chintu Cutlet
Lala Lakhpati
Professor Patta
Bunty Badshah
Golu Gambler
Mirchi Master
Sultan of Suits
Kallu Calculator
Pandit Pakad
Nawab of Naipes
Raja Rummy
Dilli Ka Don
Patta Prasad
Trump Singh
```

Create a sufficiently large pool of names and randomly assign one when a bot is created.

Requirements:

* Avoid duplicate bot names within the same room.
* The name should persist for the lifetime of the game.
* Optionally assign a bot avatar/profile icon.
* Keep the system extensible so more bot personalities can be added later.

---

# 3. Bot Player Data Model

Clearly distinguish human and bot players.

For example:

```text
Player
├── id
├── name
├── seatIndex
├── team
├── type: human | bot
├── avatar
├── isConnected
└── botProfile
```

Do not rely solely on the client to determine whether a player is a bot.

The server/game logic should treat:

```text
type = bot
```

as authoritative.

Never allow a client to impersonate a bot or change a human player into a bot during an active game.

---

# 4. Critical Rule: Bots Must Have Private Knowledge

A bot must behave exactly like a real player from an information-visibility perspective.

### A bot may know:

* Its own cards.
* Cards it has already played.
* Cards currently visible on the table.
* Cards collected during previous tricks.
* The current trump suit, once established.
* The current lead suit.
* Public game state.
* The cards played by other players.
* Which 10s have become publicly/legally observable through completed tricks.
* Its own team.
* Turn order.

### A bot must NOT know:

* Other players' current hands.
* The original complete deck order.
* Hidden/unplayed cards belonging to opponents.
* Future cards.
* The random seed used to shuffle the deck.
* Server-side/private information that a human player would not have access to.

This is extremely important.

**Do not implement the bot by giving it the complete deck or every player's hand.**

The bot decision engine should receive a sanitized game-state view equivalent to what that particular player is legitimately allowed to know.

---

# 5. Bot Decision Engine

Implement a dedicated bot decision service/engine.

For example:

```text
BotPlayer
    ↓
BotDecisionEngine
    ↓
Analyze visible game state
    ↓
Determine legal cards
    ↓
Select card
    ↓
Submit normal card-play action
```

Do not allow the bot to bypass the normal card-validation/gameplay pipeline.

A bot should effectively perform the same action as:

```text
Human Player
    ↓
Select Card
    ↓
Play Card Request
    ↓
Server Validation
    ↓
Game State Update
```

The bot should follow:

```text
Bot
 ↓
Choose Card
 ↓
Normal Play-Card Command
 ↓
Server Validation
 ↓
Normal Trick Resolution
```

This ensures bot and human gameplay remain consistent.

---

# 6. Legal Move Calculation

Before choosing a card, the bot must determine which cards it is legally allowed to play.

Apply the exact existing Dehla Pakad rules.

For example:

```text
IF bot is leading the trick
    → any card can be played

ELSE IF bot has cards matching the lead suit
    → bot MUST play from the lead suit

ELSE
    → bot may play any legal card
```

The bot must never be able to:

* Play a card it does not possess.
* Play a card belonging to another player.
* Play an illegal suit.
* Play twice in the same turn.
* Play after the trick has ended.
* Play when it is not its turn.

---

# 7. Bot Intelligence

Do not make the bot completely random.

Implement a reasonable baseline card-playing strategy.

The bot should consider:

### Lead Suit

When leading:

* Consider cards already played.
* Consider cards likely to be dangerous.
* Consider whether it should attempt to protect/capture a 10.
* Consider its team's current objective.
* Consider the current trump state.

### Following Suit

If the bot must follow suit:

* Decide whether to play high or low.
* Avoid unnecessarily wasting high cards where possible.
* Consider whether the trick contains a 10.
* Consider whether winning the trick benefits its team.

### When Void in Lead Suit

When the bot does not have the lead suit:

* Determine whether playing trump is advantageous.
* Consider whether the trick contains a valuable 10.
* Consider whether winning the trick helps the team.
* Avoid wasting a powerful trump unnecessarily when the trick has little value.

### Protecting / Capturing 10s

Because the primary objective is collecting all four 10s, the bot should understand that **10s have unusually high strategic value**.

The bot should attempt to:

* Win tricks containing an opponent's 10 when strategically reasonable.
* Protect its team's 10s.
* Avoid unnecessarily giving away a 10.
* Track publicly known 10 ownership.
* Recognize when winning a trick could complete the team's four-10 objective.

---

# 8. Difficulty Levels

Structure the bot system so difficulty can be expanded later.

Implement at least:

### Easy

* Primarily legal/random play.
* Basic suit-following.
* Basic trump usage.
* Minimal strategic reasoning.

### Medium

* Understands trick value.
* Considers 10s.
* Uses trump intelligently.
* Avoids obviously bad plays.

### Hard

* Tracks previously played cards.
* Tracks known card distribution.
* Makes stronger decisions around 10s.
* Uses trump strategically.
* Considers teammate/opponent behavior.
* Attempts to maximize probability of achieving the four-10 objective.

If implementing multiple difficulty levels is too large for the current codebase, implement **Medium** first but structure the architecture so Easy/Hard can be added without rewriting the bot system.

---

# 9. Bot Timing & Human-Like Behavior

Bots should not play instantly.

Introduce a configurable thinking delay, for example:

```text
500 ms – 1800 ms
```

with slight random variation.

The delay should make the bot feel like a player thinking about their move.

However:

* Do not block the game state while waiting.
* Do not make the delay excessively long.
* The server must still remain authoritative.
* If the bot's turn becomes invalid while it is thinking, cancel/recalculate the action.
* Do not use timing as a substitute for server validation.

Consider slightly different timing based on difficulty:

```text
Easy   → faster
Medium → moderate
Hard   → slightly longer
```

---

# 10. Bot Behavior / Personality

If practical, allow each bot to have a personality profile.

For example:

```text
Aggressive
Defensive
Trump Lover
10 Hunter
Risk Taker
Conservative
```

The personality should influence card selection subtly without violating game rules.

For example:

**Trump Lover**

* More willing to use trump cards.

**10 Hunter**

* More aggressively attempts to win tricks containing 10s.

**Conservative**

* Preserves strong cards and trump cards where possible.

Do not allow personality differences to reveal hidden information.

---

# 11. Bot Automation

The bot should automatically act whenever:

```text
game.status == active
AND
currentTurn.playerType == bot
AND
game is not over
```

The bot should:

1. Receive the sanitized game state.
2. Determine its legal cards.
3. Evaluate the available cards.
4. Select a card.
5. Wait for a short human-like delay.
6. Submit the normal play-card action.
7. Allow the normal game engine to resolve the action.

The bot should not directly manipulate:

* Trick winners
* Trump suit
* Team scores
* Card ownership
* Victory state
* Other players' hands

---

# 12. Server Authority & Security

This is a critical requirement.

Do not put sensitive bot logic entirely in Flutter if doing so would expose hidden information or allow cheating.

Evaluate the best architecture for running bot decisions.

Prefer:

```text
Firebase Game State
        ↓
Trusted Bot Execution
        ↓
Bot Decision
        ↓
Validated Game Action
        ↓
Firebase Game State
```

The bot's private hand and decision-making must not be exposed to human clients.

If Cloud Functions are used, ensure that:

* A bot action is generated only for the correct bot seat.
* The function can access the bot's private hand.
* Human clients cannot invoke bot actions arbitrarily.
* Bot actions are idempotent.
* Duplicate triggers cannot cause multiple cards to be played.
* Transactions/atomic operations protect game state.

If some bot computation remains client-side, explain the security implications and ensure no hidden information is exposed to that client.

---

# 13. Firebase Data Model

Adapt the existing Firebase schema rather than creating a parallel database structure.

Clearly define how bots are represented.

For example:

```text
games/{gameId}

players/{playerId}
    type: "bot"
    botProfile:
        difficulty: "medium"
        personality: "10_hunter"
```

Private bot state should be protected appropriately.

Do not expose:

```text
bot.hand
```

to other players.

Firestore Security Rules must prevent human clients from reading or modifying another player's private hand.

---

# 14. Bot Events & UI

Bots should participate in the same visual experience as human players.

Display:

* Bot avatar
* Bot name
* Bot indicator
* Current-turn indicator
* Thinking state

When the bot is thinking, show something subtle such as:

```text
🤔 Thinking...
```

or a small animated indicator.

When it plays:

* Use the same card-play animation as humans.
* Use the same card-play sound.
* Use the same trick animations.
* Use the same victory/defeat animations.

Do not create a visually separate gameplay system for bots.

---

# 15. Disconnect & Recovery

Bots should make the game more resilient.

If a human player disconnects during a game, **do not automatically convert them to a bot unless this behavior is explicitly supported by the existing game design**.

If implementing temporary bot takeover, design it carefully:

```text
Human disconnects
       ↓
Grace period
       ↓
Temporary bot control
       ↓
Human reconnects
       ↓
Control returned to human
```

The human must retain ownership of their original cards and player identity.

Do not allow the bot to permanently alter the player's private state.

If this is outside the current scope, leave it disabled but structure the architecture so it can be added later.

---

# 16. Important Multiplayer Edge Cases

Handle:

* Bot's turn begins.
* Bot is removed before game starts.
* Game starts with multiple bots.
* All three other players are bots.
* Human + 3 bots.
* Human + 2 bots + 1 human.
* Bot's turn while another player disconnects.
* Firebase latency.
* Duplicate bot execution.
* Bot action arrives after turn changed.
* Game ends while bot is thinking.
* Trick completes while bot action is pending.
* Bot has no legal card due to inconsistent state.
* Bot is accidentally triggered twice.
* Player reconnects while a bot is thinking.
* Room is closed while bots exist.

Every bot action must be safe to retry and safe to reject if the game state has changed.

---

# 17. Testing

Create tests for the bot system.

At minimum test:

### Card Logic

* Leading a trick.
* Following suit.
* No lead-suit card.
* Trump available.
* Multiple trump cards.
* 10 present in trick.
* 10 absent from trick.
* Final 10 collection.

### Multiplayer

* Human + 3 bots.
* 2 humans + 2 bots.
* 3 humans + 1 bot.
* Bot starts the first trick.
* Bot wins a trick.
* Human wins against bot.
* Bot team wins.
* Bot team loses.

### Security

Verify that:

* Human A cannot read Bot B's private hand.
* Human A cannot modify Bot B's hand.
* Human A cannot force Bot B to play a specific card.
* A bot cannot access another player's hidden hand.
* Clients cannot claim to be bots.
* Bot actions cannot bypass normal validation.

### Concurrency

Test:

* Duplicate bot triggers.
* Simultaneous state updates.
* Delayed Firebase events.
* Reconnection.
* Game ending during bot delay.

---

# 18. Implementation Quality

Follow the existing project's coding conventions and architecture.

Avoid:

* Duplicating game logic.
* Hardcoding seat numbers.
* Hardcoding specific bot names.
* Hardcoding card decisions.
* Trusting client-side bot actions.
* Giving bots access to the entire game state.
* Creating a second card-validation system.

Prefer reusable components such as:

```text
BotManager
BotDecisionEngine
BotStrategy
BotProfile
BotPlayer
BotActionScheduler
```

Use dependency injection where appropriate.

Keep the bot system modular so future improvements such as more sophisticated AI, reinforcement learning, or difficulty levels can be added later.

---

# 19. Final Deliverables

After implementation, provide:

### Code Changes

List:

* Files created.
* Files modified.
* New dependencies.
* Firebase/Cloud Function changes.
* Security rule changes.

### Bot Architecture

Explain:

```text
Lobby
 ↓
Bot Seat
 ↓
Game Start
 ↓
Bot Turn Detection
 ↓
Private State
 ↓
Bot Decision Engine
 ↓
Normal Play Action
 ↓
Server Validation
 ↓
Trick Resolution
 ↓
Next Turn
```

### Bot Strategy

Document the decision-making logic and difficulty level implemented.

### Security

Explicitly explain how the architecture ensures:

> **A bot only knows its own cards and information that would legitimately be visible to that player.**

### Testing

Provide the test cases executed and their results.

---

## Most Important Requirements

1. **Bots must integrate with the existing game engine rather than bypass it.**
2. **The server must remain authoritative.**
3. **A bot must never receive or infer another player's hidden cards from privileged game state.**
4. **Bot actions must pass through the same card-validation pipeline as human actions.**
5. **Bots must behave like believable players rather than playing completely random cards.**
6. **Bots should use the existing animations, sounds, turn indicators, and game events.**
7. **Adding bots must not break existing human-vs-human multiplayer games.**
8. **The implementation must be deterministic and race-condition resistant where game state matters, while allowing the bot's actual decision to have controlled variability.**
9. **Inspect the existing codebase first and adapt the implementation to its current architecture instead of introducing unnecessary architectural changes.**
10. **After implementation, run the application/tests and fix any compilation, runtime, Firebase, or state-management issues introduced by the bot system.**

