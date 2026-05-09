extends Control

const POLL_INTERVAL = 0.5
const REQUEST_TIMEOUT_SEC = 5.0

const CHARACTERS = ["Riven", "Zephon", "Liora"]
const SKILLS = [
	{"id": "quickslash", "name": "Quickslash (2M)"},
	{"id": "whiplash",   "name": "Whiplash (2M)"},
	{"id": "soulbreak",  "name": "Soulbreak (3M)"},
]

const PIXEL_FONT = preload("res://assets/fonts/pixel_operator/PixelOperatorHB.ttf")
const MatchmakingController = preload("res://scripts/domain/matchmaking_controller.gd")
const LobbyNetworkService = preload("res://scripts/services/lobby_network_service.gd")


@onready var room_code_label  = $RoomCode
@onready var status_label     = $CenterPlaceholder/StatusLabel
@onready var player1_name     = $CenterPlaceholder/HBoxContainer/Player1Name
@onready var player2_name     = $CenterPlaceholder/HBoxContainer/Player2Name
@onready var player2_tag      = $CenterPlaceholder/HBoxContainer2/Player2Tag
@onready var start_button     = $StartButton
@onready var player1_tag      = $CenterPlaceholder/HBoxContainer2/Player1Tag
@onready var countdown_timer_label = null  # Created dynamically if needed
@onready var scene_anim_player = $AnimationPlayer

# Center preview sprites
@onready var _preview_p1: AnimatedSprite2D = $CenterPlaceholder/HBoxContainer3/Player1/TextureRect/AnimatedSprite2D
@onready var _preview_p2: AnimatedSprite2D = $CenterPlaceholder/HBoxContainer3/Player2/TextureRect/AnimatedSprite2D

# Info labels
@onready var _innate_label: Label = $InnateAbility
@onready var _other_info_label: Label = $OtherInfo
@onready var _skill_hint_label: Label = $CenterPlaceholder/Label
@onready var _passive_hint_label: Label = $Passive/Label

# Character buttons
@onready var char_button_1 = $Characters/VBoxContainer/Character1
@onready var char_button_2 = $Characters/VBoxContainer/Character2
@onready var char_button_3 = $Characters/VBoxContainer/Character3

# Skill buttons
@onready var skill_button_1 = $Skill/hBoxContainer/Skill1
@onready var skill_button_2 = $Skill/hBoxContainer/Skill2
@onready var skill_button_3 = $Skill/hBoxContainer/Skill3

# Passive buttons
@onready var passive_button_1 = $Passive/HBoxContainer/VBoxContainer1/Passive1
@onready var passive_button_2 = $Passive/HBoxContainer/VBoxContainer1/Passive2
@onready var passive_button_3 = $Passive/HBoxContainer/VBoxContainer2/Passive3
@onready var passive_button_4 = $Passive/HBoxContainer/VBoxContainer2/Passive4
@onready var passive_button_5 = $Passive/HBoxContainer/VBoxContainer3/Passive5

@export var selected_char_color: Color = Color.GREEN
@export var selected_skill_color: Color = Color.CYAN
@export var selected_passive_color: Color = Color.PURPLE

# ── Character preview data ────────────────────────────────────────────────────
# Maps character name → SpriteFrames resource path and idle animation name.
# Zephon uses a different idle animation name than the other two.
const CHAR_SPRITE_FRAMES = {
	"Riven":  "res://assets/spriteframes/riven.tres",
	"Zephon": "res://assets/spriteframes/zephone.tres",
	"Liora":  "res://assets/spriteframes/leora.tres",
}
const CHAR_IDLE_ANIM = {
	"Riven":  "idle",
	"Zephon": "zephon-idle",
	"Liora":  "idle",
}

