extends Node2D

var sentences = []
var target_sentence = ""
var current_index = 0
var typed_statuses = []
var current_round = 0

var sentence_start_time = 0.0
var is_typing = false
var typos_count = 0
var total_keystrokes = 0

enum GameState { SKILL_SELECT, TYPING, RESOLVING }
var current_state = GameState.SKILL_SELECT

# Skill phase
var skill_timer: float = 10.0
var chosen_skill_index: int = -1
var chosen_skill_id: String = ""

# Typing / round timers
var round_timer: float = 60.0       # 60 s main countdown
var snap_active: bool = false        # snap-to-10s mode active?
var snap_timer: float = 10.0        # countdown after first player finishes
var i_finished: bool = false         # this client finished the sentence
var enemy_finished: bool = false     # enemy finished (detected via poll)

var enemy_typing_progress: float = 0.0
var typos_in_current_word: int = 0

var p1
var p2

# Character name → SpriteFrames resource path
const CHARACTER_SPRITES = {
	"Riven": "res://assets/spriteframes/riven.tres",
	"Zephon": "res://assets/spriteframes/zephone.tres",
	"Liora": "res://assets/spriteframes/leora.tres",
}

# Character name → idle animation name
const CHARACTER_IDLE_ANIM = {
	"Riven": "idle",
	"Zephon": "zephon-idle",
	"Liora": "idle",
}

@onready var typing_label = $HUD/TypingText
@onready var skill_select = $HUD/SkillSelect
@onready var countdown_label = $HUD/CountdownText
@onready var stats_label = $HUD/TypingStats
@onready var accuracy_warning = $HUD/AccuracyWarning
@onready var own_progress_bar  = $HUD/OwnProgress
@onready var enemy_progress_bar = $HUD/EnemyProgress

@onready var hp_bar_own = $HUD/Stats/OwnHp
@onready var hp_bar_opp = $HUD/Stats/EnemyHp
@onready var mana_bar_own = $HUD/Stats/OwnMana
@onready var mana_bar_opp = $HUD/Stats/EnemyMana

var SERVER: String:
	get: return GameManager.SERVER_URL
var last_progress_sync: float = 0.0
var last_poll_time: float     = 0.0
var sync_interval: float = 0.3
var poll_interval: float = 0.5

var _last_mutation_index: int = 0
var _queued_mutations: Array = []
var _perfect_words_streak: int = 0

var _server_phase: String = ""
var _server_phase_started_at_ms: float = 0.0
var _server_typing_started_at_ms: float = 0.0
var _server_first_finish_at_ms: float = 0.0
var _server_first_finish_by: String = ""
var _local_first_finish_at_ms: float = 0.0
var _local_first_finish_by: String = ""
var _server_round_id: int = 0
var _server_time_offset_ms: float = 0.0
var _best_time_sync_rtt_ms: float = INF
var _predicted_typing_started_at_ms: float = 0.0
var _last_snap_fallback_log_ms: int = 0
var _last_resolved_round_id: int = 0
var _snap_trace_active: bool = false
var _snap_trace_last_s: int = -1
var _snap_trace_line: String = ""
var _snap_trace_start_s: int = 0
var _last_room_seq: int = -1

var _host_skill_phase_requested: bool = false
var _host_typing_phase_requested: bool = false

# Debug overlay (non-pausing; safe for online)
var _debug_panel: Panel = null
var _debug_visible: bool = false

func _ready():
	_setup_debug_overlay()
	HPManager.init_game()
	SkillsManager.reset_match()
	if not GameManager.is_solo and GameManager.current_room != "":
		seed(GameManager.current_room.hash())
	else:
		randomize()
		
	_spawn_players()
	
	skill_select.hide()
	countdown_label.hide()
	typing_label.show()
	if accuracy_warning:
		accuracy_warning.hide()
		
	if has_node("HUD/SkillSelect/HBoxContainer/Skill1"):
		$HUD/SkillSelect/HBoxContainer/Skill1.pressed.connect(_on_skill_pressed.bind(1))
	if has_node("HUD/SkillSelect/HBoxContainer/Skill2"):
		$HUD/SkillSelect/HBoxContainer/Skill2.pressed.connect(_on_skill_pressed.bind(2))
		
	HPManager.entity_died.connect(_on_entity_died)
		
	load_sentences()
	start_skill_phase()

func _role_tag() -> String:
	if GameManager.is_solo:
		return "SOLO"
	return "HOST" if GameManager.is_host else "GUEST"

func _log(msg: String) -> void:
	# Prefix logs so multi-client testing is readable.
	var sid = GameManager.session_id
	print("[%s][%s] %s" % [sid, _role_tag(), msg])

func _setup_debug_overlay() -> void:
	_debug_panel = Panel.new()
	_debug_panel.set_anchors_preset(Control.PRESET_CENTER)
	_debug_panel.custom_minimum_size = Vector2(420, 340)
	_debug_panel.visible = false
	_debug_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	$HUD.add_child(_debug_panel)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 16
	vbox.offset_top = 16
	vbox.offset_right = -16
	vbox.offset_bottom = -16
	_debug_panel.add_child(vbox)

	var title = Label.new()
	title.text = "DEBUG (F1)"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var btn_finish = Button.new()
	btn_finish.text = "Skip / Auto Finish Sentence"
	btn_finish.pressed.connect(func():
		if current_state == GameState.TYPING:
			# Make skip-testing produce sane WPM/damage (otherwise elapsed≈0 -> absurd WPM).
			sentence_start_time = Time.get_ticks_msec() - 12000
			current_index = target_sentence.length()
			typos_in_current_word = 0
			_on_i_finished()
	)
	vbox.add_child(btn_finish)

	var inject_title = Label.new()
	inject_title.text = "Inject Passive"
	vbox.add_child(inject_title)

	for p_data in GameManager.PASSIVES:
		var p_id = p_data["id"]
		var btn = Button.new()
		btn.text = p_data.get("name", p_id)
		btn.pressed.connect(func():
			SkillsManager.selected_passive = p_id
			_log("[Debug] Passive injected: %s" % p_id)
		)
		vbox.add_child(btn)

	var btn_close = Button.new()
	btn_close.text = "Close"
	btn_close.pressed.connect(_toggle_debug_overlay)
	vbox.add_child(btn_close)

