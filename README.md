# TypeDuel

TypeDuel is a competitive 2D pixel typing duel built with Godot and a Node.js backend. Players log in, queue into matchmaking or create custom rooms, choose a character loadout, then fight through round-based typing battles where speed, accuracy, mana, skills, and passive effects decide the winner.

## Highlights

- Real-time multiplayer typing duels with matchmaking and custom rooms.
- Round loop with skill selection, typing, combat resolution, HP, mana, win streaks, and rematches.
- Three playable characters: Riven, Liora, and Zephon.
- Active skills: Quickslash, Whiplash, and Soulbreak.
- Passive disruption effects including Reversal, Jumble, Phantom, Stutter, and Erosion.
- Account registration, login, profile updates, and profile picture uploads.
- Friends, direct/global chat, leaderboards, online presence, match history, and feedback submission.
- REST API for lobby/account/social flows with WebSocket and Socket.IO sync for in-match state.
- SQLite persistence for users, leaderboard records, chat messages, friends, and match history.

## Tech Stack

- Client: Godot 4.6 project in `game/`
- Server: Node.js, Express, SQLite, Socket.IO, and `ws` in `server/`
- Shared docs/contracts: `shared/api-contracts.js`
- Deployment helper: `docker-compose.yml`

## Repository Layout

```text
type-duel/
|-- game/                  # Godot client project
|   |-- scenes/            # UI, gameplay, entity, audio, and HUD scenes
|   |-- scripts/autoload/  # Global managers for session, skills, HP, mana, audio, etc.
|   |-- scripts/domain/    # Extracted gameplay/domain helpers
|   |-- scripts/services/  # Client-side network/lobby services
|   `-- assets/            # Sprites, fonts, UI, terrain, SFX, BGM, and data
|-- server/                # Express API and real-time game server
|   |-- controllers/       # Auth, rooms, game, friends, chat, feedback
|   |-- routes/            # API route definitions
|   |-- socket/            # Socket.IO and WebSocket handlers
|   |-- services/          # Room, matchmaking, and match-result services
|   |-- database/          # SQLite schema
|   |-- data/              # Characters, skills, sentences, feedback example
|   `-- scripts/           # Migration and seed scripts
|-- shared/                # API contract notes shared between client and server
|-- docs/                  # Architecture, game design, and gameplay flow docs
`-- docker-compose.yml
```

## Requirements

- Godot 4.6 or newer compatible 4.x build
- Node.js 18 or newer
- npm
- Optional: Docker and Docker Compose

The Godot client currently points to the local server at `http://127.0.0.1:3000` in `game/scripts/autoload/GameManager.gd`.

## Quick Start

### 1. Install and run the server

```bash
cd server
npm install
npm start
```

The server starts on port `3000` by default, initializes the SQLite schema from `server/database/schema.sql`, runs migrations, and seeds the database if there are no users yet.

Useful server environment variables:

```bash
PORT=3000
JWT_SECRET=change_this_in_production
LOG_REQUESTS=true
```

### 2. Open and run the Godot client

1. Open Godot.
2. Import the `game/project.godot` project.
3. Run the project. The main scene is `res://scenes/ui/login_scene.tscn`.
4. Register or log in, enter matchmaking or create a custom room, select a character and loadout, then start typing.

For local multiplayer testing, run two Godot instances and log in with two different accounts.

## Docker Server

You can also run the backend with Docker:

```bash
docker compose up --build
```

The compose file exposes `3000:3000` and persists the SQLite database directory through `./server/database`.

## How a Match Works

1. Players enter matchmaking or join a custom room.
2. Each player selects one character, two active skills, and one passive.
3. The room starts and both players enter a repeating round loop.
4. Each round begins with a skill-select phase.
5. Both players type the same sentence during the typing phase.
6. The game tracks progress, WPM, accuracy, typos, mana, and passive mutations.
7. The host resolves combat, syncs HP, and advances the next round.
8. The match ends when a player reaches 0 HP, forfeits, or disconnects long enough to trigger an auto-forfeit.
9. Results update match history and leaderboards.

## API Overview

The backend exposes these main route groups:

- `POST /api/auth/register`, `POST /api/auth/login`, `POST /api/auth/logout`
- `POST /api/rooms/create`, `POST /api/rooms/join`, `POST /api/rooms/matchmake`
- `GET /api/rooms/:code`, `PATCH /api/rooms/:code/select`, `POST /api/rooms/:code/start`
- `PATCH /api/rooms/:code/phase`, `PATCH /api/rooms/:code/progress`, `PATCH /api/rooms/:code/hp`
- `GET /api/game/leaderboard`, `GET /api/game/online-count`, `GET /api/game/history/:user_id`
- `POST /api/chat/send`, `GET /api/chat/messages`
- `POST /api/friends/request`, `POST /api/friends/accept`, `POST /api/friends/remove`
- `POST /api/feedback`
- `GET /api/health`

Real-time gameplay uses authenticated connections over Socket.IO and WebSocket. Important events include `match:join`, `skill:pick`, `typing:progress`, `typing:finished`, `typing:mutation`, `hp:sync`, `phase:typing`, `phase:skill_select`, `forfeit`, and voice relay events.

See `shared/api-contracts.js` for request/response notes and room-state fields.

## Data and Balance

- Character stats live in `server/data/characters.json` and `game/assets/data/characters.json`.
- Skill definitions live in `server/data/skills.json`.
- Typing prompts live in `server/data/sentences.json` and `game/assets/data/sentences.json`.
- Combat design is documented in `docs/GAME_DESIGN.md`.

Current characters:

| Character | HP | Base Damage | Innate |
| --- | ---: | ---: | --- |
| Riven | 85 | 22 | Bloodlust |
| Liora | 100 | 16 | Grace |
| Zephon | 85 | 20 | Overdrive |

## Development Notes

- Rooms and live match state are held in memory on the server, while accounts, social data, leaderboard entries, and match history are stored in SQLite.
- The server runs cleanup for stale rooms, disconnect auto-forfeits, old global chat messages, and unused uploads.
- Multiplayer match results are server-authoritative. Solo history saves are accepted only when marked as solo.
- `npm test` is currently a placeholder and does not run an automated test suite.

## Documentation

- `docs/GAME_DESIGN.md` explains characters, skills, passives, mana, and combat rules.
- `docs/GAMEPLAY_FLOWCHART.md` walks through match flow, phase decisions, disconnects, and sync behavior.
- `docs/architecture.md` describes the current client/server architecture and refactor direction.
- `shared/api-contracts.js` documents API contracts and real-time event expectations.

## Credits

Game UI:

- Tiny RPG - Mana Soul GUI by tiopalada
- Additional UI assets from OpenGameArt.org

Sound effects:

- Sound effects from We Love Indies

Sprites:

- Character sprites generated using the Universal LPC Spritesheet Generator
- Authors include bluecarrot16, JaidynReiman, Benjamin K. Smith, Evert, Eliza Wyatt, TheraHedwig, MuffinElZangano, Durrani, Johannes Sjolund, and Stephen Challener
- Universal LPC Spritesheet Generator: https://github.com/sanderfrenken/Universal-LPC-Spritesheet-Character-Generator