# ── Innate / skill / passive descriptions ─────────────────────────────────────
const CHAR_INNATE_TEXT = {
	"Riven":  "Bloodlust: Every round she deals damage she loses 3HP. Win 2 consecutive rounds to pause self-damage and reset the streak.",
	"Zephon": "Overdrive: When Mana reaches 9 or higher, gain +5 bonus damage to your attack. Also gains +1 extra Mana per accurate word when WPM > 80.",
	"Liora":  "Grace: Every round accuracy above 95% heals 3HP. Capped at 15HP total per match.",
}
const SKILL_HOVER_TEXT = {
	"quickslash": "Quickslash (2M): WPM-based attack. Deals more damage the faster you type. Bonus ×1.1 on win, ×1.2 with a win streak, ×1.2 extra on full power.",
	"whiplash":   "Whiplash (2M): Accuracy-based attack. Deals ×2 damage if the opponent had a win streak. Also drains 1 Mana from the target on win.",
	"soulbreak":  "Soulbreak (3M): WPM-based heavy attack. Steals 2 Mana from the opponent on win (4 on full power). +15% bonus if you have 8+ Mana.",
}
const PASSIVE_HOVER_TEXT = {
	"reversal": "Reversal: When you finish first, one random untyped word in the opponent's sentence has its letters reversed.",
	"jumble":   "Jumble: When your Mana reaches 7 or higher, the remaining words in the opponent's sentence are shuffled.",
	"phantom":  "Phantom: Randomly swaps two untyped words in the opponent's sentence. Stacks up to 3 times with high accuracy.",
	"stutter":  "Stutter: Duplicates a random word in the opponent's sentence, forcing them to type it twice.",
	"erosion":  "Erosion: Every 3 accurately typed words, replaces a random character in one of the opponent's upcoming words with an underscore.",
}

var room_code: String   = ""
var my_user_id: int     = 0
var my_name: String     = ""
var poll_timer: float   = 0.0
var guest_joined: bool  = false
var _heartbeat_timer: float = 0.0
var _lobby_ready_time: float = 0.0  # time when lobby finished loading
var _poll_in_flight: bool = false

# Opponent's last known selections (populated from poll)
var _opp_character: String    = ""
var _opp_skills: Array        = []
var _opp_passive: String      = ""

# Lobby network/ordering state
var _last_room_seq: int = -1
var _last_server_now_ms: float = 0.0
var _opponent_left_lobby: bool = false
var _sync_in_flight: bool = false
var _creating_room: bool = false

var matchmaking_controller: MatchmakingController

# Dynamically built button arrays
var _char_buttons: Array      = []
var _skill_buttons: Array     = []
var _passive_buttons: Array   = []

func _enter_tree():
	# Seek animation to t=0 before first frame so nodes start invisible — prevents blink
	if has_node("AnimationPlayer"):
		var ap = get_node("AnimationPlayer")
		if ap.has_animation(&"intro"):
			ap.stop()
			ap.seek(0.0, true)

func _ready():
	SoundManager.play_music("gameplay")
	if scene_anim_player != null and scene_anim_player.has_animation(&"intro"):
		scene_anim_player.play(&"intro")

	# Reset all lobby selections so previous match choices don't carry over
	GameManager.selected_character = ""
	SkillsManager.selected_skills = []
	SkillsManager.selected_passive = ""

	my_user_id = GameManager.user_data.id
	my_name    = GameManager.user_data.display_name
	if my_name == "":
		my_name = GameManager.user_data.username

	# Grace period — don't treat 404/finished as "opponent left" for the first 3s
	# For rematch, the room already exists so use a shorter grace period
	var grace = 5.0 if GameManager.is_matchmaking else 3.0
	_lobby_ready_time = Time.get_ticks_msec() / 1000.0 + grace
	matchmaking_controller = MatchmakingController.new()

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
		player1_tag.text  = "Host"
		player2_name.text = "Waiting..."
		player2_tag.text  = "Waiting..."
		if GameManager.current_room != "":
			room_code = GameManager.current_room
			room_code_label.text = room_code
			guest_joined = true
			_poll_room()
		else:
			room_code = _generate_code()
			GameManager.current_room = room_code
			room_code_label.text = room_code
			_creating_room = true
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
		status_label.text = "Searching for opponent..."
		
		# Create countdown timer label for matchmaking
		countdown_timer_label = Label.new()
		countdown_timer_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
		countdown_timer_label.offset_top = 50
		countdown_timer_label.offset_left = -150
		countdown_timer_label.offset_right = 150
		countdown_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		countdown_timer_label.add_theme_font_override("font", PIXEL_FONT)
		countdown_timer_label.add_theme_font_size_override("font_size", 36)
		countdown_timer_label.add_theme_color_override("font_color", Color.WHITE)
		countdown_timer_label.text = ""
		add_child(countdown_timer_label)

	# Click to copy
	room_code_label.mouse_filter = Control.MOUSE_FILTER_STOP
	# Signal connection for copying room code is defined in the .tscn file

	status_label.add_theme_font_override("font", PIXEL_FONT)
	_setup_ui()
	if not GameManager.is_solo and room_code != "" and not _creating_room:
		VoiceManager.join_room(room_code)