func _toggle_debug_overlay() -> void:
	_debug_visible = !_debug_visible
	if is_instance_valid(_debug_panel):
		_debug_panel.visible = _debug_visible

func _on_entity_died(entity: String):
	# Only trigger game over if we are not already resolving/ended
	if current_state == GameState.RESOLVING:
		# Let the current resolution finish naturally,
		# but kill the awaited timer and force end immediately
		pass
	if current_state == GameState.TYPING or current_state == GameState.SKILL_SELECT or current_state == GameState.RESOLVING:
		current_state = GameState.RESOLVING  # block further input
		
		var victory_scene = load("res://scenes/ui/victory_screen.tscn").instantiate()
		$HUD.add_child(victory_scene)
		
		var won = (entity == "opponent")
		_save_match_history(won)
		victory_scene.set_result(won)

func start_skill_phase(announce_phase: bool = false):
	current_state = GameState.SKILL_SELECT
	_host_skill_phase_requested = false
	_host_typing_phase_requested = false
	_predicted_typing_started_at_ms = 0.0
	_server_typing_started_at_ms = 0.0
	_server_first_finish_at_ms = 0.0
	_server_first_finish_by = ""
	
	# Default timer; online play uses server phase_started_at for sync.
	skill_timer = 10.0
	
	chosen_skill_index = -1
	chosen_skill_id    = ""  # No skill chosen yet
	i_finished    = false
	enemy_finished = false
	snap_active   = false
	snap_timer    = 10.0
	_last_snap_fallback_log_ms = 0
	_snap_trace_active = false
	_snap_trace_last_s = -1
	_snap_trace_line = ""
	round_timer   = 60.0
	
	current_index = 0
	target_sentence = ""
	enemy_typing_progress = 0.0 # <--- Ensure we reset local knowledge
	
	# Update skill button labels + disable if not enough mana
	if SkillsManager.selected_skills.size() > 0:
		var s1 = SkillsManager.selected_skills[0]
		if has_node("HUD/SkillSelect/HBoxContainer/Skill1"):
			var btn1 = $HUD/SkillSelect/HBoxContainer/Skill1
			btn1.text = "%s (%dM)" % [s1.capitalize(), SkillsManager.SKILL_COSTS.get(s1, 0)]
			btn1.disabled = not SkillsManager.can_pick_skill(s1)
	if SkillsManager.selected_skills.size() > 1:
		var s2 = SkillsManager.selected_skills[1]
		if has_node("HUD/SkillSelect/HBoxContainer/Skill2"):
			var btn2 = $HUD/SkillSelect/HBoxContainer/Skill2
			btn2.text = "%s (%dM)" % [s2.capitalize(), SkillsManager.SKILL_COSTS.get(s2, 0)]
			btn2.disabled = not SkillsManager.can_pick_skill(s2)
			
	_log("[Phase] SKILL SELECT | mana=%d | skills=%s" % [SkillsManager.player_mana, str(SkillsManager.selected_skills)])
	skill_select.show()
	countdown_label.show()
	typing_label.hide()

	# Online: host declares the new skill-select phase (authoritative timers + round id)
	if announce_phase and not GameManager.is_solo and GameManager.current_room != "" and GameManager.is_host:
		_host_skill_phase_requested = true
		var next_round = max(1, _server_round_id) + 1 if _server_round_id > 0 else 2
		_server_round_id = next_round
		_host_set_phase("skill_select", next_round)

func start_typing_phase(announce_phase: bool = false):
	current_state = GameState.TYPING
	skill_select.hide()
	_host_typing_phase_requested = announce_phase and GameManager.is_host
	_local_first_finish_at_ms = 0.0
	_local_first_finish_by = ""
	
	skill_timer = 0.0
	is_typing = false
	current_index = 0
	total_keystrokes = 0
	typos_count = 0
	typos_in_current_word = 0
	typed_statuses.clear()
	_last_mutation_index = 0

	if GameManager.is_solo or GameManager.current_room == "":
		current_round += 1
	else:
		current_round = _server_round_id if _server_round_id > 0 else max(1, current_round)
	pick_random_sentence()
	
	typing_label.show()
	countdown_label.show()
	countdown_label.text = "60"
	update_typing_ui()
	
	set_meta("jumble_triggered_this_round", false)
	
	if SkillsManager.selected_passive == "stutter" and SkillsManager.opponent_win_streak > 0:
		_queued_mutations.append({ "type": "stutter" })
		
	if SkillsManager.selected_passive == "phantom" and SkillsManager.phantom_stack > 0:
		for i in range(SkillsManager.phantom_stack):
			_queued_mutations.append({ "type": "phantom" })
			
	_log("[Round] Starting TYPING Phase | target_len=%d | round_id=%d" % [target_sentence.length(), _server_round_id])
	sentence_start_time = Time.get_ticks_msec()
	is_typing = true
	
	if announce_phase and not GameManager.is_solo and GameManager.current_room != "" and GameManager.is_host:
		_host_typing_phase_requested = true
		_host_set_phase("typing", max(1, _server_round_id))

