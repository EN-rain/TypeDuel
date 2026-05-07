extends Node

## SkillsManager — All combat math, skill resolution, and passive effects.

signal skill_activated(skill_name: String)

# ─────────────────────────────────────────────
#  Constants
# ─────────────────────────────────────────────

const SKILL_COSTS = {
	"quickslash": 2,
	"whiplash":   2,
	"soulbreak":  3
}

# ─────────────────────────────────────────────
#  Per-Match State  (reset each match)
# ─────────────────────────────────────────────

var player_mana:   int = 0
var opponent_mana: int = 0

var player_win_streak:   int = 0
var opponent_win_streak: int = 0

var liora_heal_total: float = 0.0      # Liora heal cap for player (max 15HP per match)
var liora_opp_heal_total: float = 0.0  # Liora heal cap for opponent (max 15HP per match)

## Skills equipped in the class-selection screen (up to 2 slots)
var selected_skills: Array[String] = []
var selected_passive: String = ""
var phantom_stack: int = 0

# ─────────────────────────────────────────────
#  Public helpers
# ─────────────────────────────────────────────

func can_pick_skill(skill_id: String, is_opponent: bool = false) -> bool:
	var mana = opponent_mana if is_opponent else player_mana
	return mana >= SKILL_COSTS.get(skill_id, 0)

func toggle_skill(skill_name: String) -> void:
	if selected_skills.has(skill_name):
		selected_skills.erase(skill_name)
	else:
		if selected_skills.size() < 2:
			selected_skills.append(skill_name)
	skill_activated.emit(skill_name)

func reset_match() -> void:
	player_mana         = 2
	opponent_mana       = 2
	player_win_streak   = 0
	opponent_win_streak = 0
	liora_heal_total     = 0.0
	liora_opp_heal_total = 0.0
	phantom_stack       = 0

## Called after every accurately-typed word during the typing phase.
## wpm = player's rolling WPM at that moment (for Zephon passive).
func on_accurate_word(wpm: float) -> void:
	var old_mana = player_mana
	player_mana = min(10, player_mana + 1)
	# Zephon innate: extra +1 Mana when WPM > 80
	if HPManager.player_innate == "Overdrive" and wpm > 80.0:
		player_mana = min(10, player_mana + 1)
		print("[Mana] Accurate word (Overdrive WPM>80): %d → %d" % [old_mana, player_mana])
	elif player_mana != old_mana:
		print("[Mana] Accurate word: %d → %d" % [old_mana, player_mana])

## Award the +2 Mana bonus for finishing the sentence first.
func on_finish_first() -> void:
	player_mana = min(10, player_mana + 2)
	print("[Mana] Finished 1st! +2 bonus → %d Mana" % player_mana)

func on_opponent_accurate_word() -> void:
	var old_mana = opponent_mana
	opponent_mana = min(10, opponent_mana + 1)
	# Zephon innate: extra +1 Mana when opponent WPM > 80 (estimated via progress)
	if HPManager.opponent_innate == "Overdrive":
		opponent_mana = min(10, opponent_mana + 1)
		if opponent_mana != old_mana:
			print("[Mana] Opponent word (Overdrive): %d → %d" % [old_mana, opponent_mana])
	elif opponent_mana != old_mana:
		print("[Mana] Opponent word: %d → %d" % [old_mana, opponent_mana])

func on_opponent_finish_first() -> void:
	opponent_mana = min(10, opponent_mana + 2)
	print("[Mana] Opponent finished 1st! +2 bonus → %d Mana" % opponent_mana)

