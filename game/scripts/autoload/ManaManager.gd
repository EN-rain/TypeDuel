extends Node

## ManaManager — DEPRECATED / UNUSED
##
## All mana state is managed by SkillsManager (player_mana / opponent_mana).
## This singleton is registered as an autoload but is never referenced anywhere in the
## codebase.  It is kept here to avoid breaking the autoload list in project.godot, but
## it does nothing.  If you want to centralise mana management in the future, migrate
## SkillsManager.player_mana / opponent_mana into this class and update all call sites.

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