func _spawn_players():

	# Hide the pre-placed Player nodes (they're static placeholders in the .tscn)
	if has_node("Player"):
		$Player.hide()
	if has_node("Player2"):
		$Player2.hide()

	# Determine side based on a synced random value
	var host_is_left = (randi() % 2 == 0)
	var am_i_left = true
	if not GameManager.is_solo:
		am_i_left = (GameManager.is_host == host_is_left)
		
	var my_side_node = "TileMap/P1" if am_i_left else "TileMap/P2"
	var enemy_side_node = "TileMap/P2" if am_i_left else "TileMap/P1"
	
	var own_char = GameManager.selected_character
	var opp_char = GameManager.opponent_character
	
	# Spawn own player (p1)
	p1 = _create_character_sprite(own_char, not am_i_left) # Flip if on right
	if has_node(my_side_node):
		get_node(my_side_node).add_child(p1)
		p1.position = Vector2.ZERO
	else:
		p1.position = Vector2(300, 300) if am_i_left else Vector2(850, 300)
		add_child(p1)
	
	# Spawn opponent (p2)
	p2 = _create_character_sprite(opp_char, am_i_left) # Flip if on right (which is am_i_left false)
	if has_node(enemy_side_node):
		get_node(enemy_side_node).add_child(p2)
		p2.position = Vector2.ZERO
	else:
		p2.position = Vector2(850, 300) if am_i_left else Vector2(300, 300)
		add_child(p2)
			
	# If we are on the right side, swap the UI progress bars
	if not am_i_left and own_progress_bar and enemy_progress_bar:
		var own_prog = own_progress_bar
		var enemy_prog = enemy_progress_bar
		
		var own_anchors = [own_prog.anchor_left, own_prog.anchor_right]
		var own_offsets = [own_prog.offset_left, own_prog.offset_right]
		var enemy_anchors = [enemy_prog.anchor_left, enemy_prog.anchor_right]
		var enemy_offsets = [enemy_prog.offset_left, enemy_prog.offset_right]
		
		own_prog.anchor_left = enemy_anchors[0]
		own_prog.anchor_right = enemy_anchors[1]
		own_prog.offset_left = enemy_offsets[0]
		own_prog.offset_right = enemy_offsets[1]
		
		enemy_prog.anchor_left = own_anchors[0]
		enemy_prog.anchor_right = own_anchors[1]
		enemy_prog.offset_left = own_offsets[0]
		enemy_prog.offset_right = own_offsets[1]

func _create_character_sprite(char_name: String, flip: bool) -> Node2D:
	var player_scene = load("res://scenes/entities/player.tscn")
	var node = player_scene.instantiate()
	var sprite = node.get_node("AnimatedSprite2D")
	
	var sf_path = CHARACTER_SPRITES.get(char_name, "res://assets/spriteframes/riven.tres")
	sprite.sprite_frames = load(sf_path)
	sprite.flip_h = flip
	
	var idle_anim = CHARACTER_IDLE_ANIM.get(char_name, "idle")
	sprite.animation = idle_anim
	sprite.play(idle_anim)
	
	return node


func load_sentences():
	var path = "c:/Users/LENOVO/Documents/type-duel/server/data/sentences.json"
	var file = FileAccess.open(path, FileAccess.READ)
	if file:
		var text = file.get_as_text()
		var json = JSON.parse_string(text)
		if json is Array:
			for item in json:
				if item.has("text"):
					sentences.append(item["text"])
		file.close()
	
	if sentences.is_empty():
		sentences.append("The quick brown fox jumps over the lazy dog.")
		sentences.append("Type this sentence to practice your skills.")

func pick_random_sentence():
	# Re-seed every round using the room hash and round number.
	# This prevents RNG drift if one player triggers a mutation and the other doesn't.
	if not GameManager.is_solo and GameManager.current_room != "":
		seed(GameManager.current_room.hash() + int(current_round))
	
	if sentences.size() > 0:
		target_sentence = sentences[randi() % sentences.size()]
	current_index = 0
	typed_statuses.clear()
	is_typing = false
	typos_count = 0
	typos_in_current_word = 0
	total_keystrokes = 0
	if stats_label:
		stats_label.text = "WPM: 0 | Typos: 0 | Accuracy: 100% | Mana: " + str(SkillsManager.player_mana)
	update_typing_ui()

func _get_synced_server_time_ms() -> float:
	return Time.get_unix_time_from_system() * 1000.0 + _server_time_offset_ms

