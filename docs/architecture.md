# TypeDuel - Architecture Documentation

## Current Architecture (Pre-Refactor)

### Godot Client Structure

```
game/
├── scripts/autoload/           # Global singletons
│   ├── GameManager.gd          # Central state, HTTP requests, connection monitoring
│   ├── SkillsManager.gd        # Combat math, skill resolution, mana/streak tracking
│   ├── HPManager.gd            # Health management, character stats
│   ├── VoiceManager.gd         # Voice chat room management
│   ├── SoundManager.gd         # Audio playback
│   └── TransitionManager.gd    # Scene transition orchestration
├── scenes/
│   ├── ui/
│   │   ├── main_menu.gd        # Main menu navigation
│   │   ├── custom_room.gd      # LOBBY - room creation/join, selection sync, matchmaking, launch
│   │   ├── online_lobby.gd     # Online matchmaking lobby
│   │   ├── skill_selection.gd  # Skill pick UI (separate scene)
│   │   ├── login_scene.gd      # Authentication
│   │   ├── leaderboard.gd      # Leaderboard display
│   │   ├── history.gd          # Match history
│   │   ├── account.gd          # Account settings
│   │   └── victory_screen.gd   # Match end UI
│   ├── game/
│   │   ├── game.gd             # GAMEPLAY - thin orchestrator, phase management, round loop
│   │   ├── network_sync.gd     # HTTP polling, WebSocket, server state sync
│   │   ├── typing_handler.gd   # Input handling, sentence rendering, mutations
│   │   ├── combat_resolver.gd  # Round resolution, damage calc, victory/forfeit overlays
│   │   ├── animation_controller.gd  # Sprite animations, combat effects
│   │   └── combat_resolver.gd
│   └── entities/
│       └── player.gd           # Player entity (used in game scene)
└── tests/
    └── simulation.gd           # Test harness
```

**Key Autoload Responsibilities:**

| Singleton | Responsibilities | Lines |
|-----------|------------------|-------|
| `GameManager` | Server URL, user session, room state, connection watchdog, profile pics, logout | 258 |
| `SkillsManager` | Mana tracking, win streaks, skill affordability, `resolve_round()` combat math | 367 |
| `HPManager` | Player/opponent HP, character stats from JSON, heal/damage application | 101 |
| `VoiceManager` | Voice room join/leave | (not examined) |
| `TransitionManager` | Scene transitions with animations | (not examined) |

**Scene Scripts:**

- `custom_room.gd` (1082 lines) - **HIGH RISK**: Lobby coordinator handling:
  - Room CRUD (create/join/leave/delete)
  - Matchmaking queue & deadline countdown
  - Selection sync (PATCH /select)
  - Polling loop & opponent data updates
  - Skill/character UI state
  - Countdown launch → scene transition
  - Forfeit handling in lobby
  - Heartbeat

- `game.gd` (913 lines) - **HIGH RISK**: Gameplay orchestrator:
  - Phase state machine (SKILL_SELECT → TYPING → RESOLVING)
  - Round loop management
  - Skill timer & fast-forward logic
  - Typing phase countdown
  - Victory/forfeit signal routing
  - Match history save (solo only)
  - Pause menu & forfeit flow

- `network_sync.gd` (482 lines) - Network layer:
  - WebSocket connection & messaging
  - HTTP polling (0.5–2s intervals)
  - Room snapshot application
  - Phase/typing/progress sync
  - Mutation relay
  - HP sync (host only)
  - Server time offset calculation

- `combat_resolver.gd` (293 lines) - Combat logic:
  - Round resolution using `SkillsManager.resolve_round()`
  - Dual resolution for host (mirror opponent)
  - HP application
  - Victory/forfeit overlays
  - Match history save (solo, via GameManager)

### Server Structure

