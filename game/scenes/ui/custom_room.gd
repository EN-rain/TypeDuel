extends Control

const SERVER = "http://34.143.153.96:3000"
const POLL_INTERVAL = 2.0  # seconds between status checks

@onready var room_code_label = $RoomCode
@onready var status_label    = $StatusLabel
@onready var player1_name    = $Player1Name
@onready var player2_name    = $Player2Name
@onready var player2_tag     = $Player2Tag
@onready var start_button    = $StartButton
@onready var player1_tag     = $Player1Tag
@onready var char_btn_1      = $Characters/VBoxContainer/Character1
@onready var char_btn_2      = $Characters/VBoxContainer/Character2
@onready var char_btn_3      = $Characters/VBoxContainer/Character3
@onready var skill_btn_1     = $Skill/VBoxContainer/Skill1
@onready var skill_btn_2     = $Skill/VBoxContainer/Skill2
@onready var skill_btn_3     = $Skill/VBoxContainer/Skill3

var room_code: String = ""
var my_user_id: int   = 0
var my_name: String   = ""
var poll_timer: float = 0.0
var guest_joined: bool = false
var _active_http: Array = []  # track pending requests

func _ready():
	my_user_id = GameManager.user_data.id
	my_name    = GameManager.user_data.display_name
	if my_name == "":
		my_name = GameManager.user_data.username

	if not GameManager.is_host:
		room_code = GameManager.current_room
		room_code_label.text = room_code
		player2_name.text = my_name
		player2_tag.text = "You (Guest)"
		player1_name.text = "Host"
		player1_tag.text = "Waiting for host..."
		status_label.text = "Joined successfully. Waiting for host to start."
		guest_joined = true
		start_button.disabled = true
	else:
		player1_name.text = my_name
		if GameManager.current_room != "":
			room_code = GameManager.current_room
			room_code_label.text = room_code
			guest_joined = true
			_poll_room() # Initial poll to get guest info
		else:
			room_code = _generate_code()
			room_code_label.text = room_code
			_create_room()
	
	if GameManager.is_solo:
		room_code_label.hide()
		$RoomCode.hide()
	
	_setup_characters()
	_setup_copy_logic()

func _setup_copy_logic():
	$RoomCode.mouse_filter = Control.MOUSE_FILTER_STOP
	$RoomCode.gui_input.connect(_on_room_code_input)

func _on_room_code_input(event):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		DisplayServer.clipboard_set($RoomCode.text)
		status_label.text = "Room code copied to clipboard!"

func _setup_characters():
	char_btn_1.text = "Riven"
	char_btn_2.text = "Zephon"
	char_btn_3.text = "Liora"
	
	char_btn_1.pressed.connect(_on_char_selected.bind("Riven"))
	char_btn_2.pressed.connect(_on_char_selected.bind("Zephon"))
	char_btn_3.pressed.connect(_on_char_selected.bind("Liora"))
	
	skill_btn_1.text = "Quick Strike"
	skill_btn_2.text = "Drain Touch"
	skill_btn_3.text = "Whiplash"
	
	skill_btn_1.pressed.connect(_on_skill_selected.bind("quick_strike"))
	skill_btn_2.pressed.connect(_on_skill_selected.bind("drain_touch"))
	skill_btn_3.pressed.connect(_on_skill_selected.bind("whiplash"))
	
	_update_ui_selection()

func _on_char_selected(char_name: String):
	GameManager.selected_character = char_name
	status_label.text = "Selected Character: " + char_name
	_update_ui_selection()

func _on_skill_selected(skill_id: String):
	SkillsManager.toggle_skill(skill_id)
	_update_ui_selection()

func _update_ui_selection():
	# Update Characters
	char_btn_1.modulate = Color.GREEN if GameManager.selected_character == "Riven" else Color.WHITE
	char_btn_2.modulate = Color.GREEN if GameManager.selected_character == "Zephon" else Color.WHITE
	char_btn_3.modulate = Color.GREEN if GameManager.selected_character == "Liora" else Color.WHITE
	
	# Update Skills
	skill_btn_1.modulate = Color.CYAN if SkillsManager.selected_skills.has("quick_strike") else Color.WHITE
	skill_btn_2.modulate = Color.CYAN if SkillsManager.selected_skills.has("drain_touch") else Color.WHITE
	skill_btn_3.modulate = Color.CYAN if SkillsManager.selected_skills.has("whiplash") else Color.WHITE

func _process(delta: float):
	if guest_joined:
		return
	poll_timer += delta
	if poll_timer >= POLL_INTERVAL:
		poll_timer = 0.0
		_poll_room()

# ── Room creation ───────────────────────────────────────────────────────────

func _create_room():
	var http = HTTPRequest.new()
	add_child(http)
	_active_http.append(http)
	http.request_completed.connect(_on_room_created.bind(http))
	var body = JSON.stringify({
		"user_id":      my_user_id,
		"display_name": my_name,
		"code":         room_code
	})
	http.request(SERVER + "/api/rooms/create",
		["Content-Type: application/json"], HTTPClient.METHOD_POST, body)

func _on_room_created(_result, code, _headers, _body, http):
	_free_http(http)
	if code != 200:
		status_label.text = "Failed to create room. Check connection."

# ── Room polling ────────────────────────────────────────────────────────────

func _poll_room():
	var http = HTTPRequest.new()
	add_child(http)
	_active_http.append(http)
	http.request_completed.connect(_on_poll_done.bind(http))
	http.request(SERVER + "/api/rooms/" + room_code)

func _on_poll_done(_result, code, _headers, body, http):
	_free_http(http)
	if code != 200:
		return
	var json = JSON.parse_string(body.get_string_from_utf8())
	if json and json.get("guest_id", null) != null:
		guest_joined = true
		player2_name.text = json.get("guest_name", "Opponent")
		player2_tag.text  = "Joined!"
		status_label.text = "Opponent found! Ready to start."
		start_button.disabled = false

# ── Navigation ──────────────────────────────────────────────────────────────

func _on_start_pressed():
	_delete_room()
	get_tree().change_scene_to_file("res://scenes/ui/skill_selection.tscn")

func _on_back_pressed():
	_delete_room()
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")

func _delete_room():
	# Fire and forget — close the room on the server
	var http = HTTPRequest.new()
	add_child(http)
	http.request(SERVER + "/api/rooms/" + room_code,
		[], HTTPClient.METHOD_DELETE)

# ── Helpers ─────────────────────────────────────────────────────────────────

func _generate_code() -> String:
	const CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var code = ""
	for i in 6:
		code += CHARS[randi() % CHARS.length()]
	return code

func _free_http(http: HTTPRequest):
	_active_http.erase(http)
	http.queue_free()