func _process(delta):
	# Always poll room state online so phase/timer transitions stay synced.
	var now = Time.get_ticks_msec() / 1000.0
	if not GameManager.is_solo and GameManager.current_room != "":
		var effective_poll_interval = 0.15 if current_state == GameState.SKILL_SELECT else poll_interval
		if now - last_poll_time > effective_poll_interval:
			last_poll_time = now
			_poll_opponent_progress()
	
	if current_state == GameState.SKILL_SELECT:
		# Online: guests should never locally advance to typing; host only advances when server says it's typing.
		# This prevents phase flip-flopping when network/polling delays occur (especially during fast debug skips).
		# Server-authoritative skill timer when online.
		if not GameManager.is_solo and GameManager.current_room != "" and _server_phase == "skill_select" and _server_phase_started_at_ms > 0.0:
			var now_ms = _get_synced_server_time_ms()
			var elapsed = (now_ms - _server_phase_started_at_ms) / 1000.0
			skill_timer = max(0.0, 10.0 - elapsed)
		else:
			skill_timer -= delta
		if countdown_label:
			countdown_label.text = "Choose Skill: %d" % max(0, int(ceil(skill_timer)))
		if skill_timer <= 0:
			if not GameManager.is_solo and GameManager.current_room != "":
				# Host triggers the server phase change; both clients wait for server phase=typing before starting locally.
				if GameManager.is_host and _server_phase == "skill_select" and not _host_typing_phase_requested:
					_host_typing_phase_requested = true
					_host_set_phase("typing", max(1, _server_round_id))
			else:
				start_typing_phase()
			
	elif current_state == GameState.TYPING:
		# ── Main 60s round timer ──────────────────────
		# Server-authoritative timing when online.
		# NOTE: If we locally enter snap mode but the server hasn't yet recorded `first_finish_at`
		# (e.g. transient /progress request failures), keep ticking the local snap timer so the UI
		# doesn't freeze at 10s. Once the server reports `first_finish_at`, snap_timer becomes
		# authoritative again.
		if not GameManager.is_solo and GameManager.current_room != "" and _server_phase == "typing" and _server_typing_started_at_ms > 0.0:
			var now_ms = _get_synced_server_time_ms()
			var round_deadline = _server_typing_started_at_ms + 60000.0
			round_timer = max(0.0, (round_deadline - now_ms) / 1000.0)

			# Server-authoritative snap window once someone finishes.
			# Keep updating snap_timer for BOTH players (including the one who finished first),
			# otherwise the countdown freezes at 10.0 when i_finished == true.
			var effective_first_finish_at_ms: float = _server_first_finish_at_ms
			if effective_first_finish_at_ms <= 0.0 and _local_first_finish_at_ms > 0.0:
				effective_first_finish_at_ms = _local_first_finish_at_ms

			if effective_first_finish_at_ms > 0.0:
				var snap_deadline = min(round_deadline, effective_first_finish_at_ms + 10000.0)
				snap_timer = max(0.0, (snap_deadline - now_ms) / 1000.0)
				snap_active = true

				var finish_by: String = _server_first_finish_by
				if finish_by == "" and _local_first_finish_by != "":
					finish_by = _local_first_finish_by
				var am_first = (finish_by == "host" and GameManager.is_host) or (finish_by == "guest" and not GameManager.is_host)
				if not am_first:
					enemy_finished = true
			elif snap_active:
				# Fallback: tick local snap timer until server confirms first_finish_at.
				# Clamp to remaining round time so it can't extend beyond 60s.
				snap_timer = min(snap_timer, round_timer)
				snap_timer = max(0.0, snap_timer - delta)
				var now_ticks: int = int(Time.get_ticks_msec())
				if now_ticks - _last_snap_fallback_log_ms > 2000:
					_last_snap_fallback_log_ms = now_ticks
					_log("[Snap] Fallback ticking (awaiting first_finish_at)")
		else:
			if snap_active:
				snap_timer -= delta
			else:
				round_timer -= delta

		if snap_active:
			# Per-client snap trace for debugging: prints "10..9..8.."
			var s_left: int = int(ceil(snap_timer))
			if not _snap_trace_active:
				_snap_trace_active = true
				_snap_trace_last_s = s_left
				_snap_trace_line = ""
				_snap_trace_start_s = s_left
			if s_left != _snap_trace_last_s:
				_snap_trace_last_s = s_left
				var elapsed_s: int = max(0, _snap_trace_start_s - s_left)
				_snap_trace_line += ("%d.." % elapsed_s)
				_log("[SnapTrace] " + _snap_trace_line)
			if countdown_label:
				# Always show a label (user requested) rather than a bare number.
				if enemy_finished and not i_finished:
					countdown_label.text = "⏱ You: %d" % max(0, int(ceil(snap_timer)))
				else:
					countdown_label.text = "⏱ Opp: %d" % max(0, int(ceil(snap_timer)))
			# If both players are finished, resolve immediately (don’t wait for snap to expire).
			if i_finished and enemy_finished:
				_resolve_and_advance("buff")
				return
			if snap_timer <= 0.0:
				# If opponent finished first and we ran out of time, we DNF.
				if enemy_finished and not i_finished:
					print("[Round] Snap timer expired — DNF (you didn't finish)")
					_resolve_and_advance("dnf")
				else:
					print("[Round] Snap timer expired — FULL POWER resolution")
					_resolve_and_advance("full_power")
				return
		else:
			_snap_trace_active = false
			_snap_trace_last_s = -1
			_snap_trace_line = ""
			_snap_trace_start_s = 0
			if countdown_label:
				countdown_label.text = "%d" % max(0, int(ceil(round_timer)))
			if round_timer <= 0.0:
				print("[Round] 60s expired — NO ATTACK resolution")
				_resolve_and_advance("no_attack")
				return
		
		# ── Stats HUD ─────────────────────────────────
		var time_elapsed_min = 0.0
		if is_typing and sentence_start_time > 0:
			time_elapsed_min = (Time.get_ticks_msec() - sentence_start_time) / 60000.0
		var words = current_index / 5.0
		var wpm = int(words / time_elapsed_min) if time_elapsed_min > 0 else 0
		
		var accuracy = 100.0
		if total_keystrokes > 0:
			accuracy = (float(total_keystrokes - typos_count) / float(total_keystrokes)) * 100.0
			
		if stats_label:
			stats_label.text = "WPM: %d | Typos: %d | Accuracy: %.1f%% | Mana: %d" % [wpm, typos_count, accuracy, SkillsManager.player_mana]
	
	# ── Progress bars (HP display) ─────────────────
	own_progress_bar.max_value  = HPManager.player_max_hp
	own_progress_bar.value      = HPManager.player_hp
	enemy_progress_bar.max_value = HPManager.opponent_max_hp
	enemy_progress_bar.value    = HPManager.opponent_hp
	
	if hp_bar_own:
		hp_bar_own.max_value = HPManager.player_max_hp
		hp_bar_own.value = HPManager.player_hp
	if hp_bar_opp:
		hp_bar_opp.max_value = HPManager.opponent_max_hp
		hp_bar_opp.value = HPManager.opponent_hp
	if mana_bar_own:
		mana_bar_own.max_value = 10
		mana_bar_own.value = SkillsManager.player_mana
	if mana_bar_opp:
		mana_bar_opp.max_value = 10
		mana_bar_opp.value = SkillsManager.opponent_mana
	
	# ── Networking sync ────────────────────────────
	now = Time.get_ticks_msec() / 1000.0
	if current_state == GameState.TYPING:
		if now - last_progress_sync > sync_interval:
			last_progress_sync = now
			_sync_progress_to_server()