```
server/
├── controllers/
│   ├── roomController.js       # Room CRUD, matchmaking, phase/progress updates, forfeit, rematch
│   ├── gameController.js       # Leaderboard, heartbeat, online count, match history, matchmaking penalty
│   ├── authController.js       # Authentication
│   ├── chatController.js       # Chat
│   └── friendsController.js    # Friends
├── routes/
│   ├── rooms.js                # Room endpoints mounted
│   ├── game.js                 # Game endpoints (matchmaking penalty, history, leaderboard)
│   ├── auth.js                 # Auth routes
│   ├── chat.js                 # Chat routes
│   └── friends.js              # Friends routes
├── socket/
│   ├── index.js                # Socket.io event handlers for real-time match play
│   └── ws.js                   # WebSocket server setup
├── config/
│   └── db.js                   # SQLite database setup
├── data/
│   └── characters.json         # Character stat definitions
├── utils/
│   ├── calculations.js         # (not examined)
│   └── jwtSecret.js            # JWT secret for socket auth
├── game/
│   └── match.js                # (not examined)
└── scripts/
    ├── migrate.js              # DB migrations
    └── seed.js                 # Seed data
```

**Key Controller Responsibilities:**

| Controller | Responsibilities | Lines |
|------------|------------------|-------|
| `roomController.js` | In-memory room store, matchmaking queue, phase transitions, progress sync, forfeit/rematch logic | 1021 |
| `gameController.js` | Leaderboard, heartbeat, online presence, match history save, matchmaking penalty | 241 |

**Server State (In-Memory Rooms):**

```javascript
rooms[code] = {
  // Identity
  code, matchmaking, host_id, guest_id, host_name, guest_name,
  // Selections
  host_character, guest_character, host_skills, guest_skills, host_passive, guest_passive,
  // Game state
  status: 'lobby' | 'started' | 'finished',
  phase: 'lobby' | 'skill_select' | 'typing' | 'resolving' | 'finished',
  phase_started_at, typing_started_at, started_at, finished_at,
  round_id, seq,
  // Player state (host)
  host_progress, host_typos, host_mana, host_typing_start,
  host_skill, host_skill_picked, host_mutations,
  host_hp, host_streak,
  // Player state (guest)
  guest_progress, guest_typos, guest_mana, guest_typing_start,
  guest_skill, guest_skill_picked, guest_mutations,
  guest_hp, guest_streak,
  // Finish tracking
  first_finish_at, first_finish_by,
  // Disconnect/forfeit
  forfeit: { at, by, winner, loser, reason } | null,
  disconnect: { host_suspect_at, guest_suspect_at } | null,
  host_last_seen_at, guest_last_seen_at, last_activity_at,
  // Rematch
  host_wants_rematch, guest_wants_rematch,
  // History
  history_saved,
}
```

### Data Flow

#### Lobby Flow (Custom Room / Matchmaking)

```
Player → CustomRoom scene:
  ├─ Create/Join room → HTTP POST /api/rooms/create or POST /api/rooms/join
  ├─ Room state stored server-side in `rooms` in-memory map
  ├─ Client polls GET /api/rooms/:code every 0.5s
  ├─ Client syncs selections via PATCH /api/rooms/:code/select
  ├─ Host clicks Start → POST /api/rooms/:code/start
  │   └─ Server validates both ready, sets status='started', initializes phase/HP
  └─ Poll detects status=='started' → launch countdown → transition to Game scene
```

#### Matchmaking Flow

```
Player → CustomRoom (is_matchmaking=true):
  ├─ POST /api/rooms/queue/join  → added to `matchmakingQueue` array
  ├─ When 2 players queue → immediate match created
  │   └─ Both receive { matched: true, role: 'host'|'guest', room: {...} }
  ├─ Room has `matchmaking=true`, `matchmaking_deadline_at = now+60s`
  ├─ Both players must select char+2skills+passive within 60s
  ├─ If timeout BEFORE both ready → 10s penalty (role-dependent)
  ├─ Both ready → auto-start after 3s lobby countdown
  └─ If opponent leaves during countdown → show popup, 3s → main menu (no penalty)
```

#### Gameplay Flow (Host-Authoritative)

