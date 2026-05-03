extends Control

const SERVER = "http://34.143.153.96:3000"

@onready var greeting_label  = $Greeting
@onready var online_count_label = $OnlineCount
@onready var join_panel = $JoinPanel
@onready var join_input = $JoinPanel/CodeInput
@onready var join_error = $JoinPanel/ErrorLabel
@onready var matchmaking_label = $MatchmakingLabel
@onready var matchmaking_time_label = $MatchmakingTime
@onready var play_online_btn = $PlayOnlineButton

var is_matchmaking = false
var matchmaking_start_time = 0.0
var matchmaking_code = ""
var poll_timer = 0.0

func _ready():
	var name_to_show = GameManager.user_data.display_name
	if name_to_show == "":
		name_to_show = GameManager.user_data.username
	greeting_label.text = "Hi, " + name_to_show + "!"
	_fetch_online_count()
	matchmaking_label.hide()
	matchmaking_time_label.hide()

func _process(delta):
	if is_matchmaking:
		var elapsed = Time.get_ticks_msec() / 1000.0 - matchmaking_start_time
		var minutes = int(elapsed) / 60
		var seconds = int(elapsed) % 60
		matchmaking_time_label.text = "Time: %d:%02d" % [minutes, seconds]
		
		if matchmaking_code != "":
			poll_timer += delta
			if poll_timer >= 2.0:
				poll_timer = 0.0
				_check_matchmaking_status()

func _fetch_online_count():
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_online_count_received.bind(http))
	http.request(SERVER + "/api/game/online-count")

func _on_online_count_received(result, code, _headers, body, http: HTTPRequest):
	http.queue_free()
	if code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json and json.has("online"):
			online_count_label.text = "● %d players online" % json["online"]

func _on_solo_play_pressed():
	print("Solo Play pressed")
	GameManager.is_host = true
	GameManager.is_solo = true
	GameManager.current_room = ""
	get_tree().change_scene_to_file("res://scenes/ui/custom_room.tscn")

func _on_custom_room_pressed():
	print("Custom Room pressed")
	GameManager.is_host = true
	GameManager.is_solo = false
	GameManager.current_room = ""
	get_tree().change_scene_to_file("res://scenes/ui/custom_room.tscn")

func _on_join_pressed():
	join_panel.visible = true
	join_input.text = ""
	join_error.text = ""

func _on_cancel_join_pressed():
	join_panel.visible = false

func _on_submit_join_pressed():
	var code = join_input.text.strip_edges().to_upper()
	if code.length() != 6:
		join_error.text = "Code must be 6 characters."
		return
	
	join_error.text = "Joining..."
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_join_done.bind(http))
	var my_name = GameManager.user_data.display_name
	if my_name == "":
		my_name = GameManager.user_data.username
	var body = JSON.stringify({
		"user_id": GameManager.user_data.id,
		"display_name": my_name,
		"code": code
	})
	http.request(SERVER + "/api/rooms/join", ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)

func _on_join_done(_result, req_code, _headers, body, http):
	http.queue_free()
	var json = {}
	if body.size() > 0:
		json = JSON.parse_string(body.get_string_from_utf8())
		
	if req_code == 200:
		GameManager.current_room = join_input.text.strip_edges().to_upper()
		GameManager.is_host = false
		GameManager.is_solo = false
		get_tree().change_scene_to_file("res://scenes/ui/custom_room.tscn")
	else:
		if json and json.has("message"):
			join_error.text = json["message"]
		elif req_code == 403:
			join_error.text = "That's your own room!"
		elif req_code == 404:
			join_error.text = "Room not found."
		elif req_code == 409:
			join_error.text = "Room is full."
		else:
			join_error.text = "Failed to join room."

func _on_play_online_pressed():
	if is_matchmaking:
		# Cancel matchmaking
		is_matchmaking = false
		matchmaking_label.hide()
		matchmaking_time_label.hide()
		play_online_btn.text = "Play Online"
		matchmaking_code = ""
		return

	print("Starting Matchmaking...")
	is_matchmaking = true
	matchmaking_start_time = Time.get_ticks_msec() / 1000.0
	matchmaking_label.show()
	matchmaking_time_label.show()
	play_online_btn.text = "Cancel Matchmaking"
	
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_matchmake_done.bind(http))
	var my_name = GameManager.user_data.display_name
	if my_name == "":
		my_name = GameManager.user_data.username
	var body = JSON.stringify({
		"user_id": GameManager.user_data.id,
		"display_name": my_name
	})
	http.request(SERVER + "/api/rooms/matchmake", ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)

func _on_matchmake_done(_result, code, _headers, body, http):
	http.queue_free()
	if not is_matchmaking: return # already cancelled
	
	if code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json.role == "guest":
			# Found a match instantly
			GameManager.current_room = json.room.code
			GameManager.is_host = false
			GameManager.is_solo = false
			get_tree().change_scene_to_file("res://scenes/ui/custom_room.tscn")
		else:
			# Waiting for guest
			matchmaking_code = json.code
			matchmaking_label.text = "Waiting for opponent..."
	else:
		is_matchmaking = false
		matchmaking_label.text = "Matchmaking failed."
		play_online_btn.text = "Play Online"

func _check_matchmaking_status():
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_poll_match_done.bind(http))
	http.request(SERVER + "/api/rooms/" + matchmaking_code)

func _on_poll_match_done(_result, code, _headers, body, http):
	http.queue_free()
	if not is_matchmaking: return
	
	if code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json.guest_id:
			# Guest joined!
			GameManager.current_room = matchmaking_code
			GameManager.is_host = true
			GameManager.is_solo = false
			get_tree().change_scene_to_file("res://scenes/ui/custom_room.tscn")

func _on_leaderboard_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/leaderboard.tscn")

func _on_settings_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/settings.tscn")

func _on_logout_pressed():
	# Clear session
	GameManager.user_data = {
		"id": 0,
		"username": "",
		"display_name": "",
		"token": ""
	}
	get_tree().change_scene_to_file("res://scenes/ui/login_scene.tscn")