func _sync_progress_to_server():
	if GameManager.current_room == "" or GameManager.user_data.id == 0: return
	var prog = 0.0
	if target_sentence.length() > 0:
		prog = float(current_index) / float(target_sentence.length())
	
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r,_c,_h,_b): http.queue_free())
	var payload = {
		"user_id": GameManager.user_data.id,
		"progress": prog,
		"typos": typos_count
	}
	if _queued_mutations.size() > 0:
		payload["send_mutation"] = _queued_mutations.pop_front()
	
	var body = JSON.stringify(payload)
	http.request(SERVER + "/api/rooms/" + GameManager.current_room + "/progress", GameManager.get_auth_headers(), HTTPClient.METHOD_PATCH, body)

func _poll_opponent_progress():
	if GameManager.current_room == "": return
	var http = HTTPRequest.new()
	add_child(http)
	var sent_local_ms: float = Time.get_unix_time_from_system() * 1000.0
	http.request_completed.connect(_on_poll_progress_done.bind(http, sent_local_ms))
	http.request(SERVER + "/api/rooms/" + GameManager.current_room, GameManager.get_auth_headers())

func _on_poll_progress_done(_result, _code, _headers, body, http, sent_local_ms: float):
	http.queue_free()
	var recv_local_ms: float = Time.get_unix_time_from_system() * 1000.0
	var json = JSON.parse_string(body.get_string_from_utf8())
	if json:
		var seq = int(json.get("seq", -1))
		if seq >= 0 and _last_room_seq >= 0 and seq < _last_room_seq:
			return # ignore stale/out-of-order poll responses
		if seq >= 0:
			_last_room_seq = seq
		_apply_room_phase(json, sent_local_ms, recv_local_ms)
		if current_state != GameState.TYPING:
			return

		var opp_prog = 0.0
		var opp_typos = 0
		var my_muts = []
		if GameManager.is_host:
			opp_prog  = json.get("guest_progress", 0.0)
			opp_typos = json.get("guest_typos", 0)
			my_muts   = json.get("host_mutations", [])
		else:
			opp_prog  = json.get("host_progress", 0.0)
			opp_typos = json.get("host_typos", 0)
			my_muts   = json.get("guest_mutations", [])
			
		while _last_mutation_index < my_muts.size():
			_apply_mutation(my_muts[_last_mutation_index])
			_last_mutation_index += 1
		
		set_meta("opp_typos", opp_typos)
		enemy_typing_progress = opp_prog * 100.0
		
		# Online: enemy finished (check >= 0.99 to be safe with floats)
		if not GameManager.is_solo and opp_prog >= 0.99 and not enemy_finished:
			enemy_finished = true
			if i_finished:
				_log("[Round] Enemy finished (progress>=0.99) AFTER we finished")
				# Both finished
			else:
				# Enemy finished before us — start snap for us
				_log("[Round] Enemy finished first — snap timer started for us")
				snap_active = true

