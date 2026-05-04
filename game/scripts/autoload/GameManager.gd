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
var is_matchmaking: bool = false
var viewing_history_id: int = 0
var selected_character: String = ""
var opponent_character: String = ""
var opponent_passive: String = ""

# Unique session ID to count multiple windows of the same user separately
var session_id: String = ""

func _ready():
	session_id = str(randi()) + "_" + str(Time.get_ticks_msec())
	# Let us handle the quit event manually so we can send logout first
	get_tree().set_auto_accept_quit(false)

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

func send_logout():
	if user_data.id == 0: return
	var body = JSON.stringify({ "user_id": user_data.id })
	var headers = get_auth_headers()
	# Use a non-awaited HTTPRequest since the game may be closing
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r,_c,_h,_b): http.queue_free())
	http.request(SERVER_URL + "/api/auth/logout", headers, HTTPClient.METHOD_POST, body)

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		send_logout()
		# Give the HTTP request a moment, then quit
		await get_tree().create_timer(0.4).timeout
		get_tree().quit()
