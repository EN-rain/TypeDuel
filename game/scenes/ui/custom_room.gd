extends Control



const POLL_INTERVAL = 0.5
const REQUEST_TIMEOUT_SEC = 5.0

const CHARACTERS = ["Riven", "Zephon", "Liora"]
const SKILLS = [
	{"id": "quickslash", "name": "Quickslash (2M)"},
	{"id": "whiplash",   "name": "Whiplash (2M)"},
	{"id": "soulbreak",  "name": "Soulbreak (3M)"},
]


@onready var room_code_label  = $RoomCode
@onready var status_label     = $StatusLabel
@onready var player1_name     = $Player1Name
@onready var player2_name     = $Player2Name
@onready var player2_tag      = $Player2Tag
@onready var start_button     = $StartButton
@onready var player1_tag      = $Player1Tag
@onready var char_container   = $Characters/VBoxContainer
@onready var skill_container  = $Skill/VBoxContainer

@onready var _manual_passive_buttons = [
	$Passive/HBoxContainer/VBoxContainer1/Passive1,
	$Passive/HBoxContainer/VBoxContainer1/Passive2,
	$Passive/HBoxContainer/VBoxContainer2/Passive3,
	$Passive/HBoxContainer/VBoxContainer2/Passive4,
	$Passive/HBoxContainer/VBoxContainer3/Passive5
]

@export var selected_char_color: Color = Color.GREEN
@export var selected_skill_color: Color = Color.CYAN
@export var selected_passive_color: Color = Color.PURPLE

var room_code: String   = ""
var my_user_id: int     = 0
var my_name: String     = ""
var poll_timer: float   = 0.0
var guest_joined: bool  = false
var _heartbeat_timer: float = 0.0
var _poll_in_flight: bool = false

# Opponent's last known selections (populated from poll)
var _opp_character: String    = ""
var _opp_skills: Array        = []
var _opp_passive: String      = ""

# Matchmaking: auto-start / forfeit rules
var _matchmaking_deadline_unix_ms: float = 0.0
var _matchmaking_forfeit_handled: bool = false
var _matchmaking_start_sent: bool = false
var _last_room_seq: int = -1

# Dynamically built button arrays
var _char_buttons: Array      = []
var _skill_buttons: Array     = []
var _passive_buttons: Array   = []

func _ready():
	my_user_id = GameManager.user_data.id
	my_name    = GameManager.user_data.display_name
	if my_name == "":
		my_name = GameManager.user_data.username

	if not GameManager.is_host:
		room_code = GameManager.current_room
		room_code_label.text = room_code
		player2_name.text = my_name
		player2_tag.text  = "You (Guest)"
		player1_name.text = "Host"
		player1_tag.text  = "Waiting for host..."
		status_label.text = "Joined. Select your character & 2 skills."
		guest_joined      = true
		start_button.hide()
	else:
		player1_name.text = my_name
		if GameManager.current_room != "":
			room_code = GameManager.current_room
			room_code_label.text = room_code
			guest_joined = true
			_poll_room()
		else:
			room_code = _generate_code()
			GameManager.current_room = room_code
			room_code_label.text = room_code
			_create_room()

	if GameManager.is_solo:
		room_code_label.hide()
		if has_node("RoomCodeLabel"):
			$RoomCodeLabel.hide()
			
	if GameManager.is_matchmaking:
		room_code_label.hide()
		if has_node("RoomCodeLabel"):
			$RoomCodeLabel.hide()
		if is_instance_valid(start_button):
			start_button.hide()
			start_button.disabled = true

	# Click to copy
	room_code_label.mouse_filter = Control.MOUSE_FILTER_STOP
	room_code_label.gui_input.connect(_on_room_code_input)

	_setup_ui()
	_setup_chat()

func _setup_chat():
	if room_code == "" or not has_node("ChatBox"): return
	$ChatBox.room_id = room_code



func _process(delta: float):

	_heartbeat_timer += delta
	if _heartbeat_timer >= 8.0:
		_heartbeat_timer = 0.0
		_send_heartbeat()

	_process_matchmaking_rules()

	poll_timer += delta
	if poll_timer >= POLL_INTERVAL:
		poll_timer = 0.0
		_poll_room()