func _apply_room_phase(room: Dictionary, sent_local_ms: float = -1.0, recv_local_ms: float = -1.0) -> void:
	if room.has("server_now"):
		var server_now_ms: float = float(room.get("server_now"))
		var local_now_ms: float = Time.get_unix_time_from_system() * 1000.0
		var new_offset_ms: float = server_now_ms - local_now_ms
		if sent_local_ms >= 0.0 and recv_local_ms >= sent_local_ms:
			var rtt_ms: float = recv_local_ms - sent_local_ms
			# NTP-style estimate: assume symmetric delay, server_now captured near response send time.
			new_offset_ms = (server_now_ms + (rtt_ms * 0.5)) - recv_local_ms
			# Prefer the best (lowest RTT) samples to reduce jitter.
			if rtt_ms < _best_time_sync_rtt_ms:
				_best_time_sync_rtt_ms = rtt_ms
		# Smooth offset updates to avoid timer jumps.
		if _server_time_offset_ms == 0.0:
			_server_time_offset_ms = new_offset_ms
		else:
			_server_time_offset_ms = lerp(_server_time_offset_ms, new_offset_ms, 0.25)
		# Lightweight sync visibility for debugging multi-client timer drift.
		if sent_local_ms >= 0.0 and recv_local_ms >= sent_local_ms and int(Time.get_ticks_msec()) % 3000 < 30:
			var rtt_ms_dbg: float = recv_local_ms - sent_local_ms
			_log("[TimeSync] rtt_ms=%.0f best_rtt_ms=%.0f offset_ms=%.0f" % [rtt_ms_dbg, _best_time_sync_rtt_ms, _server_time_offset_ms])

	_server_phase = str(room.get("phase", _server_phase))
	_server_phase_started_at_ms = float(room.get("phase_started_at", _server_phase_started_at_ms))
	_server_typing_started_at_ms = float(room.get("typing_started_at", _server_typing_started_at_ms))
	_server_first_finish_at_ms = float(room.get("first_finish_at", _server_first_finish_at_ms))
	_server_first_finish_by = "" if room.get("first_finish_by", null) == null else str(room.get("first_finish_by"))
	_server_round_id = int(room.get("round_id", _server_round_id))
	if _server_phase == "skill_select" and _server_phase_started_at_ms > 0.0:
		_predicted_typing_started_at_ms = _server_phase_started_at_ms + 10000.0

	# Follow host phase changes.
	# Guard: ignore stale "typing" phase for a round we've already resolved locally.
	# This can happen if the host phase PATCH fails during rapid debug skipping.
	if _server_phase == "typing" and current_state == GameState.SKILL_SELECT and _server_round_id <= _last_resolved_round_id:
		return
	if _server_phase == "typing" and current_state == GameState.SKILL_SELECT:
		_log("[Net] Phase->typing (server) | round_id=%d" % _server_round_id)
		start_typing_phase(false)
	elif _server_phase == "skill_select" and current_state != GameState.SKILL_SELECT:
		_log("[Net] Phase->skill_select (server) | round_id=%d" % _server_round_id)
		start_skill_phase(false)

func _host_set_phase(phase: String, round_id: int) -> void:
	if GameManager.current_room == "" or GameManager.user_data.id == 0:
		return

	var http = HTTPRequest.new()
	add_child(http)
	var payload: Dictionary = {
		"user_id": GameManager.user_data.id,
		"phase": phase
	}
	if round_id > 0:
		payload["round_id"] = round_id
	var body = JSON.stringify(payload)
	http.request_completed.connect(func(_r, _c, _h, _b):
		if is_instance_valid(http):
			http.queue_free()
	)
	http.request(SERVER + "/api/rooms/" + GameManager.current_room + "/phase", GameManager.get_auth_headers(), HTTPClient.METHOD_PATCH, body)

@export var correct_color: Color = Color.GREEN
@export var wrong_color: Color = Color.RED
@export var current_char_color: Color = Color.YELLOW
@export var upcoming_color: Color = Color.WHITE

func _apply_mutation(mut: Dictionary):
	var type = mut.get("type", "")
	print("[Mutation] Receiving mutation: ", type)
	
	if type == "stutter_effect2":
		var prev_space = target_sentence.rfind(" ", current_index - 2)
		var start = prev_space + 1 if prev_space != -1 else 0
		var word_just_typed = target_sentence.substr(start, current_index - 1 - start)
		target_sentence = target_sentence.substr(0, current_index) + word_just_typed + " " + target_sentence.substr(current_index)
		update_typing_ui()
		return
		
	var remaining_text = target_sentence.substr(current_index)
	var first_space = remaining_text.find(" ")
	if first_space == -1: return # No unstarted words left
	
	var unstarted_part = remaining_text.substr(first_space + 1)
	var words = unstarted_part.split(" ")
	if words.size() == 0: return
	
	if type == "reversal":
		var w_idx = randi() % words.size()
		var w = words[w_idx]
		var rw = ""
		for i in range(w.length() - 1, -1, -1): rw += w[i]
		words[w_idx] = rw
	elif type == "jumble":
		var max_len = 0
		for w in words:
			if w.length() > max_len: max_len = w.length()
		var cands = []
		for i in range(words.size()):
			if words[i].length() == max_len: cands.append(i)
		var w_idx = cands[randi() % cands.size()]
		var chars = []
		for c in words[w_idx]: chars.append(c)
		chars.shuffle()
		var nw = ""
		for c in chars: nw += c
		words[w_idx] = nw
	elif type == "erosion":
		if words[0].length() > 0:
			var w = words[0]
			words[0] = w + w[w.length()-1]
	elif type == "phantom":
		var w_idx = randi() % words.size()
		var w = words[w_idx]
		if w.length() > 0:
			var c_idx = randi() % w.length()
			words[w_idx] = w.substr(0, c_idx) + "_" + w.substr(c_idx + 1)
	elif type == "stutter":
		var w_idx = randi() % words.size()
		words[w_idx] = words[w_idx] + " " + words[w_idx]
		set_meta("stutter_effect2_pending", true)

	target_sentence = target_sentence.substr(0, current_index + first_space + 1) + " ".join(words)
	update_typing_ui()

