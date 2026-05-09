# TypeDuel - Gameplay Flowchart

## High-Level Game Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                         GAME START                               │
│                                                                  │
│  • Players matched in lobby (matchmaking or custom room)        │
│  • Both select: Character, 2 Skills, 1 Passive                  │
│  • Host clicks "Start Game" → loads game scene                  │
│  • Initialize HP based on character (Riven: 85, Liora/Zephon: 100) │
│  • Initialize Mana = 2 for both players                         │
│  • Round counter = 1                                            │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    ROUND LOOP (Repeats)                          │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                   PHASE 1: SKILL SELECT                          │
│                     (10 second timer)                            │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Can player afford any skill?                            │   │
│  │  • Quickslash: 2 Mana                                   │   │
│  │  • Whiplash: 2 Mana                                     │   │
│  │  • Soulbreak: 3 Mana                                    │   │
│  └─────────────────────────────────────────────────────────┘   │
│           ↓ YES                              ↓ NO               │
│  ┌──────────────────────┐         ┌──────────────────────┐     │
│  │ Show skill buttons   │         │ Hide skill buttons   │     │
│  │ Wait for selection   │         │ Auto-advance         │     │
│  └──────────────────────┘         └──────────────────────┘     │
│           ↓                                   ↓                 │
│  ┌──────────────────────┐                    │                 │
│  │ Player clicks skill? │                    │                 │
│  └──────────────────────┘                    │                 │
│     ↓ YES        ↓ NO                        │                 │
│  ┌────────┐  ┌────────┐                      │                 │
│  │ Store  │  │ Wait   │                      │                 │
│  │ choice │  │ timer  │                      │                 │
│  └────────┘  └────────┘                      │                 │
│           ↓                                   ↓                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Timer expires OR both players can't pick?              │   │
│  │  • Host fast-forwards if both players done (1.5s min)  │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                   PHASE 2: TYPING PHASE                          │
│                    (60 second timer)                             │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ 1. Fade in sentence (1s delay + 0.4s fade)             │   │
│  │ 2. Both players type the SAME sentence                 │   │
│  │ 3. Track: progress, WPM, accuracy, typos, mana         │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ MANA GAIN (during typing):                              │   │
│  │  • +1 Mana per accurately typed word (0 typos in word) │   │
│  │  • Zephon Overdrive: +1 extra if WPM > 80              │   │
│  │  • Max Mana = 10                                        │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ PASSIVE ABILITIES (trigger during typing):              │   │
│  │  • Reversal: Reverse random word if you finish first   │   │
│  │  • Jumble: Shuffle word order if Mana ≥ 7              │   │
│  │  • Phantom: Swap 2 words per charge (85%+ accuracy)    │   │
│  │  • Stutter: Duplicate word if opponent on win streak   │   │
│  │  • Erosion: Replace char with _ every 3 perfect words  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ FINISH DETECTION:                                       │   │
│  └─────────────────────────────────────────────────────────┘   │
│           ↓                                                     │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Did player finish sentence?                              │  │
│  └──────────────────────────────────────────────────────────┘  │
│     ↓ YES                                    ↓ NO              │
│  ┌────────────────────┐              ┌──────────────────────┐  │
│  │ Check accuracy:    │              │ Wait for timer or    │  │
│  │ 60% correct?       │              │ opponent to finish   │  │
│  └────────────────────┘              └──────────────────────┘  │
│     ↓ YES    ↓ NO                             ↓                │
│  ┌──────┐ ┌──────┐                   ┌──────────────────────┐  │
│  │ Keep │ │ Show │                   │ 60s timer expires?   │  │
│  │ skill│ │ warn │                   └──────────────────────┘  │
│  │      │ │ +    │                     ↓ YES        ↓ NO      │
│  │      │ │ Clear│                   ┌──────┐   ┌──────────┐  │
│  │      │ │ skill│                   │ DNF  │   │ Continue │  │
│  └──────┘ └──────┘                   │ mode │   │ typing   │  │
│     ↓                                 └──────┘   └──────────┘  │
│  ┌────────────────────┐                  ↓                     │
│  │ Am I first?        │                  ↓                     │
│  └────────────────────┘          ┌──────────────────────────┐  │
│     ↓ YES    ↓ NO                │ Resolve round            │  │
│  ┌──────┐ ┌──────┐               │ (no_attack mode)         │  │
│  │ +2   │ │ Opp  │               └──────────────────────────┘  │
│  │ Mana │ │ gets │                                             │
│  │ bonus│ │ +2   │                                             │
│  └──────┘ └──────┘                                             │
│     ↓         ↓                                                │
│  ┌────────────────────┐                                        │
│  │ Start SNAP timer   │                                        │
│  │ (10 seconds)       │                                        │
│  └────────────────────┘                                        │
│           ↓                                                     │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Did opponent finish within 10s?                          │  │
│  └──────────────────────────────────────────────────────────┘  │
│     ↓ YES                              ↓ NO                    │
│  ┌────────────────────┐         ┌──────────────────────────┐  │
│  │ Both finished      │         │ Only I finished          │  │
│  │ → BUFF/DEBUFF mode │         │ → FULL_POWER mode        │  │
│  └────────────────────┘         └──────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                 PHASE 3: COMBAT RESOLUTION                       │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ FINISH MODES:                                           │   │
│  │  • buff: I finished first, opponent finished in 10s    │   │
│  │  • debuff: I finished second                           │   │
│  │  • full_power: I finished, opponent DNF (2× debuff)    │   │
│  │  • dnf: I didn't finish, opponent did                  │   │
│  │  • no_attack: Neither finished (-5 HP to both)         │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ SKILL VALIDATION:                                       │   │
│  │  1. Can afford skill cost?                              │   │
│  │     → NO: Cancel skill                                  │   │
│  │  2. Met 60% accuracy requirement?                       │   │
│  │     → NO: Cancel skill, mana lost                       │   │
│  │  3. Finished typing (not no_attack)?                    │   │
│  │     → NO: Cancel skill                                  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ DAMAGE CALCULATION:                                     │   │
│  │  Base = Character Base DMG                              │   │
│  │  WPM Modifier = (WPM - 40) / 100                        │   │
│  │  Acc Modifier = (Accuracy - 80) / 100                   │   │
│  │  Typo Penalty = -2 DMG per typo                         │   │
│  │                                                          │   │
│  │  Formula: CEIL(BaseDMG * (1 + modifier) - typos * 2)   │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ SKILL EFFECTS:                                          │   │
│  │                                                          │   │
│  │  QUICKSLASH (2 Mana):                                   │   │
│  │   • Win: ×1.1 (×1.2 with streak)                        │   │
│  │   • Lose: ×0.9 (0 DMG if opp on streak)                │   │
│  │   • Full Power: additional ×1.2                         │   │
│  │                                                          │   │
│  │  WHIPLASH (2 Mana):                                     │   │
│  │   • Uses Accuracy modifier instead of WPM               │   │
│  │   • Win: ×1.15, opponent loses 1 Mana                   │   │
│  │   • Win vs streak: ×2.0                                 │   │
│  │   • Lose: ×0.85, you lose 1 Mana                        │   │
│  │   • Full Power: opponent loses 2 Mana                   │   │
│  │                                                          │   │
│  │  SOULBREAK (3 Mana):                                    │   │
│  │   • 8+ Mana: ×1.15 bonus                                │   │
│  │   • Win: steal 2 Mana (4 on full power)                │   │
│  │   • Lose: give 2 Mana to opponent                       │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ INNATE ABILITIES (apply after damage):                  │   │
│  │                                                          │   │
│  │  RIVEN - Bloodlust:                                     │   │
│  │   • Take 3 HP self-damage when dealing damage           │   │
│  │   • Skip self-damage if on 2-win streak (resets)       │   │
│  │                                                          │   │
│  │  LIORA - Grace:                                         │   │
│  │   • Heal 3 HP if accuracy > 95%                         │   │
│  │   • Max 15 HP healing per match                         │   │
│  │                                                          │   │
│  │  ZEPHON - Overdrive:                                    │   │
│  │   • +5 bonus damage if Mana ≥ 9 (before skill spend)   │   │
│  │   • +1 extra Mana per accurate word if WPM > 80        │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ APPLY DAMAGE & UPDATE STATE:                            │   │
│  │  • Deduct HP from loser                                 │   │
│  │  • Update win streaks                                   │   │
│  │  • Sync HP to server (host authoritative)              │   │
│  │  • Play combat animations                               │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    VICTORY CHECK                                 │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Did anyone reach 0 HP?                                  │   │
│  └─────────────────────────────────────────────────────────┘   │
│     ↓ YES                              ↓ NO                     │
│  ┌────────────────────┐         ┌──────────────────────────┐   │
│  │ GAME OVER          │         │ Increment round counter  │   │
│  │ • Show victory     │         │ Return to SKILL SELECT   │   │
│  │ • Save match       │         │ (Round Loop continues)   │   │
│  │ • Return to menu   │         └──────────────────────────┘   │
│  └────────────────────┘                                         │
└─────────────────────────────────────────────────────────────────┘
```

## Special Cases & Edge Conditions

### Forfeit Handling

```
┌─────────────────────────────────────────────────────────────────┐
│                      FORFEIT SCENARIOS                           │
│                                                                  │
│  LOBBY FORFEIT (before game starts):                            │
│   • Host leaves → Room deleted, no penalty                      │
│   • Guest leaves → Guest slot cleared, no penalty               │
│   • Applies to BOTH custom rooms and matchmaking                │
│                                                                  │
│  MID-GAME FORFEIT (after game starts):                          │
│   • Player presses ESC → Pause menu → "Forfeit & Leave"        │
│   • OR player disconnects for 35+ seconds                       │
│   • Forfeiter:                                                  │
│     - Match saved as loss (forfeit: "self")                     │
│     - 60-second matchmaking penalty (matchmaking only)          │
│     - Return to main menu                                       │
│   • Remaining player:                                           │
│     - Match saved as win (forfeit: "opponent")                  │
│     - No penalty                                                │
│     - Victory screen shown                                      │
│                                                                  │
│  DISCONNECT DETECTION:                                          │
│   • 15s no poll → Mark as "suspected offline"                   │
│   • 35s no poll → Auto-forfeit triggered                        │
│   • Per-player tracking (not shared last_activity_at)          │
└─────────────────────────────────────────────────────────────────┘
```

### Matchmaking Lobby Leave

```
┌─────────────────────────────────────────────────────────────────┐
│              MATCHMAKING LOBBY LEAVE DETECTION                   │
│                                                                  │
│  SCENARIO: Players matched, in 15s lobby countdown              │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Opponent leaves before game starts?                     │   │
│  └─────────────────────────────────────────────────────────┘   │
│           ↓ YES                              ↓ NO               │
│  ┌──────────────────────┐         ┌──────────────────────┐     │
│  │ Remaining player:    │         │ Both players ready   │     │
│  │ • See "Opponent      │         │ • Game starts        │     │
│  │   Left" popup (3s)   │         │ • Load game scene    │     │
│  │ • Return to menu     │         └──────────────────────┘     │
│  │ • No penalty         │                                       │
│  │ • Auto-requeue       │                                       │
│  │   enabled            │                                       │
│  └──────────────────────┘                                       │
│           ↓                                                     │
│  ┌──────────────────────┐                                       │
│  │ Leaver:              │                                       │
│  │ • 10-second penalty  │                                       │
│  │ • Return to menu     │                                       │
│  └──────────────────────┘                                       │
└─────────────────────────────────────────────────────────────────┘
```

### Accuracy Warning System

```
┌─────────────────────────────────────────────────────────────────┐
│                   ACCURACY WARNING FLOW                          │
│                                                                  │
│  During typing phase:                                           │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Check: correct_letters / sentence_length < 60%?         │   │
│  └─────────────────────────────────────────────────────────┘   │
│           ↓ YES                              ↓ NO               │
│  ┌──────────────────────┐         ┌──────────────────────┐     │
│  │ Show red warning     │         │ Hide warning         │     │
│  │ "Accuracy too low!"  │         │ Normal display       │     │
│  │ Clamp progress to    │         └──────────────────────┘     │
│  │ 98% (visual only)    │                                       │
│  └──────────────────────┘                                       │
│           ↓                                                     │
│  ┌──────────────────────┐                                       │
│  │ Player finishes?     │                                       │
│  └──────────────────────┘                                       │
│           ↓ YES                                                 │
│  ┌──────────────────────┐                                       │
│  │ Skill cancelled      │                                       │
│  │ Mana NOT refunded    │                                       │
│  │ (mana only from      │                                       │
│  │  accurate words)     │                                       │
│  └──────────────────────┘                                       │
└─────────────────────────────────────────────────────────────────┘
```

## Network Synchronization

### Server-Authoritative State

```
┌─────────────────────────────────────────────────────────────────┐
│                  SERVER STATE (Authoritative)                    │
│                                                                  │
│  Room State:                                                    │
│   • phase: "lobby" | "skill_select" | "typing" | "finished"    │
│   • phase_started_at: Unix timestamp (ms)                       │
│   • typing_started_at: Unix timestamp (ms)                      │
│   • first_finish_at: Unix timestamp (ms)                        │
│   • first_finish_by: "host" | "guest" | null                   │
│   • round_id: Current round number                              │
│                                                                  │
│  Player State (per player):                                     │
│   • progress: 0.0 to 1.0 (sentence completion)                  │
│   • typos: Integer count                                        │
│   • mana: 0 to 10                                               │
│   • typing_start: Unix timestamp when first keystroke          │
│   • mutations: Array of pending mutations for opponent          │
│   • skill: Chosen skill ID                                      │
│   • hp: Current HP                                              │
│                                                                  │
│  Presence Tracking:                                             │
│   • host_last_seen_at: Last poll timestamp                      │
│   • guest_last_seen_at: Last poll timestamp                     │
│   • disconnect.host_suspect_at: Suspect offline timestamp       │
│   • disconnect.guest_suspect_at: Suspect offline timestamp      │
└─────────────────────────────────────────────────────────────────┘
```

### Client Polling & Sync

```
┌─────────────────────────────────────────────────────────────────┐
│                    CLIENT SYNC PATTERN                           │
│                                                                  │
│  POLLING (every 0.5s):                                          │
│   • GET /api/rooms/:code                                        │
│   • Receive: phase, timers, opponent state, mutations           │
│   • Update local state from server                              │
│   • Detect phase transitions                                    │
│   • Apply opponent mutations to sentence                        │
│                                                                  │
│  PROGRESS SYNC (every 0.5s during typing):                      │
│   • PATCH /api/rooms/:code/progress                             │
│   • Send: progress, typos, mana, chosen_skill, mutations        │
│   • Server stores and broadcasts to opponent                    │
│                                                                  │
│  IMMEDIATE SYNC (on finish):                                    │
│   • PATCH /api/rooms/:code/progress (bypass throttle)           │
│   • Ensures opponent sees finish immediately                    │
│                                                                  │
│  HP SYNC (host only, after each round):                         │
│   • PATCH /api/rooms/:code/hp                                   │
│   • Send: host_hp, guest_hp                                     │
│   • Guest reads from poll response                              │
│                                                                  │
│  PHASE SYNC (host only):                                        │
│   • PATCH /api/rooms/:code/phase                                │
│   • Transitions: skill_select → typing → skill_select          │
│   • Guest follows server phase                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Key Decision Points Summary

1. **Can afford skill?** → Check mana vs skill cost
2. **Met 60% accuracy?** → Check correct_letters / sentence_length
3. **Finished typing?** → Check progress >= 100%
4. **Finished first?** → Compare timestamps, award +2 mana bonus
5. **Opponent finished in 10s?** → Determines buff/debuff vs full_power
6. **HP reached 0?** → Trigger victory/defeat
7. **Player disconnected?** → 15s suspect, 35s auto-forfeit
8. **Lobby opponent left?** → Show popup, no penalty for remaining player
9. **Forfeit mid-game?** → 60s penalty (matchmaking only), save match history

## Match Length

- **Target:** 3-7 rounds (average ~4 rounds)
- **Per Round:** ~70-80 seconds (10s skill + 60s typing + resolution)
- **Total Match:** ~5-9 minutes
