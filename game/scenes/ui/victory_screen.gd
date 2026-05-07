extends Control

@onready var result_label = $CenterContainer/VBoxContainer/ResultLabel
@onready var back_button = $CenterContainer/VBoxContainer/HBoxContainer/BackButton
@onready var rematch_button = $CenterContainer/VBoxContainer/HBoxContainer/RematchButton
@onready var match_again_button = $CenterContainer/VBoxContainer/HBoxContainer/MatchAgainButton
@onready var rematch_status_label = $CenterContainer/VBoxContainer/RematchStatusLabel

const POLL_INTERVAL = 0.5
var poll_timer: float = 0.0
var _i_want_rematch: bool = false
var _opp_wants_rematch: bool = false
var _poll_in_flight: bool = false
var _rematch_initiated: bool = false
var _opp_left: bool = false

func _ready():
	back_button.pressed.connect(_on_back_pressed)
	rematch_button.pressed.connect(_on_rematch_pressed)
	match_again_button.pressed.connect(_on_match_again_pressed)

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
		match_again_button.hide()
		rematch_button.show()
		rematch_status_label.show()
		rematch_status_label.text = ""

func _process(delta: float):
	if GameManager.is_solo or _rematch_initiated or _opp_left:
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
		# Room deleted — opponent left
		_opp_left = true
		var opp_name = GameManager.opponent_name if GameManager.opponent_name != "" else "Opponent"
		rematch_status_label.text = "%s Left..." % opp_name
		rematch_status_label.modulate = Color.RED
		rematch_button.disabled = true
		# Auto-return to menu after 3s
		await get_tree().create_timer(3.0).timeout
		_on_back_pressed()
		return

	if code != 200:
		return

	var json = JSON.parse_string(body.get_string_from_utf8())
	if not json:
		return

	# Check if opponent left mid-screen (room still exists but status finished/forfeit)
	var status = json.get("status", "")
	if status == "finished" and not _i_want_rematch:
		# They left without rematching
		_opp_left = true
		var opp_name = GameManager.opponent_name if GameManager.opponent_name != "" else "Opponent"
		rematch_status_label.text = "%s Left..." % opp_name
		rematch_status_label.modulate = Color.RED
		rematch_button.disabled = true
		await get_tree().create_timer(3.0).timeout
		_on_back_pressed()
		return

	# Durable rematch-complete signal: server resets room to lobby when both agree.
	# The transient flags are cleared at that point, so we use status instead.
	# This catches the first-clicker who polled after the flags were already cleared.
	if status == "lobby" and _i_want_rematch and not _rematch_initiated:
		_rematch_initiated = true
		_opp_wants_rematch = true
		_update_rematch_status()
		_initiate_rematch()
		return

	# Read opponent rematch flag (only meaningful while status is still "finished")
	var prev_opp = _opp_wants_rematch
	if GameManager.is_host:
		_opp_wants_rematch = json.get("guest_wants_rematch", false)
	else:
		_opp_wants_rematch = json.get("host_wants_rematch", false)

	# If opponent just clicked rematch, update status immediately
	if _opp_wants_rematch and not prev_opp:
		_update_rematch_status()

	# If both want rematch, go to lobby
	if _i_want_rematch and _opp_wants_rematch and not _rematch_initiated:
		_rematch_initiated = true
		_initiate_rematch()

func _update_rematch_status():
	if not is_instance_valid(rematch_status_label):
		return

	var opp_name = GameManager.opponent_name if GameManager.opponent_name != "" else "Opponent"

	if _i_want_rematch and _opp_wants_rematch:
		rematch_status_label.text = "Both ready! Starting rematch..."
		rematch_status_label.modulate = Color.GREEN
	elif _i_want_rematch and not _opp_wants_rematch:
		rematch_status_label.text = "Waiting for %s..." % opp_name
		rematch_status_label.modulate = Color.YELLOW
	elif _opp_wants_rematch and not _i_want_rematch:
		rematch_status_label.text = "%s wants to rematch!" % opp_name
		rematch_status_label.modulate = Color.CYAN
	else:
		rematch_status_label.text = ""

func _initiate_rematch():
	GameManager.selected_character = ""
	GameManager.opponent_character = ""
	GameManager.opponent_name = ""
	SkillsManager.selected_skills.clear()
	SkillsManager.selected_passive = ""
	# Keep is_matchmaking as-is — the lobby scene uses it to show the correct UI.
	# current_room is preserved so custom_room.gd rejoins the existing reset room
	# instead of creating a new one.
	get_tree().change_scene_to_file("res://scenes/ui/custom_room.tscn")

func _on_back_pressed():
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

	_i_want_rematch = true
	rematch_button.disabled = true
	rematch_button.text = "Waiting..."
	_update_rematch_status()
	_send_rematch_request()

func _send_rematch_request():
	if GameManager.current_room == "":
		return

	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = 5.0
	http.request_completed.connect(func(_r, _code, _h, body):
		if is_instance_valid(http): http.queue_free()
		# If the server already has both players ready, transition immediately
		# from this response — don't wait for the next poll cycle.
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json and json.get("rematch_ready", false) and not _rematch_initiated:
			_rematch_initiated = true
			_opp_wants_rematch = true
			_update_rematch_status()
			_initiate_rematch()
	)

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
		GameManager.current_room = ""
		GameManager.auto_queue_matchmaking = true
		get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
	elif GameManager.is_solo:
		get_tree().change_scene_to_file("res://scenes/game/game.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/ui/custom_room.tscn")