# ─────────────────────────────────────────────
#  Round Resolution
# ─────────────────────────────────────────────
##
## finish_mode values:
##   "buff"       — you finished 1st; opponent also finished within 10 s
##   "debuff"     — you finished 2nd; opponent finished 1st (both fired)
##   "full_power" — you finished 1st; opponent did NOT finish (2× debuff magnitude)
##   "no_attack"  — 60 s expired; nobody finished
##   "tie"        — both finished at the same instant
##
## Returns { player_damage, player_hp_delta, opp_hp_delta, log }
func resolve_round(
		wpm:          float,
		accuracy:     float,
		typos:        int,
		_opp_typos:    int,
		finish_mode:  String,
		chosen_skill: String,
		_opp_hp:       float,
		_player_hp:    float,
		actor_role:    String = "player") -> Dictionary:

	var combat_log: Array[String] = []
	var player_damage:   float = 0.0
	var player_hp_delta: float = 0.0
	var opp_hp_delta:    float = 0.0

	var wpm_mod:      float = (wpm      - 40.0) / 100.0
	var acc_mod:      float = (accuracy - 80.0) / 100.0
	var typo_penalty: float = float(typos) * 2.0
	var char_base:    float = HPManager.player_base_dmg if actor_role == "player" else HPManager.opponent_base_dmg

	var won:        bool = finish_mode in ["buff", "full_power", "tie"]
	var full_power: bool = (finish_mode == "full_power")

	combat_log.append("=== [%s] ROUND RESOLVE [%s] ===" % [actor_role.to_upper(), finish_mode.to_upper()])
	combat_log.append("WPM:%.0f mod:+%.2f | Acc:%.1f%% mod:+%.2f | Typos:%d penalty:%.0f | Base DMG:%.0f"
		% [wpm, wpm_mod, accuracy, acc_mod, typos, typo_penalty, char_base])

	# ── Timeout: nobody finished (60s) ────────────────
	if finish_mode == "no_attack":
		player_hp_delta -= 5.0
		combat_log.append("[Timeout] -5HP. No damage dealt.")
		return _result(0.0, -5.0, 0.0, combat_log)

	# ── DNF: Failed to finish within opponent's 10s snap ──
	if finish_mode == "dnf":
		combat_log.append("[DNF] Actor did not finish. 0 DMG.")
		return _result(0.0, 0.0, 0.0, combat_log)

	# ── Spend Mana (only if a skill was picked AND actor can afford it) ───────
	# Snapshot mana BEFORE spending so Overdrive can check pre-spend value
	var mana_before_spend: int = player_mana if actor_role == "player" else opponent_mana
	if chosen_skill != "":
		var cost: int = int(SKILL_COSTS.get(chosen_skill, 0))
		var current_mana: int = player_mana if actor_role == "player" else opponent_mana
		if current_mana < cost:
			# Not enough mana — cancel the skill silently and treat as no-skill round.
			combat_log.append("[Mana] BLOCKED '%s' — need %d, have %d. Falling back to no-skill." % [chosen_skill, cost, current_mana])
			chosen_skill = ""
		else:
			if actor_role == "player":
				player_mana = max(0, player_mana - cost)
				combat_log.append("[Mana] Spent %d on '%s' → %d remaining" % [cost, chosen_skill, player_mana])
			else:
				opponent_mana = max(0, opponent_mana - cost)
				combat_log.append("[Mana] Opponent spent %d on '%s' → %d remaining" % [cost, chosen_skill, opponent_mana])

	# ── Debuff case: refund Mana if opponent didn't finish ─
	# P2 who did NOT finish → Mana refunded (handled by caller marking finish_mode="debuff"
	# with a flag; full refund happens only on full_power for the WINNER side)

	# ── Skill damage calculation ──────────────────────
	if chosen_skill == "":
		if won:
			player_damage = maxf(0.0, ceil(char_base * (1.0 + wpm_mod) - typo_penalty))
			combat_log.append("[No Skill] Won → base only: %.0f DMG" % player_damage)
		else:
			combat_log.append("[No Skill] Lost → 0 DMG (full opponent DMG + full debuffs hit you)")
	else:
		match chosen_skill:
			"quickslash":
				player_damage = _quickslash(wpm_mod, typo_penalty, won, full_power, char_base, combat_log, actor_role)
			"whiplash":
				player_damage = _whiplash(acc_mod, typo_penalty, won, full_power, char_base, combat_log, actor_role)
			"soulbreak":
				player_damage = _soulbreak(wpm_mod, typo_penalty, won, full_power, char_base, combat_log, actor_role)
		player_damage = maxf(0.0, player_damage)

	# ── Win-streak tracking ───────────────────────────
	# NOTE: streaks are updated BEFORE innate abilities so Bloodlust can read
	# the freshly-incremented streak value (fix #5).
	if won:
		if actor_role == "player":
			player_win_streak   += 1
			opponent_win_streak  = 0
		else:
			opponent_win_streak += 1
			player_win_streak   = 0
	else:
		if actor_role == "player":
			opponent_win_streak += 1
			player_win_streak    = 0
		else:
			player_win_streak    += 1
			opponent_win_streak   = 0
	combat_log.append("[Streak] Player: %d | Opponent: %d" % [player_win_streak, opponent_win_streak])

	# ── Character Innate Abilities ────────────────────────────
	var innate = HPManager.player_innate if actor_role == "player" else HPManager.opponent_innate
	match innate:

		"Bloodlust":  # Riven — -3HP self when dealing damage; skip on the 2nd consecutive win, then reset
			# Use the actor's own streak (player_win_streak for player, opponent_win_streak for opponent)
			var actor_streak = player_win_streak if actor_role == "player" else opponent_win_streak
			if player_damage > 0.0:
				if actor_streak == 2:
					if actor_role == "player": player_win_streak = 0
					else: opponent_win_streak = 0
					combat_log.append("[Innate Ability: Bloodlust] 2-win streak! Self-damage skipped. Streak reset.")
				else:
					player_hp_delta -= 3.0
					combat_log.append("[Innate Ability: Bloodlust] Dealt DMG → -3HP self-damage (streak: %d)" % actor_streak)

		"Grace":  # Liora — +3HP heal if accuracy > 95%; capped at 15HP total per actor
			# Use separate heal caps for player and opponent
			var heal_total = liora_heal_total if actor_role == "player" else liora_opp_heal_total
			if accuracy > 95.0 and heal_total < 15.0:
				var heal := minf(3.0, 15.0 - heal_total)
				player_hp_delta += heal
				if actor_role == "player": liora_heal_total += heal
				else: liora_opp_heal_total += heal
				combat_log.append("[Innate Ability: Grace] Acc > 95%% → +%.0fHP (total: %.0f/15)" % [heal, heal_total + heal])

		"Overdrive":  # Zephon — +5 bonus damage when mana >= 9 (checked before skill spend)
			if mana_before_spend >= 9 and player_damage > 0.0:
				player_damage += 5.0
				combat_log.append("[Innate Ability: Overdrive] High Mana (%d before spend)! +5 bonus DMG → %.0f total" % [mana_before_spend, player_damage])

	combat_log.append("RESULT → DMG:%.0f | SelfHP:%+.0f | OppHP:%+.0f" % [player_damage, player_hp_delta, opp_hp_delta])
	return _result(player_damage, player_hp_delta, opp_hp_delta, combat_log)

