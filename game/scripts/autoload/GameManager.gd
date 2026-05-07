extends Node

## Global Game Manager Singleton
## Register this in Project Settings > Autoload as 'Game' or 'GameManager'

const SERVER_URL = "http://34.126.180.170:3000"

signal game_started
signal game_ended(results: Dictionary)
signal connection_status_changed(online: bool)

var is_online: bool = true
var _connection_error_overlay: CanvasLayer = null
var _consecutive_connection_failures: int = 0
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
var auto_queue_matchmaking: bool = false
var matchmaking_penalty_until_unix_ms: float = 0.0
var viewing_history_id: int = 0
var selected_character: String = ""
var opponent_character: String = ""
var opponent_passive: String = ""
var opponent_name: String = ""
var match_start_time: float = 0.0

func is_matchmaking_penalized() -> bool:
	return (Time.get_unix_time_from_system() * 1000.0) < matchmaking_penalty_until_unix_ms

func get_matchmaking_penalty_remaining_sec() -> int:
	var remaining_ms = matchmaking_penalty_until_unix_ms - (Time.get_unix_time_from_system() * 1000.0)
	return max(0, int(ceil(remaining_ms / 1000.0)))

# Unique session ID to count multiple windows of the same user separately
var session_id: String = ""

func _ready():
	session_id = str(randi()) + "_" + str(Time.get_ticks_msec())
	# Let us handle the quit event manually so we can send logout first
	get_tree().set_auto_accept_quit(false)
	
	_create_persistent_background()
	_create_connection_overlay()
	_start_connection_watchdog()

func _create_persistent_background():
	# Keeps the background visible between scene transitions so there's no black flash.
	# Hidden during the game scene which has its own background.
	var bg_layer = CanvasLayer.new()
	bg_layer.name = "PersistentBackground"
	bg_layer.layer = -100  # render behind everything
	add_child(bg_layer)
	var bg_rect = TextureRect.new()
	bg_rect.name = "BgRect"
	bg_rect.texture = load("res://assets/terrain/Legacy-Fantasy - High Forest 2.3/Background/Background.png")
	bg_rect.layout_mode = 1
	bg_rect.anchors_preset = 15  # full rect
	bg_rect.anchor_right = 1.0
	bg_rect.anchor_bottom = 1.0
	bg_rect.grow_horizontal = 2
	bg_rect.grow_vertical = 2
	bg_rect.stretch_mode = TextureRect.STRETCH_SCALE
	bg_layer.add_child(bg_rect)
	# Listen for scene changes to hide/show based on active scene
	get_tree().root.child_entered_tree.connect(_on_scene_changed)

func set_connection_online(online: bool) -> void:
	if online:
		_consecutive_connection_failures = 0
	if online == is_online:
		return
	is_online = online
	connection_status_changed.emit(is_online)
	_toggle_connection_overlay(!is_online)

func _on_scene_changed(node: Node) -> void:
	# Hide the persistent background in scenes that have their own background.
	# Show it in all other UI scenes to prevent black flashes between transitions.
	var bg_layer = get_node_or_null("PersistentBackground")
	if bg_layer == null: return
	var scene_name = node.name if node else ""
	# These scenes have their own backgrounds — hide the persistent one
	var has_own_bg = scene_name in ["Game", "CustomRoom"]
	bg_layer.visible = not has_own_bg

func _start_connection_watchdog():
	# Only run the watchdog when NOT in an active game — during gameplay the
	# NetworkSync polls already confirm connectivity every 0.5s. Running a
	# separate health-check on top creates a competing HTTP load that can make
	# a stable connection appear to drop (server busy → health timeout → overlay).
	while true:
		await get_tree().create_timer(8.0).timeout  # check every 8s, not 3s
		# Skip the health check if the game scene is active — polls handle it
		if get_tree().current_scene and get_tree().current_scene.name == "Game":
			continue
		_check_connection()

func _check_connection():
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_connection_check_completed.bind(http))
	# 5s timeout — generous enough to survive a slow server response without
	# false-positives, tight enough to detect a real outage quickly.
	http.timeout = 5.0
	var err = http.request(SERVER_URL + "/api/health")
	if err != OK:
		_on_connection_check_completed(HTTPRequest.RESULT_CANT_CONNECT, 0, [], PackedByteArray(), http)

func _on_connection_check_completed(result, response_code, _headers, _body, http_node):
	if is_instance_valid(http_node):
		http_node.queue_free()

	var success = (result == HTTPRequest.RESULT_SUCCESS and response_code == 200)
	if success:
		_consecutive_connection_failures = 0
		set_connection_online(true)
	else:
		_consecutive_connection_failures += 1
		# Require 2 consecutive failures before showing the overlay — avoids
		# false positives from a single slow or dropped response on stable internet
		if _consecutive_connection_failures >= 2:
			set_connection_online(false)

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

func get_auth_token() -> String:
	return user_data.get("token", "")

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
