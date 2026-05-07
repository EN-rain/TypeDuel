# Debug Logs Guide - Testing the Flowchart

## Overview

Added strategic debug logs at key decision points in the gameplay flowchart. These logs are **non-spamming** - they only appear when important decisions are made or state changes occur.

## Log Categories

### 🎯 Decision Points (Prefix: `[Decision]`)

These logs show the outcome of key if/else branches in the flowchart:

| Log | When It Appears | What It Means |
|-----|----------------|---------------|
| `[Decision] ✓ Can afford skill 'X' (cost Y, have Z Mana)` | Player clicks skill button | Skill selection successful |
| `[Decision] ✗ Cannot afford skill 'X' (cost Y, have Z Mana)` | Player clicks skill button | Not enough mana |
| `[Decision] Finished typing \| Acc: X% \| Correct: Y/Z (need W)` | Player finishes sentence | Shows accuracy check data |
| `[Decision] ✓ Finished FIRST → +2 Mana bonus (now X)` | Player finishes before opponent | First finish bonus awarded |
| `[Decision] ✓ Finished SECOND → DEBUFF mode` | Player finishes after opponent | Debuff mode triggered |
| `[Decision] Starting 10s SNAP timer, waiting for opponent...` | First finisher waiting | Snap timer started |
| `[Decision] ✓ Both finished within 10s → BUFF mode` | Both finish in time | Normal buff/debuff resolution |
| `[Decision] ✗ We DNF (opponent finished, we didn't) → DNF mode` | Snap timer expires, we didn't finish | We get DNF penalty |
| `[Decision] ✓ Opponent DNF (we finished, they didn't) → FULL_POWER mode` | Snap timer expires, opponent didn't finish | We get full power bonus |
| `[Decision] ✗ 60s timer expired, neither finished → NO_ATTACK mode (-5 HP both)` | Round timer expires | Both players timeout |
| `[Decision] ✓ Skill 'X' validated — accuracy OK (Y/Z correct, need W)` | Skill passes 60% check | Skill will trigger |
| `[Decision] ✗ Skill 'X' cancelled — accuracy too low (Y/Z correct, need W) \| Mana LOST` | Skill fails 60% check | Skill cancelled, mana lost |
| `[Decision] Opponent DNF → opponent skill hidden in animation` | Full power mode | Opponent's skill won't show |
| `[Decision] We DNF → our skill hidden in animation` | DNF mode | Our skill won't show |
| `[Decision] ✓ Opponent finished FIRST → +2 Mana to opponent (now X)` | Opponent finishes first | Opponent gets bonus |

### 🎮 Phase Transitions (Prefix: `[Phase]`)

Shows when the game moves between phases:

| Log | When It Appears | What It Means |
|-----|----------------|---------------|
| `[Phase] SKILL SELECT \| round=X \| mana=Y \| opp_mana=Z \| skills=[...]` | Skill select phase starts | Shows current round and mana state |

### ⚔️ Combat Resolution (Prefix: `[Combat]`)

Shows combat calculation details:

| Log | When It Appears | What It Means |
|-----|----------------|---------------|
| `[Combat] Resolving \| Mode: X \| Our skill: Y \| Opp skill: Z` | Combat resolution starts | Shows finish mode and skills used |

### 🔄 Mana Synchronization (Prefix: `[ManaSync]`)

Shows when opponent mana changes (only logs changes, not every poll):

| Log | When It Appears | What It Means |
|-----|----------------|---------------|
| `[ManaSync] Opponent mana: X → Y` | Opponent's mana changes | Server synced new mana value |

## What You'll See During Testing

### Example: Normal Round (Both Finish)

```
[Phase] SKILL SELECT | round=1 | mana=2 | opp_mana=2 | skills=["whiplash", "soulbreak"]
[Decision] ✓ Can afford skill 'whiplash' (cost 2, have 2 Mana)
[Decision] Finished typing | Acc: 95.3% | Correct: 41/43 (need 26)
[Decision] ✓ Finished FIRST → +2 Mana bonus (now 4)
[Decision] Starting 10s SNAP timer, waiting for opponent...
[Decision] ✓ Both finished within 10s → BUFF mode
[Decision] ✓ Skill 'whiplash' validated — accuracy OK (41/43 correct, need 26)
[Combat] Resolving | Mode: buff | Our skill: whiplash | Opp skill: soulbreak
[ManaSync] Opponent mana: 4 → 3
```