func _process_matchmaking_rules():
	if not GameManager.is_matchmaking: return
	if _matchmaking_forfeit_handled: return
	if not guest_joined: return
	if room_code == "": return

	var now_unix_ms: float = Time.get_unix_time_from_system() * 1000.0
	if _matchmaking_deadline_unix_ms <= 0.0:
		_matchmaking_deadline_unix_ms = now_unix_ms + 15000.0

	var my_ready = _is_me_ready()
	var opp_ready = _is_opp_ready()
	if my_ready and opp_ready:
		if GameManager.is_host and not _matchmaking_start_sent:
			_matchmaking_start_sent = true
			_on_start_pressed()
		return

	var remaining_sec = max(0, int(ceil((_matchmaking_deadline_unix_ms - now_unix_ms) / 1000.0)))
	if remaining_sec <= 0:
		_handle_matchmaking_forfeit(my_ready)
		return

	# Update status with countdown without fighting other status updates.
	if my_ready and not opp_ready:
		status_label.text = "Waiting opponent (%ds)..." % remaining_sec
	elif not my_ready:
		status_label.text = "Choose character/skills (%ds)..." % remaining_sec

func _is_me_ready() -> bool:
	return GameManager.selected_character != "" and SkillsManager.selected_skills.size() >= 2 and SkillsManager.selected_passive != ""

func _is_opp_ready() -> bool:
	if GameManager.is_solo: return true
	return guest_joined and _opp_character != "" and _opp_skills.size() >= 2 and _opp_passive != ""

func _handle_matchmaking_forfeit(i_was_ready: bool):
	_matchmaking_forfeit_handled = true

	# Close the room so the other client will see 404 and leave too.
	_delete_room()
	GameManager.current_room = ""

	var now_unix_ms: float = Time.get_unix_time_from_system() * 1000.0
	if not i_was_ready:
		# Fix #10: apply penalty server-side so it persists across restarts
		_apply_matchmaking_penalty(10000)
		GameManager.matchmaking_penalty_until_unix_ms = now_unix_ms + 10000.0
		GameManager.auto_queue_matchmaking = false
	else:
		GameManager.auto_queue_matchmaking = true

	GameManager.is_matchmaking = false
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")

## Fix #10: tell the server to record a matchmaking penalty for this user.
func _apply_matchmaking_penalty(duration_ms: int) -> void:
	if GameManager.user_data.id == 0: return
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r,_c,_h,_b): http.queue_free())
	var body = JSON.stringify({
		"user_id": GameManager.user_data.id,
		"duration_ms": duration_ms
	})
	http.request(GameManager.SERVER_URL + "/api/game/matchmaking-penalty", GameManager.get_auth_headers(), HTTPClient.METHOD_POST, body)

# ── Network ──────────────────────────────────────────────────────────────────

func _send_heartbeat():
	if GameManager.user_data.id == 0: return
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_heartbeat_done.bind(http))
	http.timeout = REQUEST_TIMEOUT_SEC
	var body = JSON.stringify({ "user_id": GameManager.user_data.id })
	http.request(GameManager.SERVER_URL + "/api/game/heartbeat", GameManager.get_auth_headers(), HTTPClient.METHOD_POST, body)

func _on_heartbeat_done(_result, _code, _headers, _body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()

func _sync_selections():
	if room_code == "": return
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_sync_done.bind(http))
	http.timeout = REQUEST_TIMEOUT_SEC
	var body = JSON.stringify({
		"user_id":   my_user_id,
		"character": GameManager.selected_character,
		"skills":    SkillsManager.selected_skills,
		"passive":   SkillsManager.selected_passive
	})
	http.request(GameManager.SERVER_URL + "/api/rooms/" + room_code + "/select", GameManager.get_auth_headers(), HTTPClient.METHOD_PATCH, body)

func _on_sync_done(_result, _code, _headers, _body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()

func _poll_room():
	if room_code == "": return
	if _poll_in_flight: return
	_poll_in_flight = true
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_poll_done.bind(http))
	http.timeout = REQUEST_TIMEOUT_SEC
	var err = http.request(GameManager.SERVER_URL + "/api/rooms/" + room_code, GameManager.get_auth_headers())
	if err != OK:
		_poll_in_flight = false
		if is_instance_valid(http): http.queue_free()

