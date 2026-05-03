extends Node

## HPManager Singleton
## Manages health for Player and Opponent

signal hp_changed(entity: String, current_hp: float, max_hp: float)
signal entity_died(entity: String)

var player_hp: float = 100.0
var opponent_hp: float = 100.0
var max_hp: float = 100.0

func set_hp(entity: String, value: float):
	if entity == "player":
		player_hp = clamp(value, 0, max_hp)
		hp_changed.emit("player", player_hp, max_hp)
		if player_hp <= 0:
			entity_died.emit("player")
	elif entity == "opponent":
		opponent_hp = clamp(value, 0, max_hp)
		hp_changed.emit("opponent", opponent_hp, max_hp)
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
	player_hp = max_hp
	opponent_hp = max_hp
	hp_changed.emit("player", player_hp, max_hp)
	hp_changed.emit("opponent", opponent_hp, max_hp)
