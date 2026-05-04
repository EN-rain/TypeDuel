extends Node

## Global Game Manager Singleton
## Register this in Project Settings > Autoload as 'Game' or 'GameManager'

const SERVER_URL = "http://34.126.180.170:3000"

signal game_started
signal game_ended(results: Dictionary)
signal connection_status_changed(online: bool)

var is_online: bool = true
var _connection_error_overlay: CanvasLayer = null
const CONNECTION_LOST_SCENE = preload("res://scenes/ui/connection_lost_overlay.tscn")

const PASSIVES = [
	{"id": "reversal", "name": "Reversal"},
	{"id": "jumble",   "name": "Jumble"},
	{"id": "phantom",  "name": "Phantom"},
	{"id": "stutter",  "name": "Stutter"},
	{"id": "erosion",  "name": "Erosion"},
]

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
var match_start_time: float = 0.0

# Unique session ID to count multiple windows of the same user separately
var session_id: String = ""

func _ready():
	session_id = str(randi()) + "_" + str(Time.get_ticks_msec())
	# Let us handle the quit event manually so we can send logout first
	get_tree().set_auto_accept_quit(false)
	
	_create_connection_overlay()
	_start_connection_watchdog()

func _start_connection_watchdog():
	while true:
		await get_tree().create_timer(3.0).timeout
		_check_connection()

func _check_connection():
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_connection_check_completed.bind(http))
	
	# Set a short timeout for the connection check
	http.timeout = 2.0
	var err = http.request(SERVER_URL + "/api/health")
	if err != OK:
		_on_connection_check_completed(HTTPRequest.RESULT_CANT_CONNECT, 0, [], PackedByteArray(), http)

func _on_connection_check_completed(result, response_code, _headers, _body, http_node):
	if is_instance_valid(http_node):
		http_node.queue_free()
		
	var currently_online = (result == HTTPRequest.RESULT_SUCCESS and response_code == 200)
	if currently_online != is_online:
		is_online = currently_online
		connection_status_changed.emit(is_online)
		_toggle_connection_overlay(!is_online)

func _create_connection_overlay():
	_connection_error_overlay = CanvasLayer.new()
	_connection_error_overlay.layer = 128 # Above everything
	add_child(_connection_error_overlay)
	
	var overlay_instance = CONNECTION_LOST_SCENE.instantiate()
	_connection_error_overlay.add_child(overlay_instance)
	
	_connection_error_overlay.hide()

func _toggle_connection_overlay(visible: bool):
	if _connection_error_overlay:
		_connection_error_overlay.visible = visible
		if visible:
			print("[Network] Connection lost! Showing popup.")
		else:
			print("[Network] Connection restored! Hiding popup.")

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
