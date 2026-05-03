extends Node

## SkillsManager - Global Singleton
## Handles all skill damage formulas, status effects, and round resolution.

signal skill_activated(skill_name: String)
signal status_applied(target: String, effect: Dictionary)

# ─────────────────────────────────────────────
#  State
# ─────────────────────────────────────────────

var selected_skills: Array[String] = []

# Per-round trackers (reset each round)
var player_win_streak:    int = 0
var opponent_win_streak:  int = 0

# Carry-over modifiers (persist across rounds)
var player_next_round_base_modifier:   float = 1.0
var opponent_next_round_base_modifier: float = 1.0

# Bleed / Heal / Mark stacks  { "rounds": int, "value": float }
var player_bleed:    Dictionary = {}
var opponent_bleed:  Dictionary = {}
var player_heal:     Dictionary = {}
var player_mark:     Dictionary = {}
var opponent_mark:   Dictionary = {}

# CP (Combo Points)
var player_cp:    int = 0
var opponent_cp:  int = 0

const MAX_HP: int = 100


# ─────────────────────────────────────────────
#  Public API
# ─────────────────────────────────────────────

func toggle_skill(skill_name: String) -> void:
	if selected_skills.has(skill_name):
		selected_skills.erase(skill_name)
		print("[SkillsManager] Removed: ", skill_name)
	else:
		if selected_skills.size() < 2:
			selected_skills.append(skill_name)
			print("[SkillsManager] Added: ", skill_name)
		else:
			print("[SkillsManager] Max skills reached (2)")
	
	skill_activated.emit(skill_name)


## Main entry point called after each typing round.
##   wpm       – player's words-per-minute this round
##   accuracy  – player's accuracy this round (0–100)
##   typos     – player's typo count this round
##   opp_typos – opponent's typo count this round
##   won       – did the player win this round?
##   opp_hp    – opponent's current HP (needed for conditional bonuses)
##   player_hp – player's current HP (needed for bleed/heal caps)
##   chosen_skill – the skill activated this round
##
## Returns a Dictionary:
##   { "player_damage": float, "opp_damage": float,
##     "player_hp_delta": float, "opp_hp_delta": float,
##     "log": Array[String] }
func resolve_round(
		wpm: float, accuracy: float, typos: int, opp_typos: int,
		won: bool,
		opp_hp: float, player_hp: float,
		chosen_skill: String = "") -> Dictionary:

	var log: Array[String] = []
	var player_damage: float = 0.0
	var opp_damage:    float = 0.0   # damage the opponent deals to us (status only)
	var player_hp_delta: float = 0.0
	var opp_hp_delta:    float = 0.0

	# ── Modifiers ────────────────────────────
	var wpm_mod:      float = (wpm - 40.0) / 200.0
	var acc_mod:      float = (accuracy - 80.0) / 200.0
	var typo_penalty: float = typos * 0.5

	# ── Apply carry-over base modifier ───────
	var base_multiplier: float = player_next_round_base_modifier
	player_next_round_base_modifier = 1.0   # reset after use

	# ── Tick status effects first ─────────────
	var status_result := _tick_status_effects(player_hp, opp_hp)
	player_hp_delta += status_result.player_hp_delta
	opp_hp_delta    += status_result.opp_hp_delta
	log.append_array(status_result.log)
	
	# ── Apply Base Damage ────────────────────────
	if won:
		player_damage += HPManager.player_base_dmg * base_multiplier
	
	# ── Evaluate Player Passives ─────────────────
	match HPManager.player_passive:
		"Overdrive": # Zephon
			if wpm > 80:
				player_mana = min(10, player_mana + 1)
				log.append("[Passive: Overdrive] WPM > 80, gained 1 Mana!")
		"Bloodlust": # Riven
			if won:
				player_win_streak += 1
			else:
				player_win_streak = 0
			if player_win_streak >= 2:
				log.append("[Passive: Bloodlust] 2 wins! Paused 3HP self-damage.")
			else:
				player_hp_delta -= 3
				log.append("[Passive: Bloodlust] Took 3 self-damage.")
		"Survivor": # Caelum
			if player_hp < HPManager.player_max_hp * 0.4:
				player_damage += 3
				log.append("[Passive: Survivor] Low HP, +3 DMG!")
		"Equilibrium": # Nyxara
			player_damage *= 1.1 # simplified for odd round
			log.append("[Passive: Equilibrium] +10% DMG!")
		"Tactician": # Valdris
			if won:
				player_mana = min(10, player_mana + 1)
				log.append("[Passive: Tactician] Won round, +1 Mana!")
		"Grace": # Liora
			if accuracy > 80.0:
				player_hp_delta += 3
				log.append("[Passive: Grace] Accuracy > 80%, Healed 3HP!")
		"Vengeance": # Malachar
			if opp_damage > 0: # simplifed
				HPManager.player_base_dmg += 2
				log.append("[Passive: Vengeance] Took damage, gained +2 permanent DMG!")

	# ── Resolve skill ─────────────────────────
	var char_base = HPManager.player_base_dmg
	if chosen_skill != "":
		match chosen_skill:
			"quick_strike":
				var result := _quick_strike(wpm_mod, typo_penalty, won, base_multiplier, char_base)
				player_damage += result.damage
				log.append_array(result.log)

			"drain_touch":
				var result := _drain_touch(wpm_mod, typo_penalty, won, base_multiplier, opp_hp, char_base)
				player_damage      += result.damage
				player_hp_delta   += result.player_hp_delta
				opp_hp_delta      += result.opp_hp_delta
				log.append_array(result.log)

			"whiplash":
				var result := _whiplash(acc_mod, typo_penalty, won, base_multiplier, char_base)
				player_damage += result.damage
				if won:
					opponent_mana = max(0, opponent_mana - 1)
					log.append("[Whiplash] Opponent lost 1 Mana → now %d Mana" % opponent_mana)
				else:
					player_mana = max(0, player_mana - 1)
					log.append("[Whiplash] You lost 1 Mana → now %d Mana" % player_mana)
				log.append_array(result.log)

			"soulbreak":
				var result := _soulbreak(wpm_mod, typo_penalty, won, base_multiplier, char_base)
				player_damage += result.damage
				if won:
					var stolen := 2
					opponent_mana = max(0, opponent_mana - stolen)
					player_mana = min(10, player_mana + stolen)
					log.append("[Soulbreak] Stole %d Mana! You: %d | Opp: %d" % [stolen, player_mana, opponent_mana])
				log.append_array(result.log)

			"rupture":
				var result := _rupture(opp_typos, typo_penalty, won, base_multiplier, char_base)
				player_damage += result.damage
				if won:
					opponent_next_round_base_modifier = 0.8
					log.append("[Rupture] Opponent's next round base -20%")
				else:
					player_next_round_base_modifier = 0.8
					log.append("[Rupture] Your next round base -20%")
				log.append_array(result.log)

			"deathmark":
				var result := _deathmark(typo_penalty, won, base_multiplier, opp_hp, char_base)
				player_damage  += result.damage
				opp_hp_delta  += result.opp_hp_delta
				log.append_array(result.log)

	# ── Apply mark flat damage ────────────────
	if won and not opponent_mark.is_empty():
		var mark_dmg: float = opponent_mark.get("value", 2.0)
		player_damage += mark_dmg
		log.append("[Mark] +%.1f flat damage from mark" % mark_dmg)

	if not player_mark.is_empty():
		opp_damage += player_mark.get("value", 2.0)
		log.append("[Mark] Opponent's mark deals %.1f to you" % opp_damage)

	# ── Win streak tracking ───────────────────
	if won:
		player_win_streak   += 1
		opponent_win_streak  = 0
	else:
		opponent_win_streak += 1
		player_win_streak    = 0

	log.append("Round result | Player dmg: %.1f | Self HP delta: %.1f | Opp HP delta: %.1f"
		% [player_damage, player_hp_delta, opp_hp_delta])

	return {
		"player_damage":   player_damage,
		"opp_damage":      opp_damage,
		"player_hp_delta": player_hp_delta,
		"opp_hp_delta":    opp_hp_delta,
		"log":             log
	}