func _on_poll_done(_result, code, _headers, body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()
	_poll_in_flight = false
	if code != 200:
		# Matchmaking forfeits/room closes show up as 404; return to menu.
		if GameManager.is_matchmaking and not _matchmaking_forfeit_handled:
			_handle_matchmaking_forfeit(_is_me_ready())
		return
	var json = JSON.parse_string(body.get_string_from_utf8())
	if not json: return
	var seq = int(json.get("seq", -1))
	if seq >= 0 and _last_room_seq >= 0 and seq < _last_room_seq:
		return # ignore stale/out-of-order poll responses
	if seq >= 0:
		_last_room_seq = seq

	# 1. Update opponent selections from current poll first
	if GameManager.is_host:
		if json.get("guest_id", null) != null:
			guest_joined = true
			player2_name.text = str(json.get("guest_name", "Opponent"))
			
			var g_char = json.get("guest_character")
			_opp_character = str(g_char) if g_char != null else ""
			GameManager.opponent_character = _opp_character
			
			if _opp_character != "":
				player2_tag.text = "Ready: " + _opp_character
			else:
				player2_tag.text = "Joined!"
			
			var g_skills = json.get("guest_skills")
			_opp_skills = g_skills if g_skills != null else []
			
			var g_passive = json.get("guest_passive")
			_opp_passive = str(g_passive) if g_passive != null else ""
		_check_start_ready()
	else:
		player1_name.text = str(json.get("host_name", "Host"))
		
		var h_char = json.get("host_character")
		_opp_character = str(h_char) if h_char != null else ""
		GameManager.opponent_character = _opp_character
		
		if _opp_character != "":
			player1_tag.text = "Ready: " + _opp_character
		else:
			player1_tag.text = "Host"
		
		var h_skills = json.get("host_skills")
		_opp_skills = h_skills if h_skills != null else []
		
		var h_passive = json.get("host_passive")
		_opp_passive = str(h_passive) if h_passive != null else ""
		
		var my_ready   = GameManager.selected_character != "" and SkillsManager.selected_skills.size() >= 2 and SkillsManager.selected_passive != ""
		if my_ready:
			status_label.text = "Waiting for host to start..."
		else:
			status_label.text = "Pick 1 character and 2 skills."

	# 2. Check for game start
	if json.get("status") == "started":
		GameManager.opponent_character = _opp_character
		GameManager.opponent_passive = _opp_passive
		GameManager.match_start_time = float(json.get("started_at", 0))
		print("[Lobby] Starting game | Me: %s (%s) | Opp: %s (%s) | StartTime: %f" % [GameManager.selected_character, SkillsManager.selected_passive, GameManager.opponent_character, GameManager.opponent_passive, GameManager.match_start_time])
		get_tree().change_scene_to_file("res://scenes/game/game.tscn")
		return

# ── Dynamic UI setup ────────────────────────────────────────────────────────

func _setup_ui():
	for c in char_container.get_children(): c.queue_free()
	for c in skill_container.get_children(): c.queue_free()
	
	_char_buttons.clear()
	_skill_buttons.clear()
	_passive_buttons.clear()

	for char_name in CHARACTERS:
		var btn = Button.new()
		btn.text = char_name
		btn.custom_minimum_size = Vector2(0, 50)
		char_container.add_child(btn)
		btn.pressed.connect(_on_char_selected.bind(char_name))
		_char_buttons.append(btn)

	for skill in SKILLS:
		var btn = Button.new()
		btn.text = skill["name"]
		btn.custom_minimum_size = Vector2(0, 40)
		skill_container.add_child(btn)
		btn.pressed.connect(_on_skill_selected.bind(skill["id"]))
		_skill_buttons.append(btn)
		
	for i in range(GameManager.PASSIVES.size()):
		if i < _manual_passive_buttons.size():
			var btn = _manual_passive_buttons[i]
			btn.text = GameManager.PASSIVES[i]["name"]
			# Disconnect any old connections if _setup_ui is called multiple times
			if btn.pressed.is_connected(_on_passive_selected):
				btn.pressed.disconnect(_on_passive_selected)
			btn.pressed.connect(_on_passive_selected.bind(GameManager.PASSIVES[i]["id"]))
			_passive_buttons.append(btn)
		
	_refresh_ui()

func _on_char_selected(char_name: String):
	GameManager.selected_character = char_name
	_refresh_ui()
	_sync_selections()

func _on_skill_selected(skill_id: String):
	SkillsManager.toggle_skill(skill_id)
	_refresh_ui()
	_sync_selections()

func _on_passive_selected(passive_id: String):
	SkillsManager.selected_passive = passive_id
	_refresh_ui()
	_sync_selections()

func _refresh_ui():
	for i in _char_buttons.size():
		_char_buttons[i].modulate = selected_char_color if GameManager.selected_character == CHARACTERS[i] else Color.WHITE
	for i in _skill_buttons.size():
		var id = SKILLS[i]["id"]
		_skill_buttons[i].modulate = selected_skill_color if SkillsManager.selected_skills.has(id) else Color.WHITE
	for i in _passive_buttons.size():
		var id = GameManager.PASSIVES[i]["id"]
		_passive_buttons[i].modulate = selected_passive_color if SkillsManager.selected_passive == id else Color.WHITE
	
	# Update own tag
	if GameManager.is_host:
		if GameManager.selected_character != "":
			player1_tag.text = "Host: " + GameManager.selected_character
		else:
			player1_tag.text = "Host"
	else:
		if GameManager.selected_character != "":
			player2_tag.text = "You: " + GameManager.selected_character
		else:
			player2_tag.text = "You (Guest)"
	
	_check_start_ready()

func _check_start_ready():
	if not GameManager.is_host: return
	var my_ready = _is_me_ready()
	var opp_ready = _is_opp_ready()
	if is_instance_valid(start_button):
		if GameManager.is_matchmaking:
			start_button.hide()
			start_button.disabled = true
		else:
			start_button.disabled = not (my_ready and opp_ready)

	if not guest_joined:
		status_label.text = "Waiting for opponent..."
	elif not my_ready:
		status_label.text = "Pick 1 character, 2 skills, 1 passive."
	elif not opp_ready:
		status_label.text = "Waiting for opponent to choose..."
	else:
		if GameManager.is_matchmaking:
			status_label.text = "Both ready! Starting..."
			if GameManager.is_host and not _matchmaking_start_sent:
				_matchmaking_start_sent = true
				_on_start_pressed()
		else:
			status_label.text = "Both ready! You can start."

# ── Navigation ───────────────────────────────────────────────────────────────

func _on_start_pressed():
	if GameManager.is_solo:
		# Auto-generate an opponent for solo mode
		GameManager.opponent_character = CHARACTERS[randi() % CHARACTERS.size()]
		GameManager.opponent_passive = GameManager.PASSIVES[randi() % GameManager.PASSIVES.size()]["id"]
		print("[Solo] Starting game against AI: %s (Passive: %s)" % [GameManager.opponent_character, GameManager.opponent_passive])
		get_tree().change_scene_to_file("res://scenes/game/game.tscn")
		return
		
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_start_notified.bind(http))
	http.timeout = REQUEST_TIMEOUT_SEC
	http.request(GameManager.SERVER_URL + "/api/rooms/" + room_code + "/start", GameManager.get_auth_headers(), HTTPClient.METHOD_POST)

