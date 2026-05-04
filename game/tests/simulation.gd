extends Node

var characters = ["Riven", "Liora", "Zephon"]
var skills = ["quickslash", "whiplash", "soulbreak"]
var passives = ["reversal", "jumble", "phantom", "stutter", "erosion"]

var wpm_pool = [40, 60, 80]
var acc_pool = [80, 95, 100]
var typos_pool = [0, 1, 3]
var mana_pool = [0, 5, 7, 8, 10]
var streak_pool = [0, 2, 3]

var all_results = []
var flagged_results = []
var summary_stats = {
	"wins": {},
	"avg_rounds": 0.0,
	"passive_triggers": {}
}

func _ready():
	print("Starting 2025 simulations...")
	for c in characters:
		summary_stats.wins[c] = 0
	for p in passives:
		summary_stats.passive_triggers[p] = 0
		
	var total_combos = 0
	for p1_char in characters:
		for p2_char in characters:
			for p1_skill in skills:
				for p2_skill in skills:
					for p1_pass in passives:
						for p2_pass in passives:
							run_simulation(p1_char, p2_char, p1_skill, p2_skill, p1_pass, p2_pass)
							total_combos += 1
							
	summary_stats.avg_rounds /= max(1, total_combos)
	
	save_json("res://tests/sim_results.json", all_results)
	save_json("res://tests/flags.json", flagged_results)
	save_json("res://tests/summary.json", summary_stats)
	print("Simulation complete! Ran ", total_combos, " combinations.")
	get_tree().quit()

func save_json(path, data):
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()