func reset_round_state() -> void:
	player_win_streak   = 0
	opponent_win_streak = 0
	player_mana         = 0
	opponent_mana       = 0
	player_bleed        = {}
	opponent_bleed      = {}
	player_heal         = {}
	player_mark         = {}
	opponent_mark       = {}
	player_next_round_base_modifier   = 1.0
	opponent_next_round_base_modifier = 1.0


# ─────────────────────────────────────────────
#  Skill Implementations
# ─────────────────────────────────────────────

func _quick_strike(wpm_mod: float, typo_penalty: float, won: bool, base_mult: float, char_base: float) -> Dictionary:
	var log: Array[String] = []
	var base: float = char_base * (1.0 + wpm_mod) * base_mult - typo_penalty
	var damage: float = base

	if won:
		if player_win_streak >= 1:
			damage *= 1.2
			log.append("[Quick Strike] Win Streak! ×1.20 → %.1f" % damage)
		else:
			damage *= 1.1
			log.append("[Quick Strike] Win ×1.10 → %.1f" % damage)
	else:
		if opponent_win_streak >= 1:
			damage = 0.0
			log.append("[Quick Strike] Loss on streak → 0 dmg")
		else:
			damage *= 0.9
			log.append("[Quick Strike] Loss ×0.90 → %.1f" % damage)

	return { "damage": damage, "log": log }


func _drain_touch(wpm_mod: float, typo_penalty: float, won: bool,
		base_mult: float, opp_hp: float, char_base: float) -> Dictionary:
	var log: Array[String] = []
	var base: float = char_base * (1.0 + wpm_mod) * base_mult - typo_penalty
	var damage: float = base
	var player_hp_delta: float = 0.0
	var opp_hp_delta:    float = 0.0

	if won:
		var bleed_val: float = 3.0 if opp_hp >= MAX_HP else 2.0
		opponent_bleed = { "rounds": 3, "value": bleed_val }
		player_heal    = { "rounds": 3, "value": 2.0 }
		log.append("[Drain Touch] Win: Opponent bleeds %.1fHP/round × 3, you heal 2HP/round × 3" % bleed_val)
	else:
		player_bleed = { "rounds": 3, "value": 2.0 }
		log.append("[Drain Touch] Loss: You bleed 2HP/round × 3")

	return { "damage": damage, "player_hp_delta": player_hp_delta,
			"opp_hp_delta": opp_hp_delta, "log": log }


