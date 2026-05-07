extends Node

## HPManager Singleton
## Manages health for Player and Opponent

signal hp_changed(entity: String, current_hp: float, max_hp: float)
signal entity_died(entity: String)

var player_hp: float = 100.0
var opponent_hp: float = 100.0
var player_max_hp: float = 100.0
var opponent_max_hp: float = 100.0

var player_base_dmg: float = 10.0
var opponent_base_dmg: float = 10.0
var player_innate: String = ""
var opponent_innate: String = ""

var characters_data = []

func _ready():
	var path = "res://assets/data/characters.json"
	var file = FileAccess.open(path, FileAccess.READ)
	if file:
		var json = JSON.parse_string(file.get_as_text())
		if json and typeof(json) == TYPE_DICTIONARY and json.has("characters"):
			characters_data = json["characters"]
		elif json and typeof(json) == TYPE_ARRAY:
			characters_data = json

func init_game():
	var my_char = GameManager.selected_character
	var opp_char = GameManager.opponent_character
	
	player_max_hp = 100.0
	opponent_max_hp = 100.0
	player_base_dmg = 10.0
	opponent_base_dmg = 10.0
	player_innate = ""
	opponent_innate = ""
	
	for c in characters_data:
		if typeof(c) == TYPE_DICTIONARY:
			if c.get("name") == my_char:
				player_max_hp = float(c.get("hp", 100.0))
				player_base_dmg = float(c.get("base_dmg", 10.0))
				player_innate = c.get("innate", "")
			if c.get("name") == opp_char:
				opponent_max_hp = float(c.get("hp", 100.0))
				opponent_base_dmg = float(c.get("base_dmg", 10.0))
				opponent_innate = c.get("innate", "")
				
	player_hp = player_max_hp
	opponent_hp = opponent_max_hp
	hp_changed.emit("player", player_hp, player_max_hp)
	hp_changed.emit("opponent", opponent_hp, opponent_max_hp)
	
	# reset all per-match SkillsManager state (streaks, mana, Liora heal cap,
	# Phantom stack) so nothing bleeds across rematches.
	SkillsManager.reset_match()
	
	# ── DEBUG: confirm character stats loaded ──────────────────────────
	print("╔══════ HPManager Init ══════╗")
	print("║ PLAYER   : %-12s        ║" % my_char)
	print("║   HP     : %.0f / %.0f             ║" % [player_hp, player_max_hp])
	print("║   BaseDMG: %.0f                   ║" % player_base_dmg)
	print("║   Innate : %s              ║" % player_innate)
	print("║ OPPONENT : %-12s        ║" % opp_char)
	print("║   HP     : %.0f / %.0f             ║" % [opponent_hp, opponent_max_hp])
	print("║   BaseDMG: %.0f                   ║" % opponent_base_dmg)
	print("║   Innate : %s              ║" % opponent_innate)
	print("╚════════════════════════════╝")

func set_hp(entity: String, value: float):
	if entity == "player":
		player_hp = clamp(value, 0, player_max_hp)
		hp_changed.emit("player", player_hp, player_max_hp)
		if player_hp <= 0:
			entity_died.emit("player")
	elif entity == "opponent":
		opponent_hp = clamp(value, 0, opponent_max_hp)
		hp_changed.emit("opponent", opponent_hp, opponent_max_hp)
		if opponent_hp <= 0:
			entity_died.emit("opponent")

func take_damage(entity: String, amount: float):
	if entity == "player":
		set_hp("player", player_hp - amount)
	elif entity == "opponent":
		set_hp("opponent", opponent_hp - amount)

func heal(entity: String, amount: float):
	if entity == "player":
		set_hp("player", player_hp + amount)
	elif entity == "opponent":
		set_hp("opponent", opponent_hp + amount)

func reset():
	init_game()
