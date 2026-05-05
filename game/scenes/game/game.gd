extends Control

## Game - thin orchestrator.
## Heavy logic lives in four child components:
##   AnimationController  - sprites, animations, passive popups
##   NetworkSync          - HTTP polling, progress sync, phase PATCH
##   TypingHandler        - keyboard input, sentence, mutations, typing UI
##   CombatResolver       - round resolution, HP application, victory screens

# Component references
@onready var anim:   Node = $AnimationController
@onready var net:    Node = $NetworkSync
@onready var typing: Node = $TypingHandler
@onready var combat: Node = $CombatResolver

enum GameState { SKILL_SELECT, TYPING, RESOLVING }
var current_state: int = GameState.SKILL_SELECT
var current_round: int = 0
var skill_timer: float   = 10.0
var round_timer: float   = 60.0
var snap_timer: float    = 10.0
var snap_active: bool    = false
var i_finished: bool     = false
var enemy_finished: bool = false
var _victory_shown: bool = false
var _initialized: bool   = false
var chosen_skill_id: String = ""
var chosen_skill_index: int = -1
var _server_phase: String               = ""
var _server_phase_started_at_ms: float  = 0.0
var _server_typing_started_at_ms: float = 0.0
var _server_first_finish_at_ms: float   = 0.0
var _server_first_finish_by: String     = ""
var _server_round_id: int               = 0
var _last_resolved_round_id: int        = 0
var _typing_go_at_ms: float             = 0.0
var _local_first_finish_at_ms: float    = 0.0
var _local_first_finish_by: String      = ""
var _host_typing_phase_requested: bool  = false
var _host_skill_phase_requested: bool   = false
var _opp_skills: Array                  = []
var _last_snap_fallback_log_ms: int     = 0
var _snap_trace_active: bool            = false
var _snap_trace_last_s: int             = -1
var _snap_trace_line: String            = ""
var _snap_trace_start_s: int            = 0
var _last_room_seq: int                 = -1
var _last_opp_words: int                = 0
@onready var typing_label       = $HUD/TypingText
@onready var skill_select       = $HUD/SkillSelect
@onready var countdown_label    = $HUD/CountdownText
@onready var stats_label        = $HUD/OwnTypingStats
@onready var opp_stats_label    = $HUD/OppTypingStats
@onready var accuracy_warning   = $HUD/AccuracyWarning
@onready var own_progress_bar   = $HUD/OwnProgress
@onready var enemy_progress_bar = $HUD/EnemyProgress
@onready var hp_bar_own         = $HUD/Stats/OwnHp
@onready var hp_bar_opp         = $HUD/Stats/EnemyHp
@onready var mana_bar_own       = $HUD/Stats/OwnMana
@onready var mana_bar_opp       = $HUD/Stats/EnemyMana
var SERVER: String:
	get: return GameManager.SERVER_URL
var _pause_panel: Panel  = null
var _pause_visible: bool = false

# ─────────────────────────
# Lifecycle
# ─────────────────────────────────────────────

func _ready() -> void:
	_build_pause_panel()
	call_deferred("_deferred_init")

func _deferred_init() -> void:
	HPManager.init_game()
	if not GameManager.is_solo and GameManager.current_room != "":
		seed(GameManager.current_room.hash())
	else:
		randomize()
	combat.typing_handler  = typing
	combat.network_sync    = net
	combat.anim_controller = anim
	typing.typing_label     = typing_label
	typing.accuracy_warning = accuracy_warning
	typing.word_completed_accurately.connect(_on_word_completed_accurately)
	typing.sentence_finished.connect(_on_sentence_finished)
	net.room_polled.connect(_on_room_polled)
	net.opponent_forfeited.connect(_on_opponent_forfeited)
	HPManager.entity_died.connect(_on_entity_died)
	if not GameManager.is_solo and GameManager.current_room != "" and GameManager.is_host:
		net.sync_hp()
	anim.spawn_players(self)
	skill_select.hide()
	countdown_label.hide()
	typing_label.show()
	if stats_label:     stats_label.show()
	if opp_stats_label: opp_stats_label.show()
	if accuracy_warning: accuracy_warning.hide()
	if has_node("HUD/SkillSelect/HBoxContainer/Skill1"):
		$HUD/SkillSelect/HBoxContainer/Skill1.pressed.connect(_on_skill_pressed.bind(1))
	if has_node("HUD/SkillSelect/HBoxContainer/Skill2"):
		$HUD/SkillSelect/HBoxContainer/Skill2.pressed.connect(_on_skill_pressed.bind(2))
	typing.load_sentences()
	start_skill_phase()
	_initialized = true

func _role_tag() -> String:
	if GameManager.is_solo: return "SOLO"
	return "HOST" if GameManager.is_host else "GUEST"

func _log(msg: String) -> void:
	print("[%s][%s] %s" % [GameManager.session_id, _role_tag(), msg])

func _can_pick_any_skill() -> bool:
	for s in SkillsManager.selected_skills:
		if SkillsManager.can_pick_skill(s): return true
	return false

# ─────────────────────────────────────────────
# Phase management
# ─────────────────────────────────────────────

func start_skill_phase(announce_phase: bool = false) -> void:
	current_state = GameState.SKILL_SELECT
	_host_skill_phase_requested  = false
	_host_typing_phase_requested = false
	_server_typing_started_at_ms = 0.0
	_server_first_finish_at_ms   = 0.0
	_server_first_finish_by      = ""
	skill_timer    = 10.0
	chosen_skill_id    = ""
	chosen_skill_index = -1
	i_finished     = false
	enemy_finished = false
	snap_active    = false
	snap_timer     = 10.0
	round_timer    = 60.0
	_last_snap_fallback_log_ms = 0
	_snap_trace_active = false
	_snap_trace_last_s = -1
	_snap_trace_line   = ""
	net.opp_chosen_skill = ""
	_update_skill_buttons()
	_log("[Phase] SKILL SELECT | mana=%d | skills=%s" % [SkillsManager.player_mana, str(SkillsManager.selected_skills)])
	if _can_pick_any_skill():
		skill_select.show()
	else:
		skill_select.hide()
	countdown_label.show()
	typing_label.hide()
	if stats_label:     stats_label.hide()
	if opp_stats_label: opp_stats_label.hide()
	if announce_phase and not GameManager.is_solo and GameManager.current_room != "" and GameManager.is_host:
		_host_skill_phase_requested = true
		var next_round = max(1, _last_resolved_round_id) + 1
		net.set_phase("skill_select", next_round)

func start_typing_phase(announce_phase: bool = false) -> void:
	current_state = GameState.TYPING
	skill_select.hide()
	if accuracy_warning: accuracy_warning.hide()
	_host_typing_phase_requested = announce_phase and GameManager.is_host
	_local_first_finish_at_ms = 0.0
	_local_first_finish_by   = ""
	net.reset_mutation_index()
	_last_opp_words = 0
	if GameManager.is_solo or GameManager.current_room == "":
		current_round += 1
	else:
		current_round = _server_round_id if _server_round_id > 0 else max(1, current_round)
	typing.pick_sentence(GameManager.current_room, current_round)
	typing_label.show()
	countdown_label.show()
	if stats_label:     stats_label.show()
	if opp_stats_label: opp_stats_label.show()
	typing.queued_mutations.clear()
	if SkillsManager.selected_passive == "stutter" and SkillsManager.opponent_win_streak > 0:
		typing.queued_mutations.append({ "type": "stutter" })
	if SkillsManager.selected_passive == "phantom" and SkillsManager.phantom_stack > 0:
		for i in range(SkillsManager.phantom_stack):
			typing.queued_mutations.append({ "type": "phantom" })
	_log("[Round] Starting TYPING Phase | target_len=%d | round_id=%d" % [typing.target_sentence.length(), _server_round_id])
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
		net.set_phase("typing", max(1, _server_round_id))

func _update_skill_buttons() -> void:
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

# 
# Main process loop
# 

func _process(delta: float) -> void:
	if not _initialized: return
	# Always poll regardless of state so guest can exit RESOLVING
	if not GameManager.is_solo and GameManager.current_room != "":
		net.poll(current_state == GameState.SKILL_SELECT)
	match current_state:
		GameState.SKILL_SELECT: _process_skill_select(delta)
		GameState.TYPING:       _process_typing(delta)

func _process_skill_select(delta: float) -> void:
	if not GameManager.is_solo and GameManager.current_room != "":
		if _server_phase == "typing" and _server_round_id > _last_resolved_round_id and _server_round_id > current_round:
			_log("[Net] Catching up to typing phase | round_id=%d" % _server_round_id)
			start_typing_phase(false)
			return
		if _server_phase == "skill_select" and _server_phase_started_at_ms > 0.0:
			var elapsed = (_get_synced_ms() - _server_phase_started_at_ms) / 1000.0
			skill_timer = max(0.0, 10.0 - elapsed)
		else:
			skill_timer -= delta
	else:
		skill_timer -= delta
	if countdown_label:
		countdown_label.text = "Choose Skill: %d" % max(0, int(ceil(skill_timer)))
	if skill_timer <= 0:
		if not GameManager.is_solo and GameManager.current_room != "":
			if GameManager.is_host and _server_phase == "skill_select" and not _host_typing_phase_requested:
				_host_typing_phase_requested = true
				net.set_phase("typing", max(1, _server_round_id))
		else:
			start_typing_phase()
	else:
		if GameManager.is_solo or GameManager.current_room == "":
			if not _can_pick_any_skill() and chosen_skill_id == "":
				start_typing_phase()
		elif GameManager.is_host and _server_phase == "skill_select" and not _host_typing_phase_requested:
			if _should_host_fast_forward():
				_log("[Phase] Fast-forward: neither player can cast")
				_host_typing_phase_requested = true
				net.set_phase("typing", max(1, _server_round_id))

func _process_typing(delta: float) -> void:
	# Ready countdown
	if not GameManager.is_solo and GameManager.current_room != "" and _server_phase == "typing" and _server_typing_started_at_ms > 0.0:
		if _get_synced_ms() < _server_typing_started_at_ms:
			var sec_left = int(ceil((_server_typing_started_at_ms - _get_synced_ms()) / 1000.0))
			if countdown_label: countdown_label.text = "Get Ready: %d" % max(0, sec_left)
			return
	elif (GameManager.is_solo or GameManager.current_room == "") and _typing_go_at_ms > 0.0:
		if float(Time.get_ticks_msec()) < _typing_go_at_ms:
			var sec_left = int(ceil((_typing_go_at_ms - float(Time.get_ticks_msec())) / 1000.0))
			if countdown_label: countdown_label.text = "Get Ready: %d" % max(0, sec_left)
			return
	# Timers
	if not GameManager.is_solo and GameManager.current_room != "" and _server_phase == "typing" and _server_typing_started_at_ms > 0.0:
		var now_ms = _get_synced_ms()
		var deadline = _server_typing_started_at_ms + 60000.0
		round_timer = max(0.0, (deadline - now_ms) / 1000.0)
		var eff_finish = _server_first_finish_at_ms if _server_first_finish_at_ms > 0 else _local_first_finish_at_ms
		if eff_finish > 0.0:
			var snap_deadline = min(deadline, eff_finish + 10000.0)
			snap_timer = max(0.0, (snap_deadline - now_ms) / 1000.0)
			snap_active = true
			var finish_by = _server_first_finish_by if _server_first_finish_by != "" else _local_first_finish_by
			var am_first = (finish_by == "host" and GameManager.is_host) or (finish_by == "guest" and not GameManager.is_host)
			if not am_first: enemy_finished = true
		elif snap_active:
			snap_timer = min(snap_timer, round_timer)
			snap_timer = max(0.0, snap_timer - delta)
	else:
		if snap_active: snap_timer -= delta
		else:           round_timer -= delta
	# Snap resolution
	if snap_active:
		var s_left = int(ceil(snap_timer))
		if not _snap_trace_active:
			_snap_trace_active = true; _snap_trace_last_s = s_left
			_snap_trace_line = ""; _snap_trace_start_s = s_left
		if s_left != _snap_trace_last_s:
			_snap_trace_last_s = s_left
			_snap_trace_line += "%d.." % max(0, _snap_trace_start_s - s_left)
			_log("[SnapTrace] " + _snap_trace_line)
		if countdown_label:
			countdown_label.text = (" You: %d" if (enemy_finished and not i_finished) else " Opp: %d") % max(0, int(ceil(snap_timer)))
		if i_finished and enemy_finished:
			snap_active = false
			if countdown_label: countdown_label.hide()
			_resolve_and_advance("buff"); return
		if snap_timer <= 0.0:
			_resolve_and_advance("dnf" if (enemy_finished and not i_finished) else "full_power"); return
	else:
		_snap_trace_active = false; _snap_trace_last_s = -1
		if countdown_label: countdown_label.text = "%d" % max(0, int(ceil(round_timer)))
		if round_timer <= 0.0:
			_resolve_and_advance("no_attack"); return
	# Stats HUD
	_update_stats_hud()
	# Progress bars
	own_progress_bar.max_value = 1.0
	own_progress_bar.value     = typing.get_progress()
	enemy_progress_bar.max_value = 1.0
	enemy_progress_bar.value     = net.opp_progress
	# HP / Mana bars
	if hp_bar_own:   hp_bar_own.max_value   = HPManager.player_max_hp;   hp_bar_own.value   = HPManager.player_hp
	if hp_bar_opp:   hp_bar_opp.max_value   = HPManager.opponent_max_hp; hp_bar_opp.value   = HPManager.opponent_hp
	if mana_bar_own: mana_bar_own.max_value  = 10; mana_bar_own.value  = SkillsManager.player_mana
	if mana_bar_opp: mana_bar_opp.max_value  = 10; mana_bar_opp.value  = SkillsManager.opponent_mana
	# Progress sync  pass the mutation queue so NetworkSync pops only when actually sending
	net.sync_progress_with_queue(typing.current_index, typing.target_sentence.length(),
		typing.typos_count, chosen_skill_id, typing.queued_mutations,
		accuracy_warning != null and accuracy_warning.visible)

func _update_stats_hud() -> void:
	if stats_label:
		var opp_skill_text = ""
		if not GameManager.is_solo and net.opp_chosen_skill != "":
			opp_skill_text = " | Skill: %s" % net.opp_chosen_skill.capitalize()
		stats_label.text = "WPM: %d | Typos: %d | Acc: %.1f%%%s" % [typing.get_wpm(), typing.typos_count, typing.get_accuracy(), opp_skill_text]
	if opp_stats_label:
		var opp_prog = net.opp_progress
		var opp_words = opp_prog * (float(typing.target_sentence.length()) / 5.0)
		# Use server typing start so opponent WPM updates even if we haven't typed yet.
		var elapsed_min := 0.0
		if not GameManager.is_solo and GameManager.current_room != "" and _server_typing_started_at_ms > 0.0:
			var now_ms := _get_synced_ms()
			if now_ms > _server_typing_started_at_ms:
				elapsed_min = (now_ms - _server_typing_started_at_ms) / 60000.0
		elif typing.sentence_start_time > 0.0:
			elapsed_min = (Time.get_ticks_msec() - typing.sentence_start_time) / 60000.0
		var opp_wpm = int(opp_words / elapsed_min) if elapsed_min > 0 else 0
		var opp_total = opp_prog * float(typing.target_sentence.length())
		var opp_acc = clampf(((opp_total - float(net.opp_typos)) / opp_total) * 100.0, 0.0, 100.0) if opp_total > 0 else 100.0
		var opp_skill2 = (" | Skill: %s" % net.opp_chosen_skill.capitalize()) if (not GameManager.is_solo and net.opp_chosen_skill != "") else ""
		opp_stats_label.text = "WPM: %d | Typos: %d | Acc: %.1f%%%s" % [opp_wpm, net.opp_typos, opp_acc, opp_skill2]

# 
# Input
# 

func _unhandled_input(event: InputEvent) -> void:
	if not _initialized: return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_toggle_pause_panel(); return
			
		# ──────── TEMPORARY DEBUG KEYS ────────
		if event.keycode == KEY_F1:
			anim.play_combat_anims("quickslash", 10.0)
			return
		elif event.keycode == KEY_F2:
			anim.play_combat_anims("soulbreak", 10.0)
			return
		elif event.keycode == KEY_F3:
			anim.play_combat_anims("whiplash", 10.0)
			return
		# ──────────────────────────────────────

	if current_state != GameState.TYPING: return
	if not GameManager.is_solo and GameManager.current_room != "" and _server_phase == "typing" and _server_typing_started_at_ms > 0.0:
		if _get_synced_ms() < _server_typing_started_at_ms: return
	elif (GameManager.is_solo or GameManager.current_room == "") and _typing_go_at_ms > 0.0:
		if float(Time.get_ticks_msec()) < _typing_go_at_ms: return
	if event is InputEventKey and event.pressed:
		typing.handle_key(event, true)

# 
# Signal handlers
# 

func _on_word_completed_accurately(_wpm: float) -> void:
	pass

func _on_sentence_finished() -> void:
	_on_i_finished()

func _on_room_polled(room: Dictionary) -> void:
	_server_phase               = net.server_phase
	_server_phase_started_at_ms = net.server_phase_started_at_ms
	_server_typing_started_at_ms = net.server_typing_started_at_ms
	_server_first_finish_at_ms  = net.server_first_finish_at_ms
	_server_first_finish_by     = net.server_first_finish_by
	_server_round_id            = net.server_round_id
	if _server_phase == "typing" and _server_typing_started_at_ms > 0.0:
		_typing_go_at_ms = _server_typing_started_at_ms
	net.apply_hp_from_room(room)
	# Phase transitions
	if _server_phase == "typing" and current_state == GameState.SKILL_SELECT and _server_round_id <= _last_resolved_round_id:
		return
	if _server_phase == "typing" and current_state == GameState.SKILL_SELECT:
		_log("[Net] Phase->typing (server) | round_id=%d" % _server_round_id)
		start_typing_phase(false)
	elif _server_phase == "skill_select" and current_state != GameState.SKILL_SELECT:
		# Host ignores its own skill_select announcement (it already called start_skill_phase)
		if not (GameManager.is_host and _host_skill_phase_requested):
			_log("[Net] Phase->skill_select (server) | round_id=%d" % _server_round_id)
			start_skill_phase(false)
	if current_state != GameState.TYPING: return
	# Opponent mana from word progress
	var total_words = float(typing.target_sentence.length()) / 5.0
	var cur_opp_words = int(floor(net.opp_progress * total_words))
	if cur_opp_words > _last_opp_words:
		for i in range(cur_opp_words - _last_opp_words):
			SkillsManager.on_opponent_accurate_word()
		_last_opp_words = cur_opp_words
	# Apply incoming mutations
	for mut in net.consume_new_mutations():
		typing.apply_mutation(mut)
		anim.show_passive_popup(mut.get("type", ""))
	# Enemy finished detection
	if not GameManager.is_solo and net.opp_progress >= 0.99 and not enemy_finished:
		enemy_finished = true
		if i_finished:
			_log("[Round] Enemy finished AFTER we finished")
		else:
			SkillsManager.on_opponent_finish_first()
			_log("[Round] Enemy finished first  snap started (+2 opp mana)")
			snap_active = true
	_opp_skills = net.opp_skills

func _on_opponent_forfeited() -> void:
	if _victory_shown: return
	_victory_shown = true
	GameManager.current_room = ""
	combat.show_opponent_forfeited_overlay($HUD)

func _on_entity_died(entity: String) -> void:
	if _victory_shown: return
	if current_state == GameState.TYPING or current_state == GameState.SKILL_SELECT or current_state == GameState.RESOLVING:
		_victory_shown = true
		current_state = GameState.RESOLVING
		combat.show_victory(entity, $HUD)

# ────────
# Round resolution
# 

func _on_i_finished() -> void:
	if i_finished: return
	i_finished = true
	typing_label.hide()
	if stats_label:     stats_label.hide()
	if opp_stats_label: opp_stats_label.hide()
	if enemy_finished:
		snap_active = false
		if countdown_label: countdown_label.hide()
		net.sync_progress_immediate(typing.current_index, typing.target_sentence.length(), typing.typos_count, chosen_skill_id)
		_log("[Round] We finished SECOND  DEBUFF")
		_resolve_and_advance("debuff")
	else:
		SkillsManager.on_finish_first()
		if SkillsManager.selected_passive == "reversal":
			typing.queued_mutations.append({ "type": "reversal" })
		if GameManager.is_solo:
			_resolve_and_advance("buff")
		else:
			snap_timer = min(10.0, round_timer)
			snap_active = true
			if _local_first_finish_at_ms <= 0.0:
				_local_first_finish_at_ms = _get_synced_ms()
				_local_first_finish_by = "host" if GameManager.is_host else "guest"
			net.sync_progress_immediate(typing.current_index, typing.target_sentence.length(), typing.typos_count, chosen_skill_id)
			_log("[Round] We finished FIRST  snap: %.1f s" % snap_timer)
			countdown_label.show()