func _whiplash(acc_mod: float, typo_penalty: float, won: bool, base_mult: float, char_base: float) -> Dictionary:
	var log: Array[String] = []
	var base: float = char_base * (1.0 + acc_mod) * base_mult - typo_penalty
	var damage: float = base

	if won:
		if opponent_win_streak >= 1:
			damage *= 2.0
			log.append("[Whiplash] Streak punish! ×2.0 → %.1f" % damage)
		else:
			damage *= 1.15
			log.append("[Whiplash] Win ×1.15 → %.1f" % damage)
	else:
		damage *= 0.85
		log.append("[Whiplash] Loss ×0.85 → %.1f" % damage)

	return { "damage": damage, "log": log }


func _soulbreak(wpm_mod: float, typo_penalty: float, won: bool, base_mult: float, char_base: float) -> Dictionary:
	var log: Array[String] = []
	var base: float = char_base * (1.0 + wpm_mod) * base_mult - typo_penalty
	var damage: float = base

	if won and player_mana >= 8:
		damage *= 1.15
		log.append("[Soulbreak] 8+ Mana bonus ×1.15 → %.1f" % damage)
	elif won:
		log.append("[Soulbreak] Win — base %.1f" % damage)
	else:
		log.append("[Soulbreak] Loss — no modifier")

	return { "damage": damage, "log": log }


func _rupture(opp_typos: int, typo_penalty: float, won: bool, base_mult: float, char_base: float) -> Dictionary:
	var log: Array[String] = []
	var damage: float = 0.0

	if opp_typos == 0:
		log.append("[Rupture] Opponent had 0 typos → 0 damage (high risk!)")
		return { "damage": 0.0, "log": log }

	damage = (char_base + opp_typos * 1.5 - typo_penalty) * base_mult
	log.append("[Rupture] %.1f + (%d×1.5) - %.1f = %.1f" % [char_base, opp_typos, typo_penalty, damage])

	return { "damage": damage, "log": log }


func _deathmark(typo_penalty: float, won: bool, base_mult: float, opp_hp: float, char_base: float) -> Dictionary:
	var log: Array[String] = []
	var base: float = char_base * 0.9 * base_mult - typo_penalty
	var damage: float = base
	var opp_hp_delta: float = 0.0

	if won:
		var mark_val: float = 4.0 if opp_hp <= MAX_HP * 0.4 else 2.0
		opponent_mark = { "rounds": 2, "value": mark_val }
		log.append("[Deathmark] Opponent marked: +%.1f flat/round × 2" % mark_val)
	else:
		player_mark = { "rounds": 2, "value": 2.0 }
		log.append("[Deathmark] You are marked: +2 flat/round × 2")

	return { "damage": damage, "opp_hp_delta": opp_hp_delta, "log": log }


# ─────────────────────────────────────────────
#  Status Effect Ticker
# ─────────────────────────────────────────────

func _tick_status_effects(player_hp: float, opp_hp: float) -> Dictionary:
	var log: Array[String] = []
	var player_hp_delta: float = 0.0
	var opp_hp_delta:    float = 0.0

	# Player bleed
	if not player_bleed.is_empty():
		var dmg: float = player_bleed.get("value", 2.0)
		player_hp_delta -= dmg
		player_bleed["rounds"] -= 1
		log.append("[Bleed] You take %.1f bleed damage (%d rounds left)" % [dmg, player_bleed["rounds"]])
		if player_bleed["rounds"] <= 0:
			player_bleed = {}

	# Opponent bleed
	if not opponent_bleed.is_empty():
		var dmg: float = opponent_bleed.get("value", 2.0)
		opp_hp_delta -= dmg
		opponent_bleed["rounds"] -= 1
		log.append("[Bleed] Opponent takes %.1f bleed damage (%d rounds left)" % [dmg, opponent_bleed["rounds"]])
		if opponent_bleed["rounds"] <= 0:
			opponent_bleed = {}

	# Player heal
	if not player_heal.is_empty():
		var heal: float = player_heal.get("value", 2.0)
		var actual_heal: float = min(heal, MAX_HP - player_hp)
		player_hp_delta += actual_heal
		player_heal["rounds"] -= 1
		log.append("[Heal] You recover %.1f HP (%d rounds left)" % [actual_heal, player_heal["rounds"]])
		if player_heal["rounds"] <= 0:
			player_heal = {}

	# Marks tick in resolve_round (applied after damage)

	return { "player_hp_delta": player_hp_delta, "opp_hp_delta": opp_hp_delta, "log": log }