# ─────────────────────────────────────────────
#  Skill Formulas
# ─────────────────────────────────────────────

## ⚡ Quickslash (2 Mana) — WPM-based
func _quickslash(wpm_mod: float, typo_penalty: float, won: bool, full_power: bool, base: float, combat_log: Array, actor_role: String = "player") -> float:
	var dmg := maxf(0.0, ceil(base * (1.0 + wpm_mod) - typo_penalty))
	var my_streak  = player_win_streak   if actor_role == "player" else opponent_win_streak
	var opp_streak = opponent_win_streak if actor_role == "player" else player_win_streak

	if won:
		if my_streak >= 1:
			dmg = ceil(dmg * 1.2)
			combat_log.append("[Quickslash] Win + streak → ×1.20 = %.0f" % dmg)
		else:
			dmg = ceil(dmg * 1.1)
			combat_log.append("[Quickslash] Win → ×1.10 = %.0f" % dmg)
		if full_power:
			dmg = ceil(dmg * 1.2)
			combat_log.append("[Quickslash] FULL POWER (opp didn't finish) → ×1.20 extra = %.0f" % dmg)
	else:
		if opp_streak >= 1:
			dmg = 0.0
			combat_log.append("[Quickslash] Lose on opp streak → 0 DMG")
		else:
			dmg = ceil(dmg * 0.9)
			combat_log.append("[Quickslash] Lose → ×0.90 = %.0f" % dmg)

	return dmg

