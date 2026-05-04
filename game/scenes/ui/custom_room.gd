extends Control



const POLL_INTERVAL = 2.0

const CHARACTERS = ["Riven", "Zephon", "Liora"]
const SKILLS = [
	{"id": "quick_strike",  "name": "Quick Strike"},
	{"id": "drain_touch",   "name": "Drain Touch"},
	{"id": "whiplash",      "name": "Whiplash"},
	{"id": "soulbreak",     "name": "Soulbreak"},
	{"id": "rupture",       "name": "Rupture"},
	{"id": "deathmark",     "name": "Deathmark"},
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

@export var selected_char_color: Color = Color.GREEN
@export var selected_skill_color: Color = Color.CYAN

var room_code: String   = ""
var my_user_id: int     = 0
var my_name: String     = ""
var poll_timer: float   = 0.0
var guest_joined: bool  = false
var _active_http: Array = []
var _heartbeat_timer: float = 0.0

# Opponent's last known selections (populated from poll)
var _opp_character: String    = ""
var _opp_skills: Array        = []

# Dynamically built button arrays
var _char_buttons: Array      = []
var _skill_buttons: Array     = []

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
			room_code_label.text = room_code
			_create_room()

	if GameManager.is_solo:
		room_code_label.hide()
		if has_node("RoomCodeLabel"):
			$RoomCodeLabel.hide()

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
	if _heartbeat_timer >= 15.0:
		_heartbeat_timer = 0.0
		_send_heartbeat()

	poll_timer += delta
	if poll_timer >= POLL_INTERVAL:
		poll_timer = 0.0
		_poll_room()

# ── Network ──────────────────────────────────────────────────────────────────

func _send_heartbeat():
	if GameManager.user_data.id == 0: return
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_heartbeat_done.bind(http))
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
	var body = JSON.stringify({
		"user_id":   my_user_id,
		"character": GameManager.selected_character,
		"skills":    SkillsManager.selected_skills
	})
	http.request(GameManager.SERVER_URL + "/api/rooms/" + room_code + "/select", GameManager.get_auth_headers(), HTTPClient.METHOD_PATCH, body)

func _on_sync_done(_result, _code, _headers, _body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()

func _poll_room():
	if room_code == "": return
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_poll_done.bind(http))
	http.request(GameManager.SERVER_URL + "/api/rooms/" + room_code, GameManager.get_auth_headers())

func _on_poll_done(_result, code, _headers, body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()
	if code != 200: return
	var json = JSON.parse_string(body.get_string_from_utf8())
	if not json: return

	if json.get("status") == "started":
		get_tree().change_scene_to_file("res://scenes/game/game.tscn")
		return

	if GameManager.is_host:
		if json.get("guest_id", null) != null:
			guest_joined = true
			player2_name.text = str(json.get("guest_name", "Opponent"))
			
			var g_char = json.get("guest_character")
			_opp_character = str(g_char) if g_char != null else ""
			
			if _opp_character != "":
				player2_tag.text = "Ready: " + _opp_character
			else:
				player2_tag.text = "Joined!"
			
			var g_skills = json.get("guest_skills")
			_opp_skills = g_skills if g_skills != null else []
		_check_start_ready()
	else:
		player1_name.text = str(json.get("host_name", "Host"))
		
		var h_char = json.get("host_character")
		_opp_character = str(h_char) if h_char != null else ""
		
		if _opp_character != "":
			player1_tag.text = "Ready: " + _opp_character
		else:
			player1_tag.text = "Host"
		
		var h_skills = json.get("host_skills")
		_opp_skills = h_skills if h_skills != null else []
		var my_ready   = GameManager.selected_character != "" and SkillsManager.selected_skills.size() >= 2
		if my_ready:
			status_label.text = "Waiting for host to start..."
		else:
			status_label.text = "Pick 1 character and 2 skills."

# ── Dynamic UI setup ────────────────────────────────────────────────────────

func _setup_ui():
	for c in char_container.get_children(): c.queue_free()
	for c in skill_container.get_children(): c.queue_free()
	_char_buttons.clear()
	_skill_buttons.clear()

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
	_refresh_ui()

func _on_char_selected(char_name: String):
	GameManager.selected_character = char_name
	_refresh_ui()
	_sync_selections()

func _on_skill_selected(skill_id: String):
	SkillsManager.toggle_skill(skill_id)
	_refresh_ui()
	_sync_selections()

func _refresh_ui():
	for i in _char_buttons.size():
		_char_buttons[i].modulate = selected_char_color if GameManager.selected_character == CHARACTERS[i] else Color.WHITE
	for i in _skill_buttons.size():
		var id = SKILLS[i]["id"]
		_skill_buttons[i].modulate = selected_skill_color if SkillsManager.selected_skills.has(id) else Color.WHITE
	
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
	var my_ready  = GameManager.selected_character != "" and SkillsManager.selected_skills.size() >= 2
	var opp_ready = guest_joined and _opp_character != "" and _opp_skills.size() >= 2
	start_button.disabled = not (my_ready and opp_ready)

	if not guest_joined:
		status_label.text = "Waiting for opponent..."
	elif not my_ready:
		status_label.text = "Pick 1 character and 2 skills."
	elif not opp_ready:
		status_label.text = "Waiting for opponent to choose..."
	else:
		status_label.text = "Both ready! You can start."

# ── Navigation ───────────────────────────────────────────────────────────────

func _on_start_pressed():
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_start_notified.bind(http))
	http.request(GameManager.SERVER_URL + "/api/rooms/" + room_code + "/start", GameManager.get_auth_headers(), HTTPClient.METHOD_POST)

func _on_start_notified(_result, _code, _headers, _body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()
	get_tree().change_scene_to_file("res://scenes/game/game.tscn")

func _on_back_pressed():
	_delete_room()
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
	http.request(GameManager.SERVER_URL + "/api/rooms/" + room_code, GameManager.get_auth_headers(), HTTPClient.METHOD_DELETE)

func _create_room():
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_room_created.bind(http))
	var body = JSON.stringify({
		"user_id":      my_user_id,
		"display_name": my_name,
		"code":         room_code
	})
	http.request(GameManager.SERVER_URL + "/api/rooms/create", GameManager.get_auth_headers(), HTTPClient.METHOD_POST, body)

func _on_room_created(_result, code, _headers, body, http: HTTPRequest):
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