func _on_start_notified(_result, code, _headers, body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()
	# Capture server start time so host can do correct opponent WPM estimation during resolution.
	if code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json and json.get("room", null) != null:
			GameManager.match_start_time = float(json.room.get("started_at", 0))
	GameManager.opponent_character = _opp_character
	GameManager.opponent_passive = _opp_passive
	get_tree().change_scene_to_file("res://scenes/game/game.tscn")

func _on_back_pressed():
	if GameManager.is_solo:
		_delete_room()
	elif GameManager.is_host:
		_delete_room()
	else:
		_leave_room()
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")

func _on_room_code_input(event):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		DisplayServer.clipboard_set(room_code_label.text)
		status_label.text = "Room code copied!"

func _delete_room():
	if room_code == "": return
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r,_c,_h,_b): http.queue_free())
	http.timeout = REQUEST_TIMEOUT_SEC
	http.request(GameManager.SERVER_URL + "/api/rooms/" + room_code, GameManager.get_auth_headers(), HTTPClient.METHOD_DELETE)

func _leave_room():
	if room_code == "": return
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r,_c,_h,_b): http.queue_free())
	http.timeout = REQUEST_TIMEOUT_SEC
	http.request(GameManager.SERVER_URL + "/api/rooms/" + room_code + "/leave", GameManager.get_auth_headers(), HTTPClient.METHOD_POST)

func _create_room():
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_room_created.bind(http))
	http.timeout = REQUEST_TIMEOUT_SEC
	var body = JSON.stringify({
		"user_id":      my_user_id,
		"display_name": my_name,
		"code":         room_code
	})
	http.request(GameManager.SERVER_URL + "/api/rooms/create", GameManager.get_auth_headers(), HTTPClient.METHOD_POST, body)

func _on_room_created(_result, code, _headers, _body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()
	if code != 200:
		status_label.text = "Failed to create room (code %d)." % code
	else:
		print("[Room] Created OK: ", room_code)

func _generate_code() -> String:
	const CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var code = ""
	for i in 6: code += CHARS[randi() % CHARS.length()]
	return code