```
Game scene loads:
  ├─ NetworkSync connects WebSocket to wss://.../ws
  ├─ Emits match:join → joins Socket.io room for room_code
  ├─ Host announces phase via PATCH /api/rooms/:code/phase
  │   └─ Socket broadcasts phase:typing / phase:skill_select to room
  ├─ Both clients type; progress synced:
  │   ├─ Every 0.1s: PATCH /api/rooms/:code/progress (HTTP fallback)
  │   └─ WS: typing:progress → relay to opponent
  │   └─ Mutations queued and sent
  ├─ On finish: immediate sync_progress_immediate()
  ├─ First finish recorded server-side (first_finish_at, first_finish_by)
  ├─ Round resolution:
  │   ├─ Host resolves both sides authoritatively
  │   ├─ Host applies HP locally
  │   └─ Host syncs HP via PATCH /api/rooms/:code/hp
  │       └─ Socket broadcasts hp:sync to guest
  ├─ Victory detection:
  │   ├─ HP <= 0 triggers combat_resolver.show_victory()
  │   ├─ Match history saved (solo: GameManager, multiplayer: server)
  │   └─ Victory screen shown
  └─ Rematch:
      ├─ Both set wants_rematch via PATCH /api/rooms/:code/rematch
      └─ Room reset to lobby (status='lobby'), players can re-select
```

#### Forfeit & Disconnect Handling

```
Disconnect detection (per-player, NOT shared):
  ├─ Last seen tracked: host_last_seen_at, guest_last_seen_at
  ├─ 15s no poll → "suspected offline" (disconnect.{host,guest}_suspect_at)
  ├─ 35s no poll → auto-forfeit triggered
  └─ _finishRoomByForfeit(room, by, reason='disconnect_timeout'):
      ├─ Sets forfeit = { at, by, winner, loser, reason }
      ├─ Sets status='finished', phase='finished'
      └─ _persistMatchResults() → saves history + leaderboard

Mid-game forfeit (ESC → Pause → "Forfeit & Leave"):
  ├─ Client calls DELETE /api/rooms/:code (host) or POST /leave (guest)
  ├─ _finishRoomByForfeit() called immediately (status='finished')
  ├─ Client applies 60s matchmaking penalty (if is_matchmaking)
  └─ Other player receives forfeit signal via WS or poll → shows overlay

Lobby forfeit (before start):
  ├─ Host leaves → DELETE → room deleted, no penalty
  ├─ Guest leaves → POST /leave → guest slot cleared, room stays, no penalty
  └─ Applies to BOTH custom and matchmaking rooms
```

---

## Target Architecture (Post-Refactor)

### Godot Client - Proposed Structure

```
game/
├── autoload/                         # Global singletons (true global services only)
│   ├── GameManager.gd               # Session, connection, HTTP helper (narrowed)
│   ├── SkillsManager.gd             # Combat math (unchanged public API)
│   ├── HPManager.gd                 # HP state (unchanged public API)
│   ├── VoiceManager.gd              # Voice (unchanged)
│   ├── TransitionManager.gd         # Scene transitions
│   └── LobbySyncService.gd          # NEW - lobby polling & selection sync
├── scenes/
│   ├── ui/
│   │   ├── main_menu.gd
│   │   ├── custom_room.gd           # UI only - delegates to LobbySyncService
│   │   ├── online_lobby.gd
│   │   ├── skill_selection.gd
│   │   ├── login_scene.gd
│   │   ├── leaderboard.gd
│   │   ├── history.gd
│   │   ├── account.gd
│   │   └── victory_screen.gd
│   ├── game/
│   │   ├── game.gd                 # Thin orchestrator only
│   │   ├── network_sync.gd         # Delegates to NetworkService + WebSocket
│   │   ├── typing_handler.gd       # Input + rendering (unchanged)
│   │   ├── combat_resolver.gd      # Resolution + overlays (unchanged)
│   │   ├── animation_controller.gd
│   │   └── typing_handler.gd
│   └── entities/
│       └── player.gd
├── scripts/
│   ├── domain/                     # Gameplay rules (pure logic, no Godot dependencies)
│   │   ├── matchmaking.gd          # Matchmaking rules, deadline countdown, forfeit logic
│   │   ├── combat/                 # Combat system extracted from SkillsManager
│   │   │   ├── calculator.gd
│   │   │   ├── skills.gd
│   │   │   ├── passives.gd
│   │   │   └──innate_abilities.gd
│   │   └── phase_controller.gd     # Phase state machine (skill_select → typing → resolve)
│   ├── services/                   # External concerns (HTTP, voice, persistence)
│   │   ├── http_service.gd         # Generic HTTP with auth headers
│   │   ├── lobby_service.gd        # Room CRUD, selection sync, polling
│   │   ├── game_service.gd         # Match history, leaderboard, penalties
│   │   └── voice_service.gd        # Voice chat wrapper
│   └── ui/                         # UI helpers (non-scene)
│       ├── lobby_ui.gd
│       └── game_ui.gd
└── resources/
    └── config/
        ├── characters.tres         # Character data (converted from JSON)
        └── skills.tres             # Skill/passive definitions
```

