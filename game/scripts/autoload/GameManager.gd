extends Node

## Global Game Manager Singleton
## Register this in Project Settings > Autoload as 'Game' or 'GameManager'

const SERVER_URL = "http://127.0.0.1:3000"

signal game_started

signal game_ended(results: Dictionary)

var current_score: int = 0
var is_game_active: bool = false

# User Session Data
var user_data: Dictionary = {
	"id": 0,
	"username": "",
	"display_name": "",
	"profile_icon": "default",
	"token": ""
}

# Room / Matchmaking Data
var current_room: String = ""
var is_host: bool = true
var is_solo: bool = false
var viewing_history_id: int = 0
var selected_character: String = ""
var opponent_character: String = ""

# Unique session ID to count multiple windows of the same user separately
var session_id: String = ""

func _ready():
	session_id = str(randi()) + "_" + str(Time.get_ticks_msec())

func start_game() -> void:
	is_game_active = true
	current_score = 0
	game_started.emit()
	print("Game Started")

func end_game(results: Dictionary = {}) -> void:
	is_game_active = false
	game_ended.emit(results)
	print("Game Ended with results: ", results)

func get_auth_headers() -> PackedStringArray:
	if user_data.token == "":
		return ["Content-Type: application/json"]
	return ["Authorization: Bearer " + user_data.token, "Content-Type: application/json"]