func update_typing_ui():
	if accuracy_warning:
		accuracy_warning.hide()
		
	var c_hex = "#" + correct_color.to_html(false)
	var w_hex = "#" + wrong_color.to_html(false)
	var cur_hex = "#" + current_char_color.to_html(false)
	var up_hex = "#" + upcoming_color.to_html(false)
		
	var bbcode = "[center]"
	for i in range(current_index):
		var color = c_hex if typed_statuses[i] else w_hex
		bbcode += "[color=" + color + "]" + target_sentence[i] + "[/color]"
		
	if current_index < target_sentence.length():
		bbcode += "[color=" + cur_hex + "][u]" + target_sentence[current_index] + "[/u][/color]"
		if current_index + 1 < target_sentence.length():
			bbcode += "[color=" + up_hex + "]" + target_sentence.substr(current_index + 1) + "[/color]"
			
	bbcode += "[/center]"
	typing_label.text = bbcode

func _unhandled_input(event):
	# Debug overlay toggle: F1 always; ESC only in solo (avoid online desync expectations)
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			_toggle_debug_overlay()
			return
		if GameManager.is_solo and event.keycode == KEY_ESCAPE:
			_toggle_debug_overlay()
			return

	if current_state != GameState.TYPING: return
	
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_BACKSPACE:
			if current_index > 0:
				current_index -= 1
				typed_statuses.pop_back()
				update_typing_ui()
			return
			
		if not event.echo and event.unicode != 0:
			if not is_typing:
				is_typing = true
				sentence_start_time = Time.get_ticks_msec()
				
			var char_typed = char(event.unicode)
			if char_typed.length() > 0 and current_index < target_sentence.length():
				var expected_char = target_sentence[current_index]
				var is_correct = (char_typed == expected_char)
				
				total_keystrokes += 1
				if not is_correct:
					typos_count += 1
					typos_in_current_word += 1
					
				if expected_char == " ":
					# Word completed
					if typos_in_current_word == 0:
						# Accurate word: trigger mana + passive
						var cur_wpm = 0.0
						var elapsed_min = (Time.get_ticks_msec() - sentence_start_time) / 60000.0
						if elapsed_min > 0:
							cur_wpm = (float(current_index) / 5.0) / elapsed_min
						SkillsManager.on_accurate_word(cur_wpm)
						
						_perfect_words_streak += 1
						if SkillsManager.selected_passive == "erosion" and _perfect_words_streak % 3 == 0:
							_queued_mutations.append({ "type": "erosion" })
					typos_in_current_word = 0
					
					# Handle stutter effect 2
					if get_meta("stutter_effect2_pending", false):
						set_meta("stutter_effect2_pending", false)
						_apply_mutation({ "type": "stutter_effect2" })
						
					# Jumble check
					if SkillsManager.selected_passive == "jumble" and SkillsManager.player_mana >= 7 and not get_meta("jumble_triggered_this_round", false):
						set_meta("jumble_triggered_this_round", true)
						_queued_mutations.append({ "type": "jumble" })
				
				typed_statuses.append(is_correct)
				current_index += 1
				update_typing_ui()
				
				if current_index >= target_sentence.length():
					# Last word accurate?
					if typos_in_current_word == 0:
						var elapsed_min = (Time.get_ticks_msec() - sentence_start_time) / 60000.0
						var cur_wpm = (float(current_index) / 5.0) / elapsed_min if elapsed_min > 0 else 0.0
						SkillsManager.on_accurate_word(cur_wpm)
					
					var accuracy = 100.0
					if total_keystrokes > 0:
						accuracy = (float(total_keystrokes - typos_count) / float(total_keystrokes)) * 100.0
					
					if accuracy < 60.0:
						if accuracy_warning:
							accuracy_warning.show()
					else:
						_on_i_finished()

## Called when THIS player finishes typing.
func _on_i_finished():
	if i_finished: return  # guard against double-trigger
	i_finished = true
	typing_label.hide()
	
	if enemy_finished:
		# Enemy already finished before us — we're the loser
		snap_active = false
		_log("[Round] We finished SECOND (enemy faster) — DEBUFF resolution")
		_resolve_and_advance("debuff")
	else:
		# We finished first!
		SkillsManager.on_finish_first()
		if SkillsManager.selected_passive == "reversal":
			_queued_mutations.append({ "type": "reversal" })
		if GameManager.is_solo:
			# Solo: auto-resolve as buff (no real opponent)
			print("[Round] Solo mode — BUFF resolution")
			_resolve_and_advance("buff")
		else:
			# Start snap timer
			if round_timer > 10.0:
				snap_timer = 10.0
			else:
				snap_timer = round_timer
			snap_active = true
			if _local_first_finish_at_ms <= 0.0:
				_local_first_finish_at_ms = _get_synced_server_time_ms()
				_local_first_finish_by = "host" if GameManager.is_host else "guest"
			# Immediately publish a "finished" update so the server can set first_finish_at even if
			# the periodic sync loop is delayed.
			_sync_progress_to_server()
			_log("[Round] We finished FIRST — snap timer: %.1f s" % snap_timer)
			countdown_label.show()