func run_simulation(p1_char, p2_char, p1_skill, p2_skill, p1_pass, p2_pass):
	SkillsManager.reset_match()
	
	HPManager.player_innate = p1_char
	HPManager.opponent_innate = p2_char
	SkillsManager.selected_passive = p1_pass
	
	# ── Load correct HP and base_dmg per character ────────────────────
	var char_stats = {
		"Riven":  { "hp": 85.0,  "dmg": 22.0 },
		"Liora":  { "hp": 100.0, "dmg": 16.0 },
		"Zephon": { "hp": 85.0,  "dmg": 20.0 }
	}
	HPManager.player_max_hp    = char_stats[p1_char].hp
	HPManager.opponent_max_hp  = char_stats[p2_char].hp
	HPManager.player_base_dmg  = char_stats[p1_char].dmg
	HPManager.opponent_base_dmg= char_stats[p2_char].dmg
	HPManager.player_hp   = HPManager.player_max_hp
	HPManager.opponent_hp = HPManager.opponent_max_hp
	
	var rounds = 0
	var p1_passive_triggered = false
	var jumble_reachable_p1 = false
	
	while HPManager.player_hp > 0 and HPManager.opponent_hp > 0 and rounds < 20:
		rounds += 1
		var p1_wpm = wpm_pool[randi() % wpm_pool.size()]
		var p1_acc = float(acc_pool[randi() % acc_pool.size()])
		var p1_typos = typos_pool[randi() % typos_pool.size()]
		# Zephon Overdrive: biased toward higher mana (simulates +1 mana/accurate word > 80 WPM)
		var p1_mana = mana_pool[randi() % mana_pool.size()]
		if p1_char == "Zephon": p1_mana = min(10, p1_mana + 2)
		var p1_streak = streak_pool[randi() % streak_pool.size()]
		
		var p2_wpm = wpm_pool[randi() % wpm_pool.size()]
		var p2_acc = float(acc_pool[randi() % acc_pool.size()])
		var p2_typos = typos_pool[randi() % typos_pool.size()]
		# Zephon Overdrive bias for P2
		var p2_mana = mana_pool[randi() % mana_pool.size()]
		if p2_char == "Zephon": p2_mana = min(10, p2_mana + 2)
		var p2_streak = streak_pool[randi() % streak_pool.size()]
		
		# ── P1 attacks P2 ──────────────────────────────────────
		SkillsManager.player_mana = p1_mana
		SkillsManager.player_win_streak = p1_streak
		SkillsManager.opponent_win_streak = p2_streak
		
		var words = 15.0
		var t1 = (words / float(p1_wpm)) * 60.0
		var t2 = (words / float(p2_wpm)) * 60.0
		
		var p1_finish = "buff"
		var p2_finish = "buff"
		
		if t1 > 60.0 and t2 > 60.0:
			p1_finish = "no_attack"
			p2_finish = "no_attack"
		elif t1 < t2:
			var snap_limit = minf(60.0, t1 + 10.0)
			if t2 <= snap_limit:
				p1_finish = "buff"
				p2_finish = "debuff"
			else:
				p1_finish = "full_power"
				p2_finish = "dnf"
		elif t2 < t1:
			var snap_limit = minf(60.0, t2 + 10.0)
			if t1 <= snap_limit:
				p2_finish = "buff"
				p1_finish = "debuff"
			else:
				p2_finish = "full_power"
				p1_finish = "dnf"
		else:
			p1_finish = "buff"
			p2_finish = "buff"

		var p1_action = p1_skill if p1_mana >= SkillsManager.SKILL_COSTS.get(p1_skill, 0) else ""
		
		var r1 = SkillsManager.resolve_round(
			float(p1_wpm), p1_acc, p1_typos, p2_typos,
			p1_finish, p1_action,
			HPManager.opponent_hp, HPManager.player_hp
		)
		
		# ── P2 attacks P1 (swap state) ─────────────────────────
		SkillsManager.player_mana = p2_mana
		SkillsManager.player_win_streak = p2_streak
		SkillsManager.opponent_win_streak = p1_streak
		HPManager.player_innate = p2_char    # P2 is now "player" for this call
		HPManager.opponent_innate = p1_char
		
		var p2_action = p2_skill if p2_mana >= SkillsManager.SKILL_COSTS.get(p2_skill, 0) else ""
		
		var r2 = SkillsManager.resolve_round(
			float(p2_wpm), p2_acc, p2_typos, p1_typos,
			p2_finish, p2_action,
			HPManager.player_hp, HPManager.opponent_hp
		)
		
		# Restore innate labels
		HPManager.player_innate = p1_char
		HPManager.opponent_innate = p2_char
		
		# Apply results — matching game.gd logic:
		# player_hp_delta = self-effects (Bloodlust self-dmg, Liora heal, etc.)
		# player_damage    = damage dealt to opponent (via take_damage)
		HPManager.player_hp   = clampf(HPManager.player_hp   + r1.player_hp_delta - r2.player_damage, 0, HPManager.player_max_hp)
		HPManager.opponent_hp = clampf(HPManager.opponent_hp + r2.player_hp_delta - r1.player_damage, 0, HPManager.opponent_max_hp)
		
		# ── Passive trigger tracking ───────────────────────────
		if p1_pass == "reversal" and p1_wpm > p2_wpm: p1_passive_triggered = true
		if p1_pass == "jumble" and p1_mana >= 7: p1_passive_triggered = true
		if p1_pass == "phantom" and p1_acc >= 85.0: p1_passive_triggered = true
		if p1_pass == "stutter" and p2_streak > 0: p1_passive_triggered = true
		if p1_pass == "erosion" and p1_typos == 0: p1_passive_triggered = true
		if p1_mana >= 7: jumble_reachable_p1 = true
		
	var winner = p1_char if HPManager.opponent_hp <= 0 else p2_char
	summary_stats.wins[winner] += 1
	summary_stats.avg_rounds += rounds
	if p1_passive_triggered: summary_stats.passive_triggers[p1_pass] += 1
	
	var flags = []
	if rounds < 2: flags.append("TOO_FAST")
	if rounds > 7: flags.append("TOO_SLOW")
	if rounds == 1: flags.append("ONE_SHOT")
	if not p1_passive_triggered: flags.append("PASSIVE_NEVER_TRIGGERED")
	if p1_pass == "jumble" and not jumble_reachable_p1: flags.append("JUMBLE_UNREACHABLE")
	
	var result = {
		"p1": p1_char, "p2": p2_char, "p1_skill": p1_skill, "p2_skill": p2_skill,
		"p1_pass": p1_pass, "p2_pass": p2_pass, "winner": winner, "rounds": rounds, "flags": flags
	}
	all_results.append(result)
	if flags.size() > 0:
		flagged_results.append(result)