## 🌪️ Whiplash (2 Mana) — Accuracy-based
func _whiplash(acc_mod: float, typo_penalty: float, won: bool, full_power: bool, base: float, combat_log: Array, actor_role: String) -> float:
	var dmg := maxf(0.0, ceil(base * (1.0 + acc_mod) - typo_penalty))
	# Streak from the loser's perspective (the one being hit).
	var loser_streak = opponent_win_streak if actor_role == "player" else player_win_streak

	if won:
		# ×2.0 bonus when the loser had a win streak (Whiplash punishes streaks)
		if loser_streak >= 1 and not full_power:
			dmg = ceil(dmg * 2.0)
			combat_log.append("[Whiplash] Win + loser streak → ×2.0 = %.0f" % dmg)
		else:
			dmg = ceil(dmg * 1.15)
			combat_log.append("[Whiplash] Win → ×1.15 = %.0f" % dmg)

		# Actor wins → target loses 1 Mana (2 on full_power)
		if actor_role == "player":
			opponent_mana = max(0, opponent_mana - 1)
			if full_power: opponent_mana = max(0, opponent_mana - 1)
		else:
			player_mana = max(0, player_mana - 1)
			if full_power: player_mana = max(0, player_mana - 1)
		combat_log.append("[Whiplash] Target lost %d Mana" % (2 if full_power else 1))
	else:
		dmg = ceil(dmg * 0.85)
		combat_log.append("[Whiplash] Lose → ×0.85 = %.0f" % dmg)
		# Actor loses → actor loses 1 Mana
		if actor_role == "player":
			player_mana = max(0, player_mana - 1)
		else:
			opponent_mana = max(0, opponent_mana - 1)
		combat_log.append("[Whiplash] Actor lost 1 Mana")

	return dmg

## 🔮 Soulbreak (3 Mana) — WPM-based
func _soulbreak(wpm_mod: float, typo_penalty: float, won: bool, full_power: bool, base: float, combat_log: Array, actor_role: String) -> float:
	var dmg := maxf(0.0, ceil(base * (1.0 + wpm_mod) - typo_penalty))

	var current_mana = player_mana if actor_role == "player" else opponent_mana
	if current_mana >= 8:
		dmg = ceil(dmg * 1.15)
		combat_log.append("[Soulbreak] 8+ Mana bonus → ×1.15 = %.0f" % dmg)

	if won:
		var steal := 2
		if full_power:
			steal = 4  # 2× magnitude
		if actor_role == "player":
			opponent_mana = max(0, opponent_mana - steal)
			player_mana   = min(10, player_mana   + steal)
		else:
			player_mana   = max(0, player_mana   - steal)
			opponent_mana = min(10, opponent_mana + steal)
		combat_log.append("[Soulbreak] Win → stole %d Mana" % steal)
	else:
		if actor_role == "player":
			opponent_mana = min(10, opponent_mana + 2)
			player_mana   = max(0,  player_mana   - 2)
		else:
			player_mana   = min(10, player_mana   + 2)
			opponent_mana = max(0,  opponent_mana   - 2)
		combat_log.append("[Soulbreak] Lose → gave 2 Mana")

	return dmg

# ─────────────────────────────────────────────
#  Utility
# ─────────────────────────────────────────────

func _result(dmg: float, php: float, ohp: float, combat_log: Array) -> Dictionary:
	return { "player_damage": dmg, "player_hp_delta": php, "opp_hp_delta": ohp, "log": combat_log }