func _resolve_and_advance(finish_mode: String):
	if current_state == GameState.RESOLVING: return
	current_state = GameState.RESOLVING
	_last_resolved_round_id = max(_last_resolved_round_id, _server_round_id)
	
	var elapsed_ms: float = float(Time.get_ticks_msec() - sentence_start_time)
	# Guard against ultra-small elapsed time (debug skip / hitch / clock issues) producing extreme WPM and damage.
	# We cap both the minimum elapsed time and the maximum WPM used for combat.
	var safe_elapsed_ms: float = max(250.0, elapsed_ms)
	var time_elapsed_min: float = safe_elapsed_ms / 60000.0
	var words: float = float(target_sentence.length()) / 5.0
	var raw_wpm: int = int(words / time_elapsed_min) if time_elapsed_min > 0.0 else 0
	var wpm: int = clamp(raw_wpm, 0, 250)
	
	var accuracy = 100.0
	if total_keystrokes > 0:
		accuracy = (float(total_keystrokes - typos_count) / float(total_keystrokes)) * 100.0
	
	var result = SkillsManager.resolve_round(
		float(wpm), accuracy, typos_count,
		get_meta("opp_typos", 0),
		finish_mode,
		chosen_skill_id,
		HPManager.opponent_hp, HPManager.player_hp
	)
	
	for line in result.log:
		print("[Combat] ", line)
	
	# Apply HP changes
	if result.player_hp_delta != 0:
		HPManager.heal("player", result.player_hp_delta)
	if result.opp_hp_delta != 0:
		HPManager.heal("opponent", result.opp_hp_delta)
	if result.player_damage > 0:
		HPManager.take_damage("opponent", result.player_damage)
	
	# ── DEBUG: Skill Animation Stub ──────────────────────────────────────
	print("╔══════════════════════════════════════════╗")
	if chosen_skill_id == "":
		print("║  [NO SKILL] — Base attack only           ║")
	else:
		match finish_mode:
			"buff":
				print("║  🎯 [%s] — BUFF  (you finished 1st)   ║" % chosen_skill_id.to_upper())
			"debuff":
				print("║  ⬇️ [%s] — DEBUFF (you finished 2nd) ║" % chosen_skill_id.to_upper())
			"full_power":
				print("║  💥 [%s] — FULL POWER! (opp timed out)║" % chosen_skill_id.to_upper())
			"tie":
				print("║  ⚡ [%s] — TIE (both get buff)        ║" % chosen_skill_id.to_upper())
			"no_attack":
				print("║  ⏱️ [TIMEOUT] — No skill fires         ║")
	print("║  Player: %-30s  ║" % GameManager.user_data.username)
	print("║  DMG dealt:  %-5.0f                         ║" % result.player_damage)
	print("║  HP delta:   %+.0f                          ║" % result.player_hp_delta)
	
	# Update phantom stack before advancing
	var final_accuracy = 100.0
	if total_keystrokes > 0:
		final_accuracy = (float(total_keystrokes - typos_count) / float(total_keystrokes)) * 100.0
	if SkillsManager.selected_passive == "phantom":
		if final_accuracy >= 90.0 and SkillsManager.phantom_stack > 0:
			SkillsManager.phantom_stack = min(3, SkillsManager.phantom_stack + 1)
		elif final_accuracy >= 85.0 and SkillsManager.phantom_stack == 0:
			SkillsManager.phantom_stack = 1
		else:
			SkillsManager.phantom_stack = 0
			
	if HPManager.player_hp <= 0 or HPManager.opponent_hp <= 0:
		pass
	
	print("║  Your HP:    %.0f / %.0f                     ║" % [HPManager.player_hp, HPManager.player_max_hp])
	print("║  Opp HP:     %.0f / %.0f                     ║" % [HPManager.opponent_hp, HPManager.opponent_max_hp])
	print("║  Mana:       %d                             ║" % SkillsManager.player_mana)
	print("╚══════════════════════════════════════════╝")
	# ─────────────────────────────────────────────────────────────────────
	
	await get_tree().create_timer(2.0).timeout
	if GameManager.is_solo:
		start_skill_phase()
	elif GameManager.is_host:
		start_skill_phase(true)
		# Immediately re-poll so both clients converge quickly after fast debug actions (skip sentence).
		_poll_opponent_progress()

## DEPRECATED — kept as a compatibility stub
func _on_sentence_completed():
	_on_i_finished()

func _on_skill_pressed(skill_index: int):
	var idx = skill_index - 1
	if idx < SkillsManager.selected_skills.size():
		var skill = SkillsManager.selected_skills[idx]
		if SkillsManager.can_pick_skill(skill):
			chosen_skill_index = skill_index
			chosen_skill_id    = skill
			print("[Skill] Selected: %s (cost %d Mana)" % [skill, SkillsManager.SKILL_COSTS.get(skill, 0)])
			skill_select.hide()  # Only hide if the pick succeeded
		else:
			print("[Skill] Not enough Mana for %s (need %d, have %d)" % [skill, SkillsManager.SKILL_COSTS.get(skill, 0), SkillsManager.player_mana])
			# Don't hide — let player pick a different skill

func _save_match_history(won: bool):
	var wpm = 0.0
	var accuracy = 0.0
	# we just use some simple stats for now, or total average if possible.
	if total_keystrokes > 0:
		accuracy = (float(total_keystrokes - typos_count) / float(total_keystrokes)) * 100.0
	
	# Guard: if player never started typing, sentence_start_time is 0
	# which would produce a meaningless gigantic elapsed time
	var time_elapsed_min = 0.0
	if is_typing and sentence_start_time > 0:
		time_elapsed_min = (Time.get_ticks_msec() - sentence_start_time) / 60000.0
	if time_elapsed_min > 0:
		wpm = (float(total_keystrokes) / 5.0) / time_elapsed_min

	var req = HTTPRequest.new()
	add_child(req)
	
	var data = {
		"user_id": GameManager.user_data.id,
		"username": GameManager.user_data.username,
		"match_type": "online" if not GameManager.is_solo else "custom",
		"wpm": wpm,
		"accuracy": accuracy,
		"typos": typos_count,
		"won": won
	}
	
	var headers = ["Content-Type: application/json"]
	req.request(SERVER + "/api/game/history", headers, HTTPClient.METHOD_POST, JSON.stringify(data))
