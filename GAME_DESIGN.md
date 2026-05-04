# TypeDuel - Game Design Document

## Overview
TypeDuel is a competitive, multiplayer typing game where players battle using their typing speed (WPM) and accuracy. Players select a Character, Active Skills, and Passive Abilities to out-type and outplay their opponents in round-based combat.

---

## 1. Characters & Base Stats
Each character has unique base stats and an **Innate Ability** that passively affects combat.

| Character | HP | Base DMG | Innate Ability | Description |
|-----------|----|----------|----------------|-------------|
| **Riven** | 85 | 22 | **Bloodlust** | High risk, high reward. Takes **2 HP self-damage** when dealing damage. If she hits a 2-win streak, the self-damage is skipped for that round and the streak resets. |
| **Liora** | 100| 16 | **Grace** | High survivability. Heals **3 HP** anytime her round accuracy is **>97%**. (Hard capped at 15 HP total per match). |
| **Zephon**| 85 | 20 | **Overdrive** | Mana-focused burst. Deals a massive **+5 bonus damage** anytime his Mana pool reaches **9 or higher**. |

---

## 2. Combat System (Round Mechanics)
A match consists of multiple rounds (typically 3 to 7 rounds). During a round:
1. Both players receive the exact same target sentence.
2. Players type the sentence as fast and accurately as possible.
3. The winner of the round is determined by who finishes first (triggering the `buff` state) while the loser takes the `debuff` state. 
4. If a player fails to finish before the time limit, they suffer a `no_attack` timeout penalty (-5 HP).

### Damage Calculation
Final damage is calculated by modifying the character's Base DMG using the following:
* **WPM Modifier:** `(WPM - 40) / 100` -> Rewards fast typing.
* **Accuracy Modifier:** `(Accuracy - 80) / 100` -> Punishes poor accuracy.
* **Typo Penalty:** `-2 DMG per typo` -> Heavily punishes errors.
* **Win Streak:** Successive round wins grant multiplier bonuses to skill damage.

---

## 3. Mana Economy
* Mana is the resource used to cast Active Skills. 
* Players generate mana throughout the match based on performance (accuracy and WPM). 
* Maximum Mana is capped at **10**.
* If a player attempts an attack but times out, their spent mana is refunded.

---

## 4. Active Skills
Players select skills before the match begins. Skills cost Mana to execute.

| Skill | Cost | Description |
|-------|------|-------------|
| **Quickslash** | 2 Mana | **Speed-focused attack.** Damage scales heavily with WPM. Gains a `1.1x` multiplier on win, or `1.2x` on a win-streak. If the opponent times out, it deals `1.2x` full-power damage. Misses completely (`0 DMG`) if the opponent is on a win-streak. |
| **Whiplash** | 2 Mana | **Accuracy-focused attack.** Damage scales with Accuracy rather than WPM. Excellent for careful, precise typists. Modifiers function similarly to Quickslash but scale differently. |
| **Soulbreak** | 3 Mana | **Heavy finisher.** High cost, high damage. Scales with WPM but has higher base damage calculation multipliers. |

---

## 5. Passive Abilities
Passives are background effects that trigger automatically under specific conditions. They offer strategic advantages during the typing phase or combat resolution.

| Passive | Trigger Condition | Effect |
|---------|-------------------|--------|
| **Reversal** | WPM > Opponent's WPM | Triggers when you type faster than the opponent. Useful for turning the tide of momentum. |
| **Jumble** | Mana ≥ 7 | Alters or obfuscates the opponent's upcoming word when you reach high mana reserves. |
| **Phantom** | Accuracy ≥ 85% | Stacks a phantom charge (up to 3). Provides defensive or offensive utility based on consistent accuracy. |
| **Stutter** | Opponent on Win Streak | Triggers a visual or physical disruption on the opponent's next word if they are on a hot streak. |
| **Erosion** | 0 Typos in a round | Rewards flawless typing by applying pressure or bonus effects to the opponent. |

---

## 6. Balance & Simulation Metrics
The game's combat math is strictly balanced around an automated matrix of 2,025 permutations.
* **Target Match Length:** 3 to 7 Rounds (Average sits perfectly at ~4.0 rounds).
* **Win Rate Target:** ~50% normalized distribution across characters.
* **Typo Punishment:** Math heavily penalizes typos to prevent "mashing" strategies.
