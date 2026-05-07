# TypeDuel - Game Design Document

## Overview
TypeDuel is a competitive, multiplayer typing game where players battle using their typing speed (WPM) and accuracy. Players select a Character, Active Skills, and Passive Abilities to out-type and outplay their opponents in round-based combat.

---

## 1. Characters & Base Stats
Each character has unique base stats and an **Innate Ability** that passively affects combat.

| Character | HP | Base DMG | Innate Ability | Description |
|-----------|----|----------|----------------|-------------|
| **Riven** | 85 | 22 | **Bloodlust** | High risk, high reward. Takes **3 HP self-damage** when dealing damage. If she hits a 2-win streak, the self-damage is skipped for that round and the streak resets. |
| **Liora** | 100| 16 | **Grace** | High survivability. Heals **3 HP** anytime her round accuracy is **>95%**. (Hard capped at 15 HP total per match). |
| **Zephon**| 85 | 20 | **Overdrive** | Mana-focused burst. Deals **+5 bonus damage** when Mana is **≥9** (checked before skill spend). Also gains **+1 extra Mana** per accurate word when WPM > 80. |

---

## 2. Combat System (Round Mechanics)
A match consists of multiple rounds (typically 3 to 7 rounds). During a round:
1. Both players receive the exact same target sentence.
2. Players type the sentence as fast and accurately as possible.
3. The winner of the round is determined by who finishes first (triggering the `buff` state) while the loser takes the `debuff` state. If both finish at the same instant, it's a `tie` (both deal damage).
4. If a player fails to finish before the time limit, they suffer a `no_attack` timeout penalty (-5 HP).
5. If a player finishes 1st but the opponent does NOT finish within 10s, the winner gets `full_power` (2× debuff magnitude).

### Damage Calculation
Final damage is calculated by modifying the character's Base DMG using the following:
* **WPM Modifier:** `(WPM - 40) / 100` → Rewards fast typing.
* **Accuracy Modifier:** `(Accuracy - 80) / 100` → Used by Whiplash instead of WPM.
* **Typo Penalty:** `-2 DMG per typo` → Heavily punishes errors.
* **Base Formula:** `CEIL(BaseDMG * (1 + modifier) - typos * 2)` → Applied to all skills.
* **Win Streak:** Successive round wins grant multiplier bonuses to skill damage.

---

## 3. Mana Economy
* Mana is the resource used to cast Active Skills.
* **+1 Mana** per every 2 accurately-typed words (0 typos in the word).
* **+2 Mana** bonus for finishing the sentence first.
* Zephon's Overdrive: **+1 extra Mana** per 2 accurate words when WPM > 80.
* Maximum Mana is capped at **10**.
* Players start each match with **2 Mana**.
* If a player attempts an attack but times out, their spent mana is refunded.

---

## 4. Active Skills
Players select skills before the match begins. Skills cost Mana to execute.

| Skill | Cost | Type | Description |
|-------|------|------|-------------|
| **Quickslash** | 2 Mana | Offensive | **WPM-based attack.** `CEIL(BaseDMG * (1 + WPM_mod) - typos*2)`. Win → `×1.1`. Win + streak → `×1.2`. Full power (opponent didn't finish) → additional `×1.2`. Lose → `×0.9`. Lose while opponent on streak → `0 DMG`. |
| **Whiplash** | 2 Mana | Counter | **Accuracy-based attack.** `CEIL(BaseDMG * (1 + Acc_mod) - typos*2)`. Win → `×1.15` + opponent loses 1 Mana. Win + opponent on streak → `×2.0`. Full power → opponent loses 2 Mana. Lose → `×0.85` + you lose 1 Mana. |
| **Soulbreak** | 3 Mana | Utility | **WPM-based mana stealer.** `CEIL(BaseDMG * (1 + WPM_mod) - typos*2)`. 8+ Mana → `×1.15` bonus. Win → steal 2 Mana from opponent (4 on full power). Lose → give 2 Mana to opponent. |

---

## 5. Passive Abilities
Passives are background effects that trigger automatically under specific conditions. They offer strategic advantages during the typing phase or combat resolution.

| Passive | Trigger Condition | Effect |
|---------|-------------------|--------|
| **Reversal** | You finish the sentence first | **Reverses the letters** of a random upcoming word in the opponent's sentence (e.g. "hello" → "olleh"). The word stays in its original position but is much harder to read. |
| **Jumble** | Your Mana ≥ 7 | **Shuffles the word order** of all remaining untyped words in the opponent's sentence. Triggers once per round. |
| **Phantom** | Round accuracy ≥ 85% (initial stack), ≥ 90% (growth) | **Swaps two random words** in the opponent's sentence per charge. Stacks up to 3 charges (1 at 85% acc, grows at 90%+ acc). All charges apply at round start. |
| **Stutter** | Opponent on a win streak | **Duplicates a random word** in the opponent's sentence (e.g. "the" → "the the"), forcing them to type it twice. Also triggers a second stutter effect after the next word boundary. |
| **Erosion** | 3 consecutive perfect words | **Replaces a random character** in one of the opponent's upcoming words with an underscore `_`, creating a blank they must guess. Triggers every 3rd consecutive perfect word. |

---

## 6. Balance & Simulation Metrics
The game's combat math is strictly balanced around an automated matrix of 2,025 permutations.
* **Target Match Length:** 3 to 7 Rounds (Average sits perfectly at ~4.0 rounds).
* **Win Rate Target:** ~50% normalized distribution across characters.
* **Typo Punishment:** Math heavily penalizes typos to prevent "mashing" strategies.
 