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
var _victory_shown: bool = false

const _MIN_SKILL_COST: int = 2

func _can_pick_any_skill() -> bool:
	for s in SkillsManager.selected_skills:
		if SkillsManager.can_pick_skill(s):
			return true
	return false



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

const CHARACTER_HURT_ANIM = {
	"Riven": "hurt",
	"Zephon": "zephone-hurt",
	"Liora": "hurt",
}

const CHARACTER_DEATH_ANIM = {
	"Riven": "death",
	"Zephon": "zephone-death",
	"Liora": "death",
}

# Skill id -> animation base name.
const SKILL_ANIM_NAME = {
	"quickslash": "quickslash",
	"soulbreak": "soulbreak",
	"whiplash": "whipsplash",
}

func _get_sprite(node: Node) -> AnimatedSprite2D:
	if node == null:
		return null
	if node.has_node("AnimatedSprite2D"):
		return node.get_node("AnimatedSprite2D") as AnimatedSprite2D
	return null

func _safe_play_anim(node: Node, anim: String) -> void:
	var sprite: AnimatedSprite2D = _get_sprite(node)
	if sprite == null or sprite.sprite_frames == null:
		return
	if anim == "" or not sprite.sprite_frames.has_animation(anim):
		return
	sprite.play(anim)

func _fade_out_in(node: Node, out_s: float = 0.12, in_s: float = 0.12, hold_s: float = 0.03) -> void:
	var sprite: AnimatedSprite2D = _get_sprite(node)
	if sprite == null:
		return
	# Avoid stacking tweens on rapid resolves.
	if sprite.has_meta("fade_tween"):
		var prev = sprite.get_meta("fade_tween")
		if prev != null and prev is Tween:
			(prev as Tween).kill()

	sprite.modulate.a = 1.0
	var tween: Tween = create_tween()
	sprite.set_meta("fade_tween", tween)
	tween.tween_property(sprite, "modulate:a", 0.0, out_s).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.tween_interval(hold_s)
	tween.tween_property(sprite, "modulate:a", 1.0, in_s).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

func _restore_idle_after(node: Node, char_name: String, seconds: float) -> void:
	var sprite: AnimatedSprite2D = _get_sprite(node)
	if sprite == null:
		return
	var idle_anim: String = str(CHARACTER_IDLE_ANIM.get(char_name, "idle"))
	await get_tree().create_timer(seconds).timeout
	if is_instance_valid(sprite) and sprite.sprite_frames and sprite.sprite_frames.has_animation(idle_anim):
		sprite.play(idle_anim)

func _attack_anim_for(char_name: String, skill_id: String) -> String:
	var base: String = str(SKILL_ANIM_NAME.get(skill_id, ""))
	if base == "":
		base = "quickslash"
	# Zephon spriteframes use a prefix (zephone-quickslash etc).
	if char_name == "Zephon":
		return "zephone-" + base
	return base

func _play_combat_anims(skill_id: String, dealt_damage: float) -> void:
	# Only animate attacks when we actually deal damage.
	if dealt_damage <= 0:
		return
	var own_char: String = GameManager.selected_character
	var opp_char: String = GameManager.opponent_character

	var attack_anim: String = _attack_anim_for(own_char, skill_id)
	_safe_play_anim(p1, attack_anim)
	_fade_out_in(p1)
	_restore_idle_after(p1, own_char, 0.6)

	var death_anim: String = str(CHARACTER_DEATH_ANIM.get(opp_char, "death"))
	var hurt_anim: String = str(CHARACTER_HURT_ANIM.get(opp_char, "hurt"))
	if HPManager.opponent_hp <= 0:
		_safe_play_anim(p2, death_anim)
	else:
		_safe_play_anim(p2, hurt_anim)
		_fade_out_in(p2)
	_restore_idle_after(p2, opp_char, 0.6)

@onready var typing_label = $HUD/TypingText
@onready var skill_select = $HUD/SkillSelect
@onready var countdown_label = $HUD/CountdownText
@onready var stats_label     = $HUD/OwnTypingStats
@onready var opp_stats_label = $HUD/OppTypingStats
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
var _typing_go_at_ms: float = 0.0
var _last_snap_fallback_log_ms: int = 0
var _last_resolved_round_id: int = 0
var _snap_trace_active: bool = false
var _snap_trace_last_s: int = -1
var _snap_trace_line: String = ""
var _snap_trace_start_s: int = 0
var _last_room_seq: int = -1
var _last_opp_words: int = 0
var _opp_chosen_skill: String = ""

var _host_skill_phase_requested: bool = false
var _host_typing_phase_requested: bool = false

## Opponent's equipped skills — populated from room poll so
## _should_host_fast_forward_skill_select() can check opponent mana.
var _opp_skills: Array = []

func _ready():
	_build_pause_panel()
	HPManager.init_game()
	# Note: HPManager.init_game() calls SkillsManager.reset_match() internally (fix #3),
	# so no separate reset_match() call is needed here.
	if not GameManager.is_solo and GameManager.current_room != "":
		seed(GameManager.current_room.hash())
	else:
		randomize()

	# Host publishes initial HP so both clients converge if one loads late.
	if not GameManager.is_solo and GameManager.current_room != "" and GameManager.is_host:
		_host_sync_hp()
		
	_spawn_players()
	
	skill_select.hide()
	countdown_label.hide()
	typing_label.show()
	if stats_label:
		stats_label.show()
	if opp_stats_label:
		opp_stats_label.show()
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

var _pause_panel: Panel = null
var _pause_visible: bool = false

func _build_pause_panel() -> void:
	_pause_panel = Panel.new()
	_pause_panel.set_anchors_preset(Control.PRESET_CENTER)
	_pause_panel.custom_minimum_size = Vector2(320, 180)
	_pause_panel.visible = false
	_pause_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	$HUD.add_child(_pause_panel)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 24
	vbox.offset_top = 24
	vbox.offset_right = -24
	vbox.offset_bottom = -24
	vbox.add_theme_constant_override("separation", 16)
	_pause_panel.add_child(vbox)

	var title = Label.new()
	title.text = "Game Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	var btn_resume = Button.new()
	btn_resume.text = "Resume"
	btn_resume.pressed.connect(_toggle_pause_panel)
	vbox.add_child(btn_resume)

	var btn_leave = Button.new()
	btn_leave.text = "Forfeit & Leave"
	btn_leave.pressed.connect(_on_forfeit_pressed)
	vbox.add_child(btn_leave)

func _toggle_pause_panel() -> void:
	_pause_visible = !_pause_visible
	if is_instance_valid(_pause_panel):
		_pause_panel.visible = _pause_visible

func _on_forfeit_pressed() -> void:
	_pause_visible = false
	if is_instance_valid(_pause_panel):
		_pause_panel.visible = false
	# Close the room so the opponent knows we left
	if not GameManager.is_solo and GameManager.current_room != "":
		var http = HTTPRequest.new()
		add_child(http)
		http.request_completed.connect(func(_r,_c,_h,_b): http.queue_free())
		http.request(SERVER + "/api/rooms/" + GameManager.current_room, GameManager.get_auth_headers(), HTTPClient.METHOD_DELETE)
		GameManager.current_room = ""
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")

func _show_opponent_forfeited_overlay() -> void:
	if _victory_shown: return
	_victory_shown = true
	GameManager.current_room = ""

	# Build overlay panel
	var overlay = Panel.new()
	overlay.set_anchors_preset(Control.PRESET_CENTER)
	overlay.custom_minimum_size = Vector2(380, 200)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	$HUD.add_child(overlay)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 24
	vbox.offset_top = 24
	vbox.offset_right = -24
	vbox.offset_bottom = -24
	vbox.add_theme_constant_override("separation", 16)
	overlay.add_child(vbox)

	var msg = Label.new()
	msg.text = "Opponent forfeited!"
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.add_theme_font_size_override("font_size", 24)
	msg.add_theme_color_override("font_color", Color.GREEN)
	vbox.add_child(msg)

	var countdown_lbl = Label.new()
	countdown_lbl.text = "Returning to main menu in 10..."
	countdown_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(countdown_lbl)

	var leave_btn = Button.new()
	leave_btn.text = "Leave Now"
	leave_btn.pressed.connect(func():
		get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
	)
	vbox.add_child(leave_btn)

	# 10s countdown then auto-redirect
	var t = 10
	var timer = get_tree().create_timer(1.0)
	while t > 0:
		await timer.timeout
		t -= 1
		if is_instance_valid(countdown_lbl):
			countdown_lbl.text = "Returning to main menu in %d..." % t
		if t > 0:
			timer = get_tree().create_timer(1.0)
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")

func _on_entity_died(entity: String):
	if _victory_shown:
		return
	# Only trigger game over if we are not already resolving/ended
	if current_state == GameState.RESOLVING:
		# Let the current resolution finish naturally,
		# but kill the awaited timer and force end immediately
		pass
	if current_state == GameState.TYPING or current_state == GameState.SKILL_SELECT or current_state == GameState.RESOLVING:
		_victory_shown = true
		current_state = GameState.RESOLVING  # block further input

		# Play death animation before showing victory.
		var my_char: String = GameManager.selected_character
		var opp_char: String = GameManager.opponent_character
		if entity == "player":
			var death_anim: String = str(CHARACTER_DEATH_ANIM.get(my_char, "death"))
			_safe_play_anim(p1, death_anim)
		else:
			var death_anim: String = str(CHARACTER_DEATH_ANIM.get(opp_char, "death"))
			_safe_play_anim(p2, death_anim)
		await get_tree().create_timer(0.6).timeout
		
		var victory_scene = load("res://scenes/ui/victory_screen.tscn").instantiate()
		# Pause everything behind the victory panel.
		get_tree().paused = true
		victory_scene.process_mode = Node.PROCESS_MODE_ALWAYS
		$HUD.add_child(victory_scene)
		
		var won = (entity == "opponent")
		_save_match_history(won)
		victory_scene.set_result(won)

func _swap_controls(a: Control, b: Control) -> void:
	if a == null or b == null:
		return
	var a_anchors = [a.anchor_left, a.anchor_right]
	var a_offsets = [a.offset_left, a.offset_right]
	var b_anchors = [b.anchor_left, b.anchor_right]
	var b_offsets = [b.offset_left, b.offset_right]
	a.anchor_left = b_anchors[0]
	a.anchor_right = b_anchors[1]
	a.offset_left = b_offsets[0]
	a.offset_right = b_offsets[1]
	b.anchor_left = a_anchors[0]
	b.anchor_right = a_anchors[1]
	b.offset_left = a_offsets[0]
	b.offset_right = a_offsets[1]

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
	# Fix #13: reset opponent's last-round skill so stale data isn't shown
	_opp_chosen_skill  = ""
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
	# Only show the skill panel if the player can actually afford at least one skill.
	# If they can't, hide it immediately so the UI doesn't show a useless disabled panel.
	if _can_pick_any_skill():
		skill_select.show()
	else:
		skill_select.hide()
	countdown_label.show()
	typing_label.hide()
	if stats_label:
		stats_label.hide()
	if opp_stats_label:
		opp_stats_label.hide()

	# Online: host declares the new skill-select phase (authoritative timers + round id)
	if announce_phase and not GameManager.is_solo and GameManager.current_room != "" and GameManager.is_host:
		_host_skill_phase_requested = true
		var next_round = max(1, _server_round_id) + 1 if _server_round_id > 0 else 2
		_server_round_id = next_round
		_host_set_phase("skill_select", next_round)

func start_typing_phase(announce_phase: bool = false):
	current_state = GameState.TYPING
	skill_select.hide()
	# Fix #9: hide accuracy warning at the start of every typing phase so it
	# doesn't persist from the previous round.
	if accuracy_warning:
		accuracy_warning.hide()
	_host_typing_phase_requested = announce_phase and GameManager.is_host
	_local_first_finish_at_ms = 0.0
	_local_first_finish_by = ""
	if has_meta("passive_highlight_word"):
		remove_meta("passive_highlight_word")
	if has_meta("passive_highlight_type"):
		remove_meta("passive_highlight_type")
	
	skill_timer = 0.0
	is_typing = false
	current_index = 0
	total_keystrokes = 0
	typos_count = 0
	typos_in_current_word = 0
	typed_statuses.clear()
	_last_mutation_index = 0
	# Fix #4: reset per-round opponent word counter so mana tracking starts fresh
	_last_opp_words = 0

	if GameManager.is_solo or GameManager.current_room == "":
		current_round += 1
	else:
		current_round = _server_round_id if _server_round_id > 0 else max(1, current_round)
	pick_random_sentence()
	
	typing_label.show()
	countdown_label.show()
	countdown_label.show()
	if stats_label:
		stats_label.show()
	if opp_stats_label:
		opp_stats_label.show()
	_host_typing_phase_requested = false
	remove_meta("jumble_triggered_this_round")
	update_typing_ui()
	
	set_meta("jumble_triggered_this_round", false)
	
	if SkillsManager.selected_passive == "stutter" and SkillsManager.opponent_win_streak > 0:
		_queued_mutations.append({ "type": "stutter" })
		
	if SkillsManager.selected_passive == "phantom" and SkillsManager.phantom_stack > 0:
		for i in range(SkillsManager.phantom_stack):
			_queued_mutations.append({ "type": "phantom" })
			
	_log("[Round] Starting TYPING Phase | target_len=%d | round_id=%d" % [target_sentence.length(), _server_round_id])
	# Do not start typing immediately; we run a short ready countdown before the round timer starts.
	is_typing = false
	sentence_start_time = 0.0
	if not GameManager.is_solo and GameManager.current_room != "" and _server_typing_started_at_ms > 0.0:
		_typing_go_at_ms = _server_typing_started_at_ms
	else:
		if current_round <= 1:
			_typing_go_at_ms = float(Time.get_ticks_msec()) + 3000.0
			countdown_label.text = "Get Ready: 3"
		else:
			_typing_go_at_ms = float(Time.get_ticks_msec())

	
	if announce_phase and not GameManager.is_solo and GameManager.current_room != "" and GameManager.is_host:
		_host_typing_phase_requested = true
		_host_set_phase("typing", max(1, _server_round_id))

func _spawn_players():

	# Hide the pre-placed Player nodes (they're static placeholders in the .tscn)
	if has_node("Player"):
		$Player.hide()
	if has_node("Player2"):
		$Player2.hide()

	# Each player always sees themselves on the left and the opponent on the right.
	# This gives a consistent perspective regardless of host/guest role.
	var am_i_left = true
		
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
		_swap_controls(own_progress_bar, enemy_progress_bar)
		_swap_controls(hp_bar_own, hp_bar_opp)
		_swap_controls(mana_bar_own, mana_bar_opp)

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
	var path = "res://assets/data/sentences.json"
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
		stats_label.text = "WPM: 0 | Typos: 0 | Acc: 100%"
	if opp_stats_label:
		opp_stats_label.text = "WPM: 0 | Typos: 0 | Acc: 100%"
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
		# If server is ALREADY in typing phase for a new round, catch up immediately.
		if not GameManager.is_solo and GameManager.current_room != "" and _server_phase == "typing" and _server_round_id > _last_resolved_round_id:
			_log("[Net] Catching up to typing phase | round_id=%d" % _server_round_id)
			start_typing_phase(false)
			return

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
		else:
			# Fast-forward to typing if neither player can afford any skill.
			# Covers two cases:
			#   1. Both players have 0 mana (nobody can pick) → skip immediately.
			#   2. Host already picked, opponent can't afford anything → skip remaining wait.
			if GameManager.is_solo or GameManager.current_room == "":
				# Solo: skip the 10s if the player can't cast anything
				if not _can_pick_any_skill() and chosen_skill_id == "":
					_log("[Phase] Solo fast-forward: no mana to cast — skipping skill timer")
					start_typing_phase()
			elif GameManager.is_host and _server_phase == "skill_select" and not _host_typing_phase_requested:
				if _should_host_fast_forward_skill_select():
					_log("[Phase] Fast-forward: neither player can cast — skipping skill timer")
					_host_typing_phase_requested = true
					_host_set_phase("typing", max(1, _server_round_id))
			
		
	elif current_state == GameState.TYPING:
		# Ready countdown (3s) before typing starts.
		if not GameManager.is_solo and GameManager.current_room != "" and _server_phase == "typing" and _server_typing_started_at_ms > 0.0:
			var now_ms_ready = _get_synced_server_time_ms()
			if now_ms_ready < _server_typing_started_at_ms:
				var sec_left = int(ceil((_server_typing_started_at_ms - now_ms_ready) / 1000.0))
				if countdown_label:
					countdown_label.text = "Get Ready: %d" % max(0, sec_left)
				return
		elif GameManager.is_solo or GameManager.current_room == "":
			var now_ticks_ready = float(Time.get_ticks_msec())
			if _typing_go_at_ms > 0.0 and now_ticks_ready < _typing_go_at_ms:
				var sec_left = int(ceil((_typing_go_at_ms - now_ticks_ready) / 1000.0))
				if countdown_label:
					countdown_label.text = "Get Ready: %d" % max(0, sec_left)
				return


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
				snap_active = false
				if countdown_label:
					countdown_label.hide()
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
			# Fix #13: show opponent's chosen skill so the variable is actually used in UI
			var opp_skill_text = ""
			if not GameManager.is_solo and _opp_chosen_skill != "":
				opp_skill_text = " | Skill: %s" % _opp_chosen_skill.capitalize()
			stats_label.text = "WPM: %d | Typos: %d | Acc: %.1f%%%s" % [wpm, typos_count, accuracy, opp_skill_text]

		# ── Opponent stats (live from polled progress) ─────────────────
		if opp_stats_label:
			var opp_prog = enemy_typing_progress / 100.0
			var opp_total_words = float(target_sentence.length()) / 5.0
			var opp_words_typed = opp_prog * opp_total_words
			# Estimate opponent WPM using the same elapsed time as our own round timer
			var opp_wpm = 0
			var time_elapsed_min_opp = 0.0
			if is_typing and sentence_start_time > 0:
				time_elapsed_min_opp = (Time.get_ticks_msec() - sentence_start_time) / 60000.0
			if time_elapsed_min_opp > 0:
				opp_wpm = int(opp_words_typed / time_elapsed_min_opp)
			var opp_typos_val = int(get_meta("opp_typos")) if has_meta("opp_typos") else 0
			# Accuracy: progress = total letters typed (correct + wrong) / sentence_length
			# so total_typed = progress × sentence_length, correct = total_typed - typos
			var opp_acc = 100.0
			var opp_total_typed = opp_prog * float(target_sentence.length())
			if opp_total_typed > 0:
				opp_acc = ((opp_total_typed - float(opp_typos_val)) / opp_total_typed) * 100.0
				opp_acc = clampf(opp_acc, 0.0, 100.0)
			var opp_skill_text2 = ""
			if not GameManager.is_solo and _opp_chosen_skill != "":
				opp_skill_text2 = " | Skill: %s" % _opp_chosen_skill.capitalize()
			opp_stats_label.text = "WPM: %d | Typos: %d | Acc: %.1f%%%s" % [opp_wpm, opp_typos_val, opp_acc, opp_skill_text2]
	
	# ── Typing progress bars ──────────────────────
	# Show raw typing progress (0→1). The accuracy warning blocks finishing
	# if acc < 60% — no need to penalise the bar display itself.
	var my_prog = float(current_index) / float(target_sentence.length()) if target_sentence.length() > 0 else 0.0
	own_progress_bar.max_value = 1.0
	own_progress_bar.value     = my_prog
	enemy_progress_bar.max_value = 1.0
	enemy_progress_bar.value     = enemy_typing_progress / 100.0

	# ── HP / Mana bars ─────────────────────────────
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
	# Do not send >= 0.999 until the player has actually finished (accuracy check passed).
	# This prevents the server marking first_finish_at while the warning is still showing.
	if accuracy_warning and accuracy_warning.visible:
		prog = minf(prog, 0.98)
	
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r,_c,_h,_b): http.queue_free())
	var payload = {
		"user_id": GameManager.user_data.id,
		"progress": prog,
		"typos": typos_count,
		"chosen_skill": chosen_skill_id
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
	# Opponent forfeited — room was deleted (404)
	if _code == 404 and not GameManager.is_solo and not _victory_shown:
		_show_opponent_forfeited_overlay()
		return
	var recv_local_ms: float = Time.get_unix_time_from_system() * 1000.0
	# Fix #15: log JSON parse failures so silent network errors are visible in debug output
	var raw_text = body.get_string_from_utf8()
	var json = JSON.parse_string(raw_text)
	if not json:
		if raw_text.length() > 0:
			_log("[Poll] JSON parse failed — raw: %s" % raw_text.left(120))
		return
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
			_opp_chosen_skill = str(json.get("guest_skill", ""))
			my_muts   = json.get("host_mutations", [])
			# Fix #1: keep opponent skill list in sync for fast-forward checks
			var g_skills = json.get("guest_skills", null)
			if g_skills != null and g_skills is Array:
				_opp_skills = g_skills
		else:
			opp_prog  = json.get("host_progress", 0.0)
			opp_typos = json.get("host_typos", 0)
			_opp_chosen_skill = str(json.get("host_skill", ""))
			my_muts   = json.get("guest_mutations", [])
			# Fix #1: keep opponent skill list in sync for fast-forward checks
			var h_skills = json.get("host_skills", null)
			if h_skills != null and h_skills is Array:
				_opp_skills = h_skills
			
		# Track opponent mana gain
		var total_words = float(target_sentence.length()) / 5.0
		var cur_opp_words = int(floor(opp_prog * total_words))
		if cur_opp_words > _last_opp_words:
			var diff = cur_opp_words - _last_opp_words
			for i in range(diff):
				SkillsManager.on_opponent_accurate_word()
			_last_opp_words = cur_opp_words

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
				# Enemy finished before us — award them the +2 finish-first mana bonus
				# Fix #4: opponent finish-first mana bonus was never applied
				SkillsManager.on_opponent_finish_first()
				# Start snap for us
				_log("[Round] Enemy finished first — snap timer started for us (+2 opp mana)")
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
	if _server_phase == "typing" and _server_typing_started_at_ms > 0.0:
		_typing_go_at_ms = _server_typing_started_at_ms
	_server_first_finish_at_ms = float(room.get("first_finish_at", _server_first_finish_at_ms))
	_server_first_finish_by = "" if room.get("first_finish_by", null) == null else str(room.get("first_finish_by"))
	_server_round_id = int(room.get("round_id", _server_round_id))

	# HP sync (host authoritative)
	if room.has("host_hp") and room.has("guest_hp"):
		var host_hp_v: float = float(room.get("host_hp", 0))
		var guest_hp_v: float = float(room.get("guest_hp", 0))
		if host_hp_v > 0 or guest_hp_v > 0:
			if GameManager.is_host:
				if abs(HPManager.player_hp - host_hp_v) > 0.01:
					HPManager.set_hp("player", host_hp_v)
				if abs(HPManager.opponent_hp - guest_hp_v) > 0.01:
					HPManager.set_hp("opponent", guest_hp_v)
			else:
				if abs(HPManager.player_hp - guest_hp_v) > 0.01:
					HPManager.set_hp("player", guest_hp_v)
				if abs(HPManager.opponent_hp - host_hp_v) > 0.01:
					HPManager.set_hp("opponent", host_hp_v)
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

func _host_sync_hp() -> void:
	if GameManager.current_room == "" or GameManager.user_data.id == 0:
		return
	if GameManager.is_solo or not GameManager.is_host:
		return
	var http := HTTPRequest.new()
	add_child(http)
	var payload: Dictionary = {
		"user_id": GameManager.user_data.id,
		"host_hp": HPManager.player_hp,
		"guest_hp": HPManager.opponent_hp
	}
	var body := JSON.stringify(payload)
	http.request_completed.connect(func(_r, _c, _h, _b):
		if is_instance_valid(http):
			http.queue_free()
	)
	http.request(SERVER + "/api/rooms/" + GameManager.current_room + "/hp", GameManager.get_auth_headers(), HTTPClient.METHOD_PATCH, body)

@export var correct_color: Color = Color.GREEN
@export var wrong_color: Color = Color.RED
@export var current_char_color: Color = Color.YELLOW
@export var upcoming_color: Color = Color.WHITE

func _apply_mutation(mut: Dictionary):
	# Deterministic RNG for mutations: seed with room, round and type hash
	if not GameManager.is_solo and GameManager.current_room != "":
		seed(GameManager.current_room.hash() + int(current_round) + str(mut.get("type")).hash())
	
	var type = mut.get("type", "")
	_show_passive_popup(type)
	
	# Stutter Effect 2 is a special case: duplicates the word JUST typed.
	if type == "stutter_effect2":
		var prev_space = target_sentence.rfind(" ", current_index - 2)
		var start_idx = prev_space + 1 if prev_space != -1 else 0
		var word_just_typed = target_sentence.substr(start_idx, current_index - start_idx).strip_edges()
		if word_just_typed.length() > 0:
			target_sentence = target_sentence.substr(0, current_index) + " " + word_just_typed + target_sentence.substr(current_index)
			update_typing_ui()
		return

	# Standard mutations affect the UPCOMING text (after the current word's space)
	var remaining_text = target_sentence.substr(current_index)
	var first_space = remaining_text.find(" ")
	if first_space == -1: return # No more upcoming words to mutate
	
	var unstarted_part = remaining_text.substr(first_space + 1)
	var words = unstarted_part.split(" ", false) # false = don't include empty
	if words.size() == 0: return

	if type == "jumble":
		words.shuffle()
	elif type == "erosion":
		var w_idx = randi() % words.size()
		var w = words[w_idx]
		if w.length() > 0:
			var c_idx = randi() % w.length()
			words[w_idx] = w.substr(0, c_idx) + "_" + w.substr(c_idx + 1)
	elif type == "stutter":
		var w_idx = randi() % words.size()
		words[w_idx] = words[w_idx] + " " + words[w_idx]
		set_meta("stutter_effect2_pending", true)
		set_meta("passive_highlight_word", words[w_idx].split(" ")[0])
	elif type == "reversal":
		# Reverse the upcoming part entirely
		var full_upcoming = " ".join(words)
		var reversed = ""
		for i in range(full_upcoming.length() - 1, -1, -1):
			reversed += full_upcoming[i]
		words = [reversed]
	elif type == "phantom":
		# Swap two random words
		if words.size() >= 2:
			var i1 = randi() % words.size()
			var i2 = randi() % words.size()
			var tmp = words[i1]
			words[i1] = words[i2]
			words[i2] = tmp

	target_sentence = target_sentence.substr(0, current_index + first_space + 1) + " ".join(words)
	update_typing_ui()

func _show_passive_popup(passive_type: String) -> void:
	if GameManager.is_solo:
		return
	# Mutations received are caused by the opponent, so show above the opponent sprite.
	var target_node: Node2D = p2
	if target_node == null:
		return
	var label: Label = Label.new()
	label.text = passive_type.capitalize() + " activated"
	label.modulate = Color(1, 1, 1, 1)
	add_child(label)
	label.global_position = target_node.global_position + Vector2(0, -80)
	var tween: Tween = create_tween()
	tween.tween_property(label, "global_position:y", label.global_position.y - 30, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(label, "modulate:a", 0.0, 0.6)
	tween.finished.connect(func():
		if is_instance_valid(label):
			label.queue_free()
	)

func update_typing_ui():
	if accuracy_warning:
		accuracy_warning.hide()
		
	var c_hex = "#" + correct_color.to_html(false)
	var w_hex = "#" + wrong_color.to_html(false)
	var cur_hex = "#" + current_char_color.to_html(false)
	var up_hex = "#" + upcoming_color.to_html(false)
		
	var highlight_word: String = ""
	if has_meta("passive_highlight_word"):
		highlight_word = str(get_meta("passive_highlight_word"))
	var highlight_hex = "#ffcc00"

	var bbcode = "[center]"
	for i in range(current_index):
		var color = c_hex if typed_statuses[i] else w_hex
		bbcode += "[color=" + color + "]" + target_sentence[i] + "[/color]"
		
	if current_index < target_sentence.length():
		bbcode += "[color=" + cur_hex + "][u]" + target_sentence[current_index] + "[/u][/color]"
		if current_index + 1 < target_sentence.length():
			var upcoming = target_sentence.substr(current_index + 1)
			# Passive highlight: for stutter, color the duplicated word to show it triggered.
			if highlight_word != "":
				upcoming = upcoming.replace(" " + highlight_word + " ", " [color=" + highlight_hex + "]" + highlight_word + "[/color] ")
			bbcode += "[color=" + up_hex + "]" + upcoming + "[/color]"
			
	bbcode += "[/center]"
	typing_label.text = bbcode

func _unhandled_input(event):
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_toggle_pause_panel()
			return

	if current_state != GameState.TYPING: return
	# During the ready countdown, ignore input so nobody can start early.
	if not GameManager.is_solo and GameManager.current_room != "" and _server_phase == "typing" and _server_typing_started_at_ms > 0.0:
		if _get_synced_server_time_ms() < _server_typing_started_at_ms:
			return
	elif (GameManager.is_solo or GameManager.current_room == "") and _typing_go_at_ms > 0.0:
		if float(Time.get_ticks_msec()) < _typing_go_at_ms:
			return
	
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_BACKSPACE:
			if current_index > 0:
				var was_typo = typed_statuses.size() > 0 and not typed_statuses.back()
				if was_typo:
					# Undo the typo: remove it from both the word counter and the global counts
					typos_in_current_word = max(0, typos_in_current_word - 1)
					typos_count     = max(0, typos_count - 1)
					total_keystrokes = max(0, total_keystrokes - 1)
				else:
					# Correct character being erased — remove its keystroke too
					total_keystrokes = max(0, total_keystrokes - 1)

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
					if has_meta("stutter_effect2_pending") and bool(get_meta("stutter_effect2_pending")):
						set_meta("stutter_effect2_pending", false)
						_apply_mutation({ "type": "stutter_effect2" })
						
					# Jumble check
					var jumble_done := has_meta("jumble_triggered_this_round") and bool(get_meta("jumble_triggered_this_round"))
					if SkillsManager.selected_passive == "jumble" and SkillsManager.player_mana >= 7 and not jumble_done:
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
					
					# Pass condition: at least 60% of the sentence's letters typed correctly.
					# correct_letters = total_keystrokes - typos_count (after backspace corrections).
					var correct_letters = total_keystrokes - typos_count
					var required = int(ceil(float(target_sentence.length()) * 0.6))
					if correct_letters < required:
						if accuracy_warning:
							accuracy_warning.show()
					else:
						_on_i_finished()

## Called when THIS player finishes typing.
func _on_i_finished():
	if i_finished: return  # guard against double-trigger
	i_finished = true
	typing_label.hide()
	if stats_label:
		stats_label.hide()
	if opp_stats_label:
		opp_stats_label.hide()
	
	if enemy_finished:
		# Enemy already finished before us — we're the loser
		snap_active = false
		if countdown_label:
			countdown_label.hide()
		# Send an immediate final progress update (progress=1.0) so the winner can stop snap early.
		_sync_progress_to_server()
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
	# Hide timers while resolving so UI can't show stale snap/60s countdown.
	if countdown_label:
		countdown_label.hide()
	if typing_label:
		typing_label.hide()
	if stats_label:
		stats_label.hide()
	if opp_stats_label:
		opp_stats_label.hide()
	
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
		(int(get_meta("opp_typos")) if has_meta("opp_typos") else 0),
		finish_mode,
		chosen_skill_id,
		HPManager.opponent_hp, HPManager.player_hp,
		"player"
	)
	
	# ── Authoritative Opponent Resolution (Host Only) ──────────────────────
	if not GameManager.is_solo and GameManager.is_host:
		var opp_finish_mode = "debuff"
		if finish_mode == "debuff": opp_finish_mode = "buff"
		elif finish_mode == "full_power": opp_finish_mode = "dnf"
		elif finish_mode == "tie": opp_finish_mode = "tie"
		elif finish_mode == "no_attack": opp_finish_mode = "no_attack"
		
		# Estimate opponent WPM
		var opp_wpm = 0
		if opp_finish_mode in ["buff", "tie"]:
			# They finished first or tied; use the server-synced time
			var start_ms = GameManager.match_start_time * 1000.0
			var finish_ms = _server_first_finish_at_ms if _server_first_finish_at_ms > 0 else float(Time.get_ticks_msec())
			var dur_min = (finish_ms - start_ms) / 60000.0
			opp_wpm = clamp(int(words / dur_min) if dur_min > 0.0 else 0, 0, 250)
		elif opp_finish_mode == "debuff":
			# They finished within 10s snap
			opp_wpm = 40 # conservative estimate for 2nd place
			
		var opp_acc = 100.0 # simplified for now
		var opp_typos = int(get_meta("opp_typos")) if has_meta("opp_typos") else 0
		
		var opp_result = SkillsManager.resolve_round(
			float(opp_wpm), opp_acc, opp_typos, typos_count,
			opp_finish_mode, _opp_chosen_skill,
			HPManager.player_hp, HPManager.opponent_hp,
			"opponent"
		)
		
		# Combine results
		result.player_hp_delta += opp_result.player_hp_delta # Self HP changes
		result.opp_hp_delta    += opp_result.opp_hp_delta    # Damage to Guest
		
		for line in opp_result.log:
			result.log.append(line)
	
	for line in result.log:
		print("[Combat] ", line)
	
	# Apply HP changes
	
	
	if result.player_hp_delta != 0:
		HPManager.heal("player", result.player_hp_delta)
	if result.opp_hp_delta != 0:
		HPManager.heal("opponent", result.opp_hp_delta)
	if result.player_damage > 0:
		HPManager.take_damage("opponent", result.player_damage)
	
	# Skill-based attack animation (uses AnimatedSprite2D frames if present).
	_play_combat_anims(chosen_skill_id, result.player_damage)

	# Online: host syncs authoritative HP after every resolution so the other client can't diverge.
	if not GameManager.is_solo and GameManager.current_room != "" and GameManager.is_host:
		_host_sync_hp()
	
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
			# Online: if opponent can't possibly pick (no mana), host can skip the remaining timer.
			if not GameManager.is_solo and GameManager.current_room != "" and GameManager.is_host and _server_phase == "skill_select" and not _host_typing_phase_requested:
				if _should_host_fast_forward_skill_select():
					_host_typing_phase_requested = true
					_host_set_phase("typing", max(1, _server_round_id))
		else:
			print("[Skill] Not enough Mana for %s (need %d, have %d)" % [skill, SkillsManager.SKILL_COSTS.get(skill, 0), SkillsManager.player_mana])
			# Don't hide — let player pick a different skill

func _should_host_fast_forward_skill_select() -> bool:
	# If I haven't picked yet AND I can still afford a skill, don't fast forward
	if chosen_skill_id == "" and _can_pick_any_skill(): return false

	# If the opponent can still afford any of their skills, don't fast forward
	var opp_can_pick = false
	for s_id in _opp_skills:
		if SkillsManager.can_pick_skill(s_id, true):
			opp_can_pick = true
			break

	return not opp_can_pick

func _save_match_history(won: bool):
	# Only save for logged-in users.
	if GameManager.user_data.id == 0:
		return
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
	if not is_finite(wpm):
		wpm = 0.0
	if not is_finite(accuracy):
		accuracy = 0.0
	wpm = clampf(wpm, 0.0, 250.0)
	accuracy = clampf(accuracy, 0.0, 100.0)

	var req = HTTPRequest.new()
	add_child(req)
	
	var data = {
		"user_id": GameManager.user_data.id,
		"username": GameManager.user_data.username,
		# Distinguish matchmaking vs custom lobby.
		# - solo:      custom
		# - online mm: online
		# - online room (invite/custom lobby): custom
		"match_type": "custom" if GameManager.is_solo else ("online" if GameManager.is_matchmaking else "custom"),
		"wpm": wpm,
		"accuracy": accuracy,
		"typos": typos_count,
		"won": won
	}
	
	var headers = ["Content-Type: application/json"]
	req.request(SERVER + "/api/game/history", headers, HTTPClient.METHOD_POST, JSON.stringify(data))