**Key Changes:**

1. **Autoloads narrowed**: `GameManager` no longer handles HTTP directly - delegates to `HttpService`
2. **Lobby logic extracted**: `custom_room.gd` becomes UI-only; all network/state in `LobbySyncService`
3. **Game flow extracted**: Phase transitions, timer logic moved to `PhaseController`
4. **Combat pure**: `SkillsManager` becomes `CombatCalculator` with no Godot dependencies
5. **Services layer**: HTTP, voice, persistence isolated behind interfaces

### Server - Proposed Structure

```
server/
├── controllers/                    # Thin request/response parsers only
│   ├── roomController.js           # Delegates to services (will become thin)
│   ├── gameController.js           # Delegates to services (will become thin)
│   └── ...                        # Other controllers unchanged
├── services/                       # Business logic layer
│   ├── roomService.js              # Room CRUD, presence, TTL
│   ├── matchmakingService.js       # Queue management, matching logic, penalties
│   ├── phaseService.js             # Phase transitions (skill_select → typing)
│   ├── progressService.js          # Progress sync, mutations, first_finish tracking
│   ├── combatService.js            # Round resolution, damage calculation
│   ├── matchResultService.js       # History save, leaderboard update
│   └── roomStateService.js         # Room state transitions ( forfeit/rematch)
├── repositories/                   # Database access layer
│   ├── roomRepository.js           # Room CRUD (in-memory + future DB)
│   ├── matchRepository.js          # Match history queries
│   └── userRepository.js           # User queries, penalties
├── socket/                         # Real-time event handlers (thin wrappers)
│   └── index.js                    # Delegates to services
├── routes/                         # Express routes (unchanged interface)
│   ├── rooms.js
│   ├── game.js
│   └── ...
├── domain/                         # Pure domain models & validators
│   ├── room.js                     # Room class (replaces plain object)
│   ├── match.js                    # Match state machine
│   └── validators.js               # Input validation
├── config/
│   └── db.js
└── utils/
    └── ...                        # Existing utils
```

**Key Changes:**

1. **Controllers thin**: Parse req/res only; delegate to services
2. **Services own rules**: Matchmaking, phase transitions, combat in dedicated classes
3. **Repositories abstract DB**: All SQL in one layer, easy to swap storage later
4. **Domain models**: `Room` class with methods instead of plain object spread
5. **Socket thin**: Event handlers call services directly

---

## Ownership & Responsibility Matrix

| Concern | Current Location | Target Location | Notes |
|---------|-----------------|-----------------|-------|
| Lobby state (room data, selections) | `custom_room.gd` + `roomController.js` | `LobbySyncService` + `RoomService` | Extract polling/sync/validation |
| Match state (round, phase, timers) | `game.gd` + `roomController.js` | `PhaseController` + `PhaseService` | Host-authoritative transitions |
| Persistence (history, leaderboard) | `GameManager.save_match_history()` + `roomController._persistMatchResults()` | `MatchResultService` (server) + `MatchHistoryService` (client) | Server authoritative for MP |
| Voice chat | `VoiceManager.gd` | `VoiceService` (unchanged API) | Wrap for easier testing |
| UI transitions | `TransitionManager.gd` | `TransitionService` | Minor cleanup |
| Character/skill data | JSON + inline constants | `Resources` + `SkillDefinition` classes | Type-safe data |

---

## Risk Assessment

### High-Risk Files (Split Carefully)

