extends Node

## ManaManager Singleton
## Manages Combo Points (CP) for Player and Opponent

signal cp_changed(entity: String, current_cp: int)

var player_cp: int = 0
var opponent_cp: int = 0
var max_cp: int = 10

func set_cp(entity: String, value: int):
	if entity == "player":
		player_cp = clamp(value, 0, max_cp)
		cp_changed.emit("player", player_cp)
	elif entity == "opponent":
		opponent_cp = clamp(value, 0, max_cp)
		cp_changed.emit("opponent", opponent_cp)

func add_cp(entity: String, amount: int):
	if entity == "player":
		set_cp("player", player_cp + amount)
	elif entity == "opponent":
		set_cp("opponent", opponent_cp + amount)

func spend_cp(entity: String, amount: int) -> bool:
	if entity == "player":
		if player_cp >= amount:
			set_cp("player", player_cp - amount)
			return true
	elif entity == "opponent":
		if opponent_cp >= amount:
			set_cp("opponent", opponent_cp - amount)
			return true
	return false

func reset():
	player_cp = 0
	opponent_cp = 0
	cp_changed.emit("player", player_cp)
	cp_changed.emit("opponent", opponent_cp)
