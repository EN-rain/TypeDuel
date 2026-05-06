extends Control

@onready var result_label = $CenterContainer/VBoxContainer/ResultLabel
@onready var back_button = $CenterContainer/VBoxContainer/HBoxContainer/BackButton
@ontml:parameter name="rematch_button = $CenterContainer/VBoxContainer/HBoxContainer/RematchButton
@onready var match_again_button = $CenterContainer/VBoxContainer/HBoxContainer/MatchAgainButton
@onready var rematch_status_label = $CenterContainer/VBoxContainer/RematchStatusLabel

const POLL_INTERVAL = 0.5
var poll_timer: float = 0.0
var _i_want_rematch: bool = false
var _opp_wants_rematch: bool = false
var _poll_in_flight: bool = false
var _rematch_initiated: bool = false

func _ready():
	back_button.pressed.connect(_on_back_pressed)
	rematch_button.pressed.connect(_on_rematch_pressed)
	match_again_button.pressed.connect(_on_match_again_pressed)
	
	# Unpause the game so we can process polling
	get_tree().paused = false
	
	if GameManager.is_solo:
		match_again_button.text = "Restart"
		rematch_button.hide()
		rematch_status_label.hide()
	elif GameManager.is_matchmaking:
		match_again_button.text = "Find New Match"
		rematch_button.show()
		rematch_status_label.show()
		rematch_status_label.text = ""
	else:
		# Custom Room
		match_again_button.hide()
		rematch_button.show()
		rematch_status_label.show()
		rematch_status_label.text = ""

func _process(delta: float):
	if GameManager.is_solo or _rematch_initiated:
		return
	
	poll_timer += delta
	if poll_timer >= POLL_INTERVAL:
		poll_timer = 0.0
		_poll_rematch_status()
	
	_update_rematch_status()


func set_result(won: bool):
	if won:
		result_label.text = "VICTORY!"
		result_label.modulate = Color.GREEN
	else:
		result_label.text = "DEFEAT!"
		result_label.modulate = Color.RED

func _poll_rematch_status():
	if GameManager.current_room == "" or _poll_in_flight:
		return
	
	_poll_in_flight = true
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_poll_done.bind(http))
	http.timeout = 5.0
	var err = http.request(GameManager.SERVER_URL + "/api/rooms/" + GameManager.current_room, GameManager.get_auth_headers())
	if err != OK:
		_poll_in_flight = false
		if is_instance_valid(http):
			http.queue_free()

func _on_poll_done(_result, code, _headers, body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()
	_poll_in_flight = false
	
	if code == 404:
		# Room was deleted, go back to menu
		_on_back_pressed()
		return
	
	if code != 200:
		return
	
	var json = JSON.parse_string(body.get_string_from_utf8())
	if not json:
		return
	
	# Check rematch status
	if GameManager.is_host:
		_opp_wants_rematch = json.get("guest_wants_rematch", false)
	else:
		_opp_wants_rematch = json.get("host_wants_rematch", false)
	
	# If both want rematch, go to lobby
	if _i_want_rematch and _opp_wants_rematch and not _rematch_initiated:
		_rematch_initiated = true
		_initiate_rematch()

func _update_rematch_status():
	if not is_instance_valid(rematch_status_label):
		return
	
	if _i_want_rematch and _opp_wants_rematch:
		rematch_status_label.text = "Both ready! Starting rematch..."
		rematch_status_label.modulate = Color.GREEN
	elif _i_want_rematch:
		rematch_status_label.text = "You: Ready | Opponent: Waiting..."
		rematch_status_label.modulate = Color.YELLOW
	elif _opp_wants_rematch:
		rematch_status_label.text = "You: Waiting | Opponent: Ready"
		rematch_status_label.modulate = Color.YELLOW
	else:
		rematch_status_label.text = ""

func _initiate_rematch():
	# Reset selections but keep the room
	GameManager.selected_character = ""
	GameManager.opponent_character = ""
	SkillsManager.selected_skills.clear()
	SkillsManager.selected_passive = ""
	
	# Go back to lobby
	get_tree().change_scene_to_file("res://scenes/ui/custom_room.tscn")

func _on_back_pressed():
	# Delete the room if host, leave if guest
	if GameManager.current_room != "":
		if GameManager.is_host:
			_delete_room()
		else:
			_leave_room()
	
	GameManager.current_room = ""
	GameManager.is_matchmaking = false
	GameManager.auto_queue_matchmaking = false
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")

func _on_rematch_pressed():
	if GameManager.is_solo:
		get_tree().change_scene_to_file("res://scenes/game/game.tscn")
		return
	
	# Mark that we want rematch
	_i_want_rematch = true
	rematch_button.disabled = true
	rematch_button.text = "Waiting..."
	
	# Send rematch request to server
	_send_rematch_request()

func _send_rematch_request():
	if GameManager.current_room == "":
		return
	
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r, _c, _h, _b): http.queue_free())
	http.timeout = 5.0
	
	var body = JSON.stringify({
		"user_id": GameManager.user_data.id,
		"wants_rematch": true
	})
	
	http.request(
		GameManager.SERVER_URL + "/api/rooms/" + GameManager.current_room + "/rematch",
		GameManager.get_auth_headers(),
		HTTPClient.METHOD_PATCH,
		body
	)

func _delete_room():
	if GameManager.current_room == "":
		return
	
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r, _c, _h, _b): http.queue_free())
	http.timeout = 5.0
	http.request(
		GameManager.SERVER_URL + "/api/rooms/" + GameManager.current_room,
		GameManager.get_auth_headers(),
		HTTPClient.METHOD_DELETE
	)

func _leave_room():
	if GameManager.current_room == "":
		return
	
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r, _c, _h, _b): http.queue_free())
	http.timeout = 5.0
	http.request(
		GameManager.SERVER_URL + "/api/rooms/" + GameManager.current_room + "/leave",
		GameManager.get_auth_headers(),
		HTTPClient.METHOD_POST
	)

func _on_match_again_pressed():
	if GameManager.is_matchmaking:
		# Auto-queue matchmaking (intended behavior)
		GameManager.current_room = ""
		GameManager.auto_queue_matchmaking = true
		get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
	elif GameManager.is_solo:
		get_tree().change_scene_to_file("res://scenes/game/game.tscn")
	else:
		# Custom room - go back to lobby
		get_tree().change_scene_to_file("res://scenes/ui/custom_room.tscn")
