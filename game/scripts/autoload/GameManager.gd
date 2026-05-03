extends Node

## Global Game Manager Singleton
## Register this in Project Settings > Autoload as 'Game' or 'GameManager'

signal game_started
signal game_ended(results: Dictionary)

var current_score: int = 0
var is_game_active: bool = false

# User Session Data
var user_data: Dictionary = {
	"id": 0,
	"username": "",
	"display_name": "",
	"token": ""
}

func start_game() -> void:
	is_game_active = true
	current_score = 0
	game_started.emit()
	print("Game Started")

func end_game(results: Dictionary = {}) -> void:
	is_game_active = false
	game_ended.emit(results)
	print("Game Ended with results: ", results)