### Example: Accuracy Too Low

```
[Decision] Finished typing | Acc: 55.8% | Correct: 24/43 (need 26)
[Decision] ✓ Finished FIRST → +2 Mana bonus (now 4)
[Decision] Starting 10s SNAP timer, waiting for opponent...
[Decision] ✓ Both finished within 10s → BUFF mode
[Decision] ✗ Skill 'whiplash' cancelled — accuracy too low (24/43 correct, need 26) | Mana LOST
[Combat] Resolving | Mode: buff | Our skill: none | Opp skill: soulbreak
```

### Example: Opponent DNF (Full Power)

```
[Decision] Finished typing | Acc: 92.1% | Correct: 39/43 (need 26)
[Decision] ✓ Finished FIRST → +2 Mana bonus (now 6)
[Decision] Starting 10s SNAP timer, waiting for opponent...
[Decision] ✓ Opponent DNF (we finished, they didn't) → FULL_POWER mode
[Decision] ✓ Skill 'soulbreak' validated — accuracy OK (39/43 correct, need 26)
[Decision] Opponent DNF → opponent skill hidden in animation
[Combat] Resolving | Mode: full_power | Our skill: soulbreak | Opp skill: none
```

### Example: We DNF

```
[Decision] ✓ Opponent finished FIRST → +2 Mana to opponent (now 4)
[Decision] ✗ We DNF (opponent finished, we didn't) → DNF mode
[Decision] We DNF → our skill hidden in animation
[Combat] Resolving | Mode: dnf | Our skill: none | Opp skill: whiplash
```

### Example: Both Timeout

```
[Decision] ✗ 60s timer expired, neither finished → NO_ATTACK mode (-5 HP both)
[Combat] Resolving | Mode: no_attack | Our skill: none | Opp skill: none
```

### Example: Mana Sync After Skill

```
[Combat] Resolving | Mode: buff | Our skill: whiplash | Opp skill: soulbreak
[ManaSync] Opponent mana: 6 → 5
```
(Opponent lost 1 mana from Whiplash)

## Log Symbols

- ✓ = Success / Positive outcome
- ✗ = Failure / Negative outcome / Penalty

## What NOT to Expect (No Spam)

These logs will **NOT** appear:
- ❌ Every frame during typing
- ❌ Every progress sync (every 0.5s)
- ❌ Every poll (every 0.5s)
- ❌ Every keystroke
- ❌ Repeated mana values (only changes)

## Testing Checklist

Use these logs to verify each flowchart decision point:

### ✅ Skill Selection Phase
- [ ] Can afford skill → See `✓ Can afford` log
- [ ] Cannot afford skill → See `✗ Cannot afford` log
- [ ] Mana values shown correctly in phase start log

### ✅ Typing Phase
- [ ] Finish first → See `✓ Finished FIRST` with +2 mana
- [ ] Finish second → See `✓ Finished SECOND`
- [ ] Opponent finishes first → See `✓ Opponent finished FIRST`
- [ ] Accuracy check shown when finishing

### ✅ Snap Timer
- [ ] Both finish in 10s → See `✓ Both finished within 10s → BUFF mode`
- [ ] Opponent DNF → See `✓ Opponent DNF → FULL_POWER mode`
- [ ] We DNF → See `✗ We DNF → DNF mode`

### ✅ Timeout
- [ ] 60s expires → See `✗ 60s timer expired → NO_ATTACK mode`

### ✅ Accuracy Validation
- [ ] 60%+ accuracy → See `✓ Skill validated`
- [ ] <60% accuracy → See `✗ Skill cancelled — accuracy too low | Mana LOST`

### ✅ Combat Resolution
- [ ] Combat starts → See `[Combat] Resolving` with mode and skills
- [ ] DNF player's skill hidden → See `skill hidden in animation`

### ✅ Mana Sync
- [ ] Opponent mana changes → See `[ManaSync] Opponent mana: X → Y`
- [ ] After mana-stealing skills (Whiplash, Soulbreak) → See mana change log

## Summary

These logs follow the flowchart exactly, showing:
1. **Phase transitions** - When game state changes
2. **Decision outcomes** - Results of if/else branches
3. **Mana changes** - Server sync verification
4. **Combat resolution** - What skills are used

Use them to verify the implementation matches the flowchart in `GAMEPLAY_FLOWCHART.md`!