func _resolve_and_advance(finish_mode: String) -> void:
	if current_state == GameState.RESOLVING: return
	current_state = GameState.RESOLVING
	_last_resolved_round_id = max(_last_resolved_round_id, _server_round_id)
	if countdown_label:  countdown_label.hide()
	if typing_label:     typing_label.hide()
	if stats_label:      stats_label.hide()
	if opp_stats_label:  opp_stats_label.hide()
	var result = combat.resolve(finish_mode, chosen_skill_id, net.opp_progress, _server_first_finish_at_ms, current_round)
	anim.play_combat_anims(
		chosen_skill_id, 
		result.player_damage, 
		net.opp_chosen_skill, 
		result.get("opp_player_damage", 0.0)
	)
	if not GameManager.is_solo and GameManager.current_room != "" and GameManager.is_host:
		net.sync_hp()
	await get_tree().create_timer(2.0).timeout
	if GameManager.is_solo:
		start_skill_phase()
	elif GameManager.is_host:
		start_skill_phase(true)
		net.last_poll_time = 0.0  # force immediate re-poll so both clients converge

# 
# Skill selection
# 

func _on_skill_pressed(skill_index: int) -> void:
	var idx = skill_index - 1
	if idx < SkillsManager.selected_skills.size():
		var skill = SkillsManager.selected_skills[idx]
		if SkillsManager.can_pick_skill(skill):
			chosen_skill_index = skill_index
			chosen_skill_id    = skill
			print("[Skill] Selected: %s (cost %d Mana)" % [skill, SkillsManager.SKILL_COSTS.get(skill, 0)])
			skill_select.hide()
			if not GameManager.is_solo and GameManager.current_room != "" and GameManager.is_host and _server_phase == "skill_select" and not _host_typing_phase_requested:
				if _should_host_fast_forward():
					_host_typing_phase_requested = true
					net.set_phase("typing", max(1, _server_round_id))
		else:
			print("[Skill] Not enough Mana for %s" % skill)

func _should_host_fast_forward() -> bool:
	if chosen_skill_id == "" and _can_pick_any_skill(): return false
	for s_id in _opp_skills:
		if SkillsManager.can_pick_skill(s_id, true): return false
	return true

# 
# Pause menu
# 

func _build_pause_panel() -> void:
	_pause_panel = Panel.new()
	_pause_panel.set_anchors_preset(Control.PRESET_CENTER)
	_pause_panel.custom_minimum_size = Vector2(320, 180)
	_pause_panel.visible = false
	_pause_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	$HUD.add_child(_pause_panel)
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 24; vbox.offset_top = 24
	vbox.offset_right = -24; vbox.offset_bottom = -24
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
	if is_instance_valid(_pause_panel): _pause_panel.visible = false
	if not GameManager.is_solo and GameManager.current_room != "":
		net.delete_room()
		GameManager.current_room = ""
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")

# ─────────────────────────────────────────────
# Utilities
# ─────────────────────────────────────────────

func _get_synced_ms() -> float:
	return Time.get_unix_time_from_system() * 1000.0 + net.server_time_offset_ms

func _swap_controls(a: Control, b: Control) -> void:
	if a == null or b == null: return
	var al = a.anchor_left; var ar = a.anchor_right
	var aol = a.offset_left; var aor = a.offset_right
	a.anchor_left = b.anchor_left; a.anchor_right = b.anchor_right
	a.offset_left = b.offset_left; a.offset_right = b.offset_right
	b.anchor_left = al; b.anchor_right = ar
	b.offset_left = aol; b.offset_right = aor

## DEPRECATED  kept as a compatibility stub
func _on_sentence_completed():
	_on_i_finished()
		