| File | Lines | Risks | Extraction Strategy |
|------|-------|-------|---------------------|
| `custom_room.gd` | 1082 | - Polling loop tightly coupled to UI<br>- Matchmaking deadline logic interleaved with UI updates<br>- Selection sync embedded in `_poll_room()`<br>- Countdown/launch flow | 1. Extract `LobbySyncService` (polling, sync, heartbeat)<br>2. Extract `MatchmakingController` (deadline, forfeit, auto-start)<br>3. Thin `custom_room.gd` to signal wiring only |
| `game.gd` | 913 | - Phase state machine mixed with UI updates<br>- Fast-forward logic complex<br>- Timer management per-state<br>- Round resolution glue | 1. Extract `PhaseController` (state transitions, timer expiry)<br>2. Extract `RoundFlowController` (victory/forfeit orchestration)<br>3. Keep `game.gd` as thin coordinator |
| `roomController.js` | 1021 | - Room CRUD + game logic + matchmaking + persistence all in one<br>- In-memory store directly mutated<br>- Phase transition logic | 1. Extract `RoomService` (CRUD, TTL, presence)<br>2. Extract `MatchmakingService` (queue, matching)<br>3. Extract `PhaseService` (state transitions)<br>4. Extract `MatchResultService` (history/leaderboard)<br>5. RoomController becomes thin HTTP façade |
| `gameController.js` | 241 | - Leaderboard + heartbeat + history + penalties mixed | 1. Extract `OnlinePresenceService`<br>2. Extract `MatchHistoryService`<br>3. Extract `PenaltyService` |
| `network_sync.gd` | 482 | - WebSocket + HTTP polling mixed<br>- State application tightly coupled | 1. Extract `NetworkService` (HTTP fallback)<br>2. Extract `WebSocketClient` (WS only)<br>3. Extract `RoomStateApplier` (pure function) |

---

## Regression Checklist

Before and after each major extraction, verify:

- [ ] **Login/Logout** - auth flows, token storage, logout cleanup
- [ ] **Create Room** - host can create, code generated, room exists server-side
- [ ] **Join Room** - guest can join with code, both see each other's names
- [ ] **Matchmaking Join** - player enters queue, gets matched within 60s
- [ ] **Matchmaking Cancel** - leaving queue before match works
- [ ] **Matchmaking Timeout** - 60s timeout applies penalty correctly
- [ ] **Lobby Ready Flow** - both select char+skills+passive, ready indicators
- [ ] **Skill Select Fast-Forward** - host fast-forwards when both done (1.5s min)
- [ ] **Typing Phase Transition** - countdown, sentence appears, typing enabled
- [ ] **Forfeit / Disconnect** - mid-game forfeit shows overlay, penalty applied
- [ ] **Victory / Rematch** - HP reaches 0 → victory screen → history saved
- [ ] **Leaderboard / History** - stats update after match, history page loads

---

## Naming Conventions (Proposed)

- Godot scene scripts: `snake_case.gd` (already mostly consistent)
- Domain/service classes: `PascalCase.gd` with clear responsibility (e.g. `MatchResultService.gd`)
- Server JS: `camelCase` for methods, files in `services/` use `PascalCase` (e.g. `MatchResultService.js`)
- Remove "Manager" except for true global state (`GameManager`, `SkillsManager` retains)
- Replace "god objects" with: `LobbySyncService`, `PhaseController`, `CombatCalculator`, `MatchmakingService`

---

## Extraction Order (Safe Sequence)

**Phase 2–3 (Introduce Boundaries):**

1. **Add service interfaces** (create empty classes, wire through GameManager first)
2. **Extract server match result logic** → `server/services/matchResultService.js` (self-contained, no room state mutation)
3. **Extract server room state transitions** → `server/services/roomStateService.js` (room lifecycle methods)
4. **Extract custom_room.gd matchmaking** → `game/scripts/domain/matchmaking_controller.gd`
5. **Extract custom_room.gd HTTP sync** → `game/scripts/services/lobby_service.gd`
6. **Extract game.gd victory/forfeit** → `game/scripts/domain/game_flow_helper.gd`
7. **Extract network_sync phase handling** → `game/scripts/services/phase_sync_service.gd`

**Phase 4 (Split Big Files):**

8. **Split custom_room.gd** after dependencies extracted; keep old functions as thin wrappers calling new services
9. **Split game.gd** similarly - delegate to PhaseController, RoundFlowController
10. **Split roomController.js** - each endpoint becomes 3 lines calling service methods

**Phase 5–6 (Polish & Safety):**

11. Standardize naming, remove vague "manager" where inappropriate
12. Add targeted tests for:
    - Room lifecycle (create/join/start/finish)
    - Match result persistence
    - Matchmaking penalty & timeout
    - Phase transition rules

This document will be updated as the refactor progresses.