func _process(delta: float):

	_heartbeat_timer += delta
	if _heartbeat_timer >= 8.0:
		_heartbeat_timer = 0.0
		_send_heartbeat()

	_process_matchmaking_rules()

	# Stop polling once countdown has started — avoids "Already launching" spam
	if _launching: return

	poll_timer += delta
	if poll_timer >= POLL_INTERVAL:
		poll_timer = 0.0
		_poll_room()

func _process_matchmaking_rules():
	if not GameManager.is_matchmaking: return
	if matchmaking_controller.is_forfeit_handled(): return
	if room_code == "": return

	if not guest_joined:
		status_label.text = "Searching for opponent..."
		if countdown_timer_label:
			countdown_timer_label.text = ""
		return

	var my_ready = _is_me_ready()
	var opp_ready = _is_opp_ready()
	var state = matchmaking_controller.update(
		GameManager.is_host,
		my_ready,
		opp_ready,
		_last_server_now_ms,
		Time.get_unix_time_from_system() * 1000.0
	)

	if state.forfeit_triggered:
		_handle_matchmaking_forfeit(state.forfeit_i_was_ready)
		return

	status_label.text = state.status_text

	if countdown_timer_label:
		if state.should_start:
			countdown_timer_label.text = "Starting..."
		else:
			countdown_timer_label.text = state.get("countdown_label_text", "")
		countdown_timer_label.modulate = state.countdown_color

	if state.should_start:
		var role = "HOST" if GameManager.is_host else "GUEST"
		print("[Lobby][%s] Both players ready, sending start request..." % role)
		_on_start_pressed()

func _is_me_ready() -> bool:
	return GameManager.selected_character != "" and SkillsManager.selected_skills.size() >= 2 and SkillsManager.selected_passive != ""

func _room_has_leave_signal(room_json: Dictionary) -> bool:
	var forfeit = room_json.get("forfeit", null)
	if forfeit is Dictionary:
		var reason = str(forfeit.get("reason", ""))
		return reason == "leave" or reason == "disconnect_timeout"
	return false

func _is_opp_ready() -> bool:
	if GameManager.is_solo: return true
	return guest_joined and _opp_character != "" and _opp_skills.size() >= 2 and _opp_passive != ""

func _handle_matchmaking_forfeit(i_was_ready: bool):
	if matchmaking_controller.is_forfeit_handled(): return
	matchmaking_controller.mark_forfeit_handled()
	var role = "HOST" if GameManager.is_host else "GUEST"
	print("[Lobby][%s] Matchmaking forfeit | was_ready=%s" % [role, i_was_ready])

	# Notify server to close/leave so the other client sees 404
	if GameManager.is_host:
		_delete_room()
	else:
		_leave_room()
	
	GameManager.current_room = ""

	var now_unix_ms: float = Time.get_unix_time_from_system() * 1000.0
	if not i_was_ready:
		# Apply penalty server-side so it persists
		_apply_matchmaking_penalty(10000)
		GameManager.matchmaking_penalty_until_unix_ms = now_unix_ms + 10000.0
		GameManager.auto_queue_matchmaking = false
	else:
		GameManager.auto_queue_matchmaking = true

	GameManager.is_matchmaking = false
	get_tree().change_scene_to_file("res://scenes/ui/menus/main_menu.tscn")

## tell the server to record a matchmaking penalty for this user.
func _apply_matchmaking_penalty(duration_ms: int) -> void:
	if GameManager.user_data.id == 0: return
	LobbyNetworkService.apply_matchmaking_penalty(self, GameManager.user_data.id, duration_ms)

# ── Network ──────────────────────────────────────────────────────────────────

func _send_heartbeat():
	if GameManager.user_data.id == 0: return
	LobbyNetworkService.send_heartbeat(self, GameManager.user_data.id, _on_heartbeat_done)

func _on_heartbeat_done(_result, _code, _headers, _body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()

func _sync_selections():
	if room_code == "": return
	if _sync_in_flight: return  # Don't stack sync requests
	_sync_in_flight = true
	LobbyNetworkService.sync_selections(self, room_code, my_user_id, GameManager.selected_character, SkillsManager.selected_skills, SkillsManager.selected_passive, _on_sync_done)

func _on_sync_done(_result, _code, _headers, _body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()
	_sync_in_flight = false
	if _code != 200:
		print("[Lobby][Sync] Selection sync failed | code=%d result=%d" % [_code, _result])

func _poll_room():
	if room_code == "": return
	if _poll_in_flight: return  # Don't stack poll requests
	_poll_in_flight = true
	LobbyNetworkService.poll_room(self, room_code, _on_poll_done)

func _on_poll_done(_result, code, _headers, body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()
	_poll_in_flight = false
	if code != 200:
		if code != 404:
			return
		var past_grace = (Time.get_ticks_msec() / 1000.0) >= _lobby_ready_time
		if GameManager.is_matchmaking and not matchmaking_controller.is_forfeit_handled() and past_grace:
			# If we are matched and the room is gone, it means opponent left.
			# We only ignore it during selection to avoid transient errors, but if it's
			# persistent (repeated 404), we must treat it as authoritative.
			# After 10s of lobby life, we stop being "graceful" about selections.
			var selection_grace = (Time.get_ticks_msec() / 1000.0) < (_lobby_ready_time + 7.0)
			if _is_me_ready() or not selection_grace:
				_opponent_left_lobby = true
				_show_opponent_left_popup()
			# else: ignore for a few more seconds to see if it recovers
		else:
			_leave_and_menu()
		return
	var json = JSON.parse_string(body.get_string_from_utf8())
	if not json: return

	# Heal transient selection desync: if local choice differs from server snapshot,
	# resend once on the next poll cycle so readiness can converge.
	# Skip if a sync is already in flight to avoid stacking requests.
	if not _sync_in_flight and _is_local_selection_out_of_sync(json):
		print("[Lobby][Sync] Local/server selection mismatch detected, re-syncing...")
		_sync_selections()

	# 0. Check for room termination (forfeit/finish) before updating data
	if json.get("status") == "finished":
		if not _room_has_leave_signal(json):
			return
		var past_grace = (Time.get_ticks_msec() / 1000.0) >= _lobby_ready_time
		if GameManager.is_matchmaking and not matchmaking_controller.is_forfeit_handled() and past_grace:
			var selection_grace = (Time.get_ticks_msec() / 1000.0) < (_lobby_ready_time + 7.0)
			if _is_me_ready() or not selection_grace:
				_opponent_left_lobby = true
				_show_opponent_left_popup()
			# else: ignore transient finished state while we're still selecting
		elif not GameManager.is_matchmaking:
			_leave_and_menu()
		return
	var server_now = json.get("server_now", null)
	if server_now != null:
		_last_server_now_ms = float(server_now)
		var mm_deadline = json.get("matchmaking_deadline_at", null)
		if mm_deadline != null and float(mm_deadline) > 0.0:
			matchmaking_controller.set_deadline(float(mm_deadline))
	var seq = int(json.get("seq", -1))
	if seq >= 0 and _last_room_seq >= 0 and seq < _last_room_seq:
		return # ignore stale/out-of-order poll responses
	if seq >= 0:
		_last_room_seq = seq

	# 1. Update opponent selections from current poll first
	if GameManager.is_host:
		var guest_id_now = json.get("guest_id", null)
		if guest_id_now != null:
			# Guest is present
			if not guest_joined:
				# Guest just joined
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
		else:
			# Guest left - check if we were matched before
			var past_grace = (Time.get_ticks_msec() / 1000.0) >= _lobby_ready_time
			if guest_joined and GameManager.is_matchmaking and not matchmaking_controller.is_forfeit_handled() and past_grace:
				# Opponent left after joining - show popup and return to menu
				_opponent_left_lobby = true
				_show_opponent_left_popup()
				return
			
			# Guest hasn't joined yet or already handled
			guest_joined = false
			player2_name.text = "Waiting..."
			player2_tag.text = "Waiting..."
			_opp_character = ""
			_opp_skills = []
			_opp_passive = ""
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
		if not GameManager.is_matchmaking:
			if my_ready:
				status_label.text = "Waiting for host to start..."
			else:
				status_label.text = "Pick 1 character and 2 skills."

	_refresh_ui()
	
	# 2. Check for game start
	if json.get("status") == "started":
		# Guard: only process game start once
		if _launching:
			print("[Lobby] Already launching, skipping duplicate start trigger")
			return
			
		# Ensure opponent data is set before launching
		if _opp_character == "":
			if GameManager.is_host:
				var g_char = json.get("guest_character")
				_opp_character = str(g_char) if g_char != null else ""
			else:
				var h_char = json.get("host_character")
				_opp_character = str(h_char) if h_char != null else ""
		
		if _opp_passive == "":
			if GameManager.is_host:
				var g_passive = json.get("guest_passive")
				_opp_passive = str(g_passive) if g_passive != null else ""
			else:
				var h_passive = json.get("host_passive")
				_opp_passive = str(h_passive) if h_passive != null else ""
		
		GameManager.opponent_character = _opp_character
		GameManager.opponent_passive = _opp_passive
		GameManager.opponent_name = str(json.get("guest_name", "Opponent")) if GameManager.is_host else str(json.get("host_name", "Opponent"))
		GameManager.match_start_time = float(json.get("started_at", 0))
		
		var role = "HOST" if GameManager.is_host else "GUEST"
		print("[Lobby][%s] Game start detected | Me: %s (%s) | Opp: %s (%s) | StartTime: %f" % [
			role,
			GameManager.selected_character, 
			SkillsManager.selected_passive, 
			GameManager.opponent_character, 
			GameManager.opponent_passive, 
			GameManager.match_start_time
		])
		
		if is_inside_tree():
			print("[Lobby][%s] Launching countdown..." % role)
			_launch_game_with_countdown()
		else:
			print("[Lobby][%s] ERROR: Not in tree, cannot launch!" % role)
		return

func _is_local_selection_out_of_sync(room_json: Dictionary) -> bool:
	var my_char = GameManager.selected_character
	var my_skills: Array = SkillsManager.selected_skills
	var my_passive = SkillsManager.selected_passive

	var server_char = ""
	var server_skills: Array = []
	var server_passive = ""

	if GameManager.is_host:
		var c = room_json.get("host_character", null)
		server_char = str(c) if c != null else ""
		var s = room_json.get("host_skills", [])
		server_skills = s if s is Array else []
		var p = room_json.get("host_passive", null)
		server_passive = str(p) if p != null else ""
	else:
		var c = room_json.get("guest_character", null)
		server_char = str(c) if c != null else ""
		var s = room_json.get("guest_skills", [])
		server_skills = s if s is Array else []
		var p = room_json.get("guest_passive", null)
		server_passive = str(p) if p != null else ""

	if my_char != server_char:
		return true
	if my_passive != server_passive:
		return true
	if my_skills.size() != server_skills.size():
		return true
	for skill_id in my_skills:
		if not server_skills.has(skill_id):
			return true
	return false

# ── Dynamic UI setup ────────────────────────────────────────────────────────

# ── Preview / info helpers ────────────────────────────────────────────────────

func _update_player_preview(char_name: String) -> void:
	if not is_instance_valid(_preview_p1): return
	if char_name == "" or not CHAR_SPRITE_FRAMES.has(char_name):
		_preview_p1.visible = false
		return
	var frames = load(CHAR_SPRITE_FRAMES[char_name]) as SpriteFrames
	if frames == null: return
	_preview_p1.sprite_frames = frames
	var anim = CHAR_IDLE_ANIM.get(char_name, "idle")
	if _preview_p1.sprite_frames.has_animation(anim):
		_preview_p1.play(anim)
	_preview_p1.visible = true

func _update_opponent_preview(char_name: String) -> void:
	if not is_instance_valid(_preview_p2): return
	if char_name == "" or not CHAR_SPRITE_FRAMES.has(char_name):
		_preview_p2.visible = false
		return
	var frames = load(CHAR_SPRITE_FRAMES[char_name]) as SpriteFrames
	if frames == null: return
	_preview_p2.sprite_frames = frames
	var anim = CHAR_IDLE_ANIM.get(char_name, "idle")
	if _preview_p2.sprite_frames.has_animation(anim):
		_preview_p2.play(anim)
	_preview_p2.visible = true

func _update_innate_info(char_name: String) -> void:
	if not is_instance_valid(_innate_label): return
	if char_name == "" or not CHAR_INNATE_TEXT.has(char_name):
		_innate_label.text = "Select a character to view innate ability."
		return
	_innate_label.text = CHAR_INNATE_TEXT[char_name]

func _show_other_info(text: String) -> void:
	if not is_instance_valid(_other_info_label): return
	_other_info_label.text = text

func _clear_other_info() -> void:
	if not is_instance_valid(_other_info_label): return
	_other_info_label.text = "Hover a skill or passive to see details."

func _setup_ui():
	"""Setup button arrays and initial UI state"""
	# Build button arrays from scene nodes
	_char_buttons = [char_button_1, char_button_2, char_button_3]
	_skill_buttons = [skill_button_1, skill_button_2, skill_button_3]
	_passive_buttons = [passive_button_1, passive_button_2, passive_button_3, passive_button_4, passive_button_5]
	
	# Update button texts from data
	for i in range(min(CHARACTERS.size(), _char_buttons.size())):
		_char_buttons[i].text = CHARACTERS[i]
	
	# Skill buttons have no text — icons only
	
	for i in range(min(GameManager.PASSIVES.size(), _passive_buttons.size())):
		_passive_buttons[i].text = ""

	# Hide center previews until characters are selected
	if is_instance_valid(_preview_p1): _preview_p1.visible = false
	if is_instance_valid(_preview_p2): _preview_p2.visible = false

	# Set initial placeholder text
	_update_innate_info("")
	_clear_other_info()

	_refresh_ui()

func _on_char_selected(char_name: String):
	print("[Lobby] Character selected: %s" % char_name)
	GameManager.selected_character = char_name
	_update_player_preview(char_name)
	_update_innate_info(char_name)
	_refresh_ui()
	_sync_selections()

func _on_skill_selected(skill_id: String):
	SkillsManager.toggle_skill(skill_id)
	print("[Lobby] Skills updated: %s" % str(SkillsManager.selected_skills))
	_refresh_ui()
	_sync_selections()

func _on_passive_selected(passive_id: String):
	print("[Lobby] Passive selected: %s" % passive_id)
	SkillsManager.selected_passive = passive_id
	_refresh_ui()
	_sync_selections()

func _refresh_ui():
	for i in _char_buttons.size():
		var sprite := _char_buttons[i].get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		var is_selected = GameManager.selected_character == CHARACTERS[i]
		# Remove the green tint — use animation state instead:
		# selected = playing idle, unselected = paused on first frame
		_char_buttons[i].modulate = Color.WHITE
		if sprite != null:
			var anim = CHAR_IDLE_ANIM.get(CHARACTERS[i], "idle")
			if is_selected:
				if not sprite.is_playing():
					sprite.play(anim)
			else:
				sprite.stop()
				sprite.frame = 0
	for i in _skill_buttons.size():
		var id = SKILLS[i]["id"]
		var is_selected = SkillsManager.selected_skills.has(id)
		_skill_buttons[i].modulate = Color(1, 1, 1, 0.7) if is_selected else Color.WHITE
	for i in _passive_buttons.size():
		var id = GameManager.PASSIVES[i]["id"]
		var is_selected = SkillsManager.selected_passive == id
		_passive_buttons[i].modulate = Color(1, 1, 1, 0.7) if is_selected else Color.WHITE
	
	# Sync preview sprites with current selections
	_update_player_preview(GameManager.selected_character)
	_update_opponent_preview(_opp_character)

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

	# Dynamic skill hint label
	if is_instance_valid(_skill_hint_label):
		var count = SkillsManager.selected_skills.size()
		if count == 0:
			_skill_hint_label.text = "Choose 2 skills"
		elif count == 1:
			_skill_hint_label.text = "1 more skill"
		else:
			_skill_hint_label.text = "Done"

	# Dynamic passive hint label
	if is_instance_valid(_passive_hint_label):
		if SkillsManager.selected_passive != "":
			_passive_hint_label.text = "Done"
		else:
			_passive_hint_label.text = "Choose a Passive"

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

	# During matchmaking, _process_matchmaking_rules owns the status label exclusively.
	if GameManager.is_matchmaking: return

	if not guest_joined:
		status_label.text = "Waiting for opponent..."
	elif not my_ready:
		status_label.text = "Pick 1 character, 2 skills, 1 passive."
	elif not opp_ready:
		status_label.text = "Waiting for opponent to choose..."
	else:
		status_label.text = "Both ready! You can start."

# ── Navigation ───────────────────────────────────────────────────────────────

func _on_start_pressed():
	if GameManager.is_solo:
		GameManager.opponent_character = CHARACTERS[randi() % CHARACTERS.size()]
		GameManager.opponent_passive = GameManager.PASSIVES[randi() % GameManager.PASSIVES.size()]["id"]
		print("[Solo] Starting game against AI: %s (Passive: %s)" % [GameManager.opponent_character, GameManager.opponent_passive])
		_launch_game_with_countdown()
		return
	
	print("[Lobby][HOST] Sending start request to server for room: %s" % room_code)
	LobbyNetworkService.start_room(self, room_code, _on_start_notified)

func _on_start_notified(_result, code, _headers, body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()
	
	print("[Lobby][HOST] Start request response: code=%d" % code)
	
	if code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json and json.get("room", null) != null:
			GameManager.match_start_time = float(json.room.get("started_at", 0))
			print("[Lobby][HOST] Match start time set: %f" % GameManager.match_start_time)
	elif code == 409:
		# Server rejected start — players not fully ready on server side yet.
		# Reset flag but enforce a 1s cooldown before retrying to avoid hammering the server.
		print("[Lobby][HOST] 409 — not ready on server yet, will retry after sync")
		matchmaking_controller.schedule_start_retry(1.0)
	else:
		# Unexpected error — reset so the host can retry
		print("[Lobby][HOST] Start request failed (code=%d) — resetting for retry" % code)
		matchmaking_controller.schedule_start_retry(0.0)
		status_label.text = "Failed to start (code %d). Retrying..." % code
	
	GameManager.opponent_character = _opp_character
	GameManager.opponent_passive = _opp_passive
	# Don't launch here — let the poll detect status=="started" so both clients
	# start the countdown at the same time (within one poll interval of each other)

func _on_back_pressed():
	if GameManager.is_matchmaking:
		if matchmaking_controller.is_forfeit_handled():
			return # Already on our way out
			
		# Dodging penalty check:
		# If we are the host and a guest has joined, OR if we are the guest
		# (who only exists in the room if matched), leaving now is a 'dodge'.
		var is_matched = (GameManager.is_host and guest_joined) or (not GameManager.is_host)
		
		if is_matched:
			_handle_matchmaking_forfeit(false)
			return
		else:
			# Just searching (host waiting for guest) - safe to leave
			_leave_and_menu()
			return

	_leave_and_menu()

func _leave_and_menu():
	if GameManager.is_solo or GameManager.is_host:
		_delete_room()
	else:
		_leave_room()

	TransitionManager.back("res://scenes/ui/menus/main_menu.tscn")

func _on_room_code_input(event):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		DisplayServer.clipboard_set(room_code_label.text)
		status_label.text = "Room code copied!"

func _delete_room():
	if room_code == "": return
	VoiceManager.leave_room()
	LobbyNetworkService.delete_room(self, room_code)

func _leave_room():
	if room_code == "": return
	VoiceManager.leave_room()
	LobbyNetworkService.leave_room(self, room_code)

func _create_room():
	LobbyNetworkService.create_room(self, my_user_id, my_name, room_code, _on_room_created)

func _on_room_created(_result, code, _headers, _body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()
	_creating_room = false
	if code != 200:
		status_label.text = "Failed to create room (code %d)." % code
	else:
		print("[Room] Created OK: ", room_code)
		if not GameManager.is_solo:
			VoiceManager.join_room(room_code)

func _generate_code() -> String:
	const CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var code = ""
	for i in 6: code += CHARS[randi() % CHARS.length()]
	return code

## Transition to game scene with a "Get Ready" countdown
## Shows a 3-second countdown overlay (lobby stays visible behind it)
var _launching: bool = false
var _countdown_canvas: CanvasLayer = null

func _launch_game_with_countdown() -> void:
	var role = "HOST" if GameManager.is_host else "GUEST"
	
	if _launching:
		print("[Lobby][%s] _launch_game_with_countdown called but already launching" % role)
		return
	
	print("[Lobby][%s] Starting countdown sequence..." % role)
	_launching = true
	
	# Snap animation to fully-visible end state so lobby shows behind the overlay
	if scene_anim_player != null:
		if scene_anim_player.has_animation(&"intro"):
			scene_anim_player.stop()
			scene_anim_player.seek(scene_anim_player.get_animation(&"intro").length, true)
		else:
			scene_anim_player.stop()
	modulate.a = 1.0
	
	# Add overlay to a CanvasLayer — child of this scene, freed automatically on scene change
	_countdown_canvas = CanvasLayer.new()
	_countdown_canvas.layer = 10
	add_child(_countdown_canvas)
	
	var overlay = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_countdown_canvas.add_child(overlay)
	
	var bg = ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.7)
	overlay.add_child(bg)
	
	var ready_label = Label.new()
	ready_label.set_anchors_preset(Control.PRESET_CENTER)
	ready_label.offset_top = -120
	ready_label.offset_bottom = -70
	ready_label.offset_left = -200
	ready_label.offset_right = 200
	ready_label.text = "GET READY!"
	ready_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ready_label.add_theme_font_override("font", PIXEL_FONT)
	ready_label.add_theme_font_size_override("font_size", 48)
	ready_label.add_theme_color_override("font_color", Color.WHITE)
	overlay.add_child(ready_label)
	
	var label = Label.new()
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.offset_left = -100
	label.offset_right = 100
	label.offset_top = -60
	label.offset_bottom = 80
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", PIXEL_FONT)
	label.add_theme_font_size_override("font_size", 120)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 8)
	overlay.add_child(label)
	
	print("[Lobby][%s] Countdown overlay created, starting 3-2-1..." % role)
	
	# Countdown with immediate opponent leave detection
	for i in range(3, 0, -1):
		if not is_instance_valid(label): 
			print("[Lobby][%s] Label invalid during countdown" % role)
			return
		# Check if opponent left (immediate detection, not just flag)
		if matchmaking_controller.is_forfeit_handled() or _opponent_left_lobby:
			if is_instance_valid(overlay): overlay.queue_free()
			print("[Lobby][%s] Opponent left during countdown, aborting" % role)
			return
			
		label.text = str(i)
		print("[Lobby][%s] Countdown: %d" % [role, i])
		# Use smaller intervals to detect opponent leaving faster
		for j in range(4):  # Check 4 times per second
			await get_tree().create_timer(0.25).timeout
			if matchmaking_controller.is_forfeit_handled() or _opponent_left_lobby:
				if is_instance_valid(overlay): overlay.queue_free()
				print("[Lobby][%s] Opponent left during countdown (sub-check)" % role)
				return
	
	if not is_instance_valid(label):
		print("[Lobby][%s] Label invalid before GO" % role)
		return
	if matchmaking_controller.is_forfeit_handled() or _opponent_left_lobby:
		if is_instance_valid(overlay): overlay.queue_free()
		print("[Lobby][%s] Opponent left before GO" % role)
		return
	
	label.text = "GO!"
	print("[Lobby][%s] GO! Transitioning to game scene..." % role)

	if is_inside_tree() and not matchmaking_controller.is_forfeit_handled() and not _opponent_left_lobby:
		print("[Lobby][%s] Changing to game scene" % role)
		TransitionManager.to_game("res://scenes/game/game.tscn")
	else:
		print("[Lobby][%s] Cannot change scene - not in tree or opponent left" % role)

## Show popup when opponent leaves the lobby, wait 3s, then return to menu without penalty
func _show_opponent_left_popup() -> void:
	if matchmaking_controller.is_forfeit_handled(): return
	matchmaking_controller.mark_forfeit_handled()
	var role = "HOST" if GameManager.is_host else "GUEST"
	print("[Lobby][%s] Opponent left the lobby" % role)
	
	# Stop polling and heartbeat
	poll_timer = 999999.0
	_heartbeat_timer = 999999.0
	
	# Create overlay
	var overlay = Panel.new()
	overlay.set_anchors_preset(Control.PRESET_CENTER)
	overlay.custom_minimum_size = Vector2(400, 200)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 24
	vbox.offset_top = 24
	vbox.offset_right = -24
	vbox.offset_bottom = -24
	vbox.add_theme_constant_override("separation", 16)
	overlay.add_child(vbox)
	
	var title = Label.new()
	title.text = "Opponent Left"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", Color.ORANGE)
	vbox.add_child(title)
	
	var msg = Label.new()
	msg.text = "Your opponent has left the lobby.\nReturning to main menu..."
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(msg)
	
	var countdown_label = Label.new()
	countdown_label.text = "3"
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.add_theme_font_override("font", PIXEL_FONT)
	countdown_label.add_theme_font_size_override("font_size", 48)
	countdown_label.add_theme_color_override("font_color", Color.WHITE)
	vbox.add_child(countdown_label)
	
	# Leave the room (no penalty for us)
	if GameManager.is_host:
		_delete_room()
	else:
		_leave_room()
	GameManager.current_room = ""
	
	# Enable auto-requeue since we're the innocent party
	GameManager.auto_queue_matchmaking = true
	GameManager.is_matchmaking = false
	
	# 3-second countdown
	for i in range(3, 0, -1):
		if not is_instance_valid(countdown_label): return
		countdown_label.text = str(i)
		await get_tree().create_timer(1.0).timeout
	
	# Return to main menu
	if is_inside_tree():
		get_tree().change_scene_to_file("res://scenes/ui/menus/main_menu.tscn")
