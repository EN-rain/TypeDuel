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
var _skill_phase_local_start_ms: float  = 0.0  # local time when skill phase began
var _typing_go_at_ms: float             = 0.0
var _local_first_finish_at_ms: float    = 0.0
var _local_first_finish_by: String      = ""
var _host_typing_phase_requested: bool  = false
var _host_skill_phase_requested: bool   = false
var _opp_skills: Array                  = []
@onready var typing_label       = $HUD/TypingText
@onready var skill_select       = $HUD/OwnSkillSelect
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
	SoundManager.play_music(preload("res://assets/bg-music/fight_looped.wav"))
	_build_pause_panel()
	call_deferred("_deferred_init")

func _deferred_init() -> void:
	HPManager.init_game()
	_update_bars()
	_log("[Init] Game scene loaded | char=%s | opp=%s | room=%s | role=%s" % [
		GameManager.selected_character, GameManager.opponent_character,
		GameManager.current_room, _role_tag()])
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
	typing.accuracy_too_low.connect(_on_accuracy_too_low)
	net.room_polled.connect(_on_room_polled)
	net.opponent_forfeited.connect(_on_opponent_forfeited)
	if net.has_signal("you_forfeited"):
		net.you_forfeited.connect(_on_you_forfeited)
	if net.has_signal("match_ended"):
		net.match_ended.connect(_on_match_ended)
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
	# Disable percentage display on all bars — values are raw numbers, not percentages.
	if hp_bar_own:   hp_bar_own.show_percentage   = false
	if hp_bar_opp:   hp_bar_opp.show_percentage   = false
	if mana_bar_own: mana_bar_own.show_percentage = false
	if mana_bar_opp: mana_bar_opp.show_percentage = false
	if has_node("HUD/OwnSkillSelect/HBoxContainer/Skill1"):
		$HUD/OwnSkillSelect/HBoxContainer/Skill1.pressed.connect(_on_skill_pressed.bind(1))
	if has_node("HUD/OwnSkillSelect/HBoxContainer/Skill2"):
		$HUD/OwnSkillSelect/HBoxContainer/Skill2.pressed.connect(_on_skill_pressed.bind(2))
	_update_skill_icons()
	typing.load_sentences()
	# Delay the first skill phase announcement to let both clients load the scene
	if not GameManager.is_solo and GameManager.current_room != "" and GameManager.is_host:
		await get_tree().create_timer(0.5).timeout
	start_skill_phase(true if (not GameManager.is_solo and GameManager.current_room != "" and GameManager.is_host) else false)
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
	_victory_shown = false  # Reset for new round (edge case protection)
	skill_timer    = 10.0
	chosen_skill_id    = ""
	chosen_skill_index = -1
	i_finished     = false
	enemy_finished = false
	snap_active    = false
	snap_timer     = 10.0
	round_timer    = 60.0
	net.opp_chosen_skill = ""  # Clear opponent's skill choice from previous round
	_skill_phase_local_start_ms = float(Time.get_ticks_msec())
	
	# Use server round_id if available, otherwise increment local counter
	if not GameManager.is_solo and GameManager.current_room != "" and _server_round_id > 0:
		current_round = _server_round_id
	elif GameManager.is_solo or GameManager.current_room == "":
		# Solo mode: increment locally
		pass
	
	_log("[Phase] SKILL SELECT | round=%d | mana=%d | opp_mana=%d | skills=%s" % [current_round, SkillsManager.player_mana, SkillsManager.opponent_mana, str(SkillsManager.selected_skills)])
	
	# Update skill buttons based on current mana — do NOT unconditionally re-enable them.
	# _update_skill_buttons() already handles enable/disable based on affordability.
	_update_skill_buttons()
	
	# Always show skill buttons — disabled state communicates affordability, not visibility
	skill_select.show()
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
	net.opp_mana = -1  # Reset to -1 until server syncs first value
	if GameManager.is_solo or GameManager.current_room == "":
		current_round += 1
	else:
		current_round = _server_round_id if _server_round_id > 0 else max(1, current_round)
	typing.pick_sentence(GameManager.current_room, current_round)
	# Hide typing label initially — it fades in after a 1s delay.
	typing_label.modulate.a = 0.0
	typing_label.show()
	countdown_label.hide()
	if stats_label:     stats_label.show()
	if opp_stats_label: opp_stats_label.show()
	typing.queued_mutations.clear()
	SkillsManager.reset_round_word_counts()  # Reset per-round mana gain counters
	if SkillsManager.selected_passive == "stutter" and SkillsManager.opponent_win_streak > 0:
		typing.queued_mutations.append({ "type": "stutter" })
		_log("[Passive] Stutter queued (opp win streak=%d)" % SkillsManager.opponent_win_streak)
	if SkillsManager.selected_passive == "phantom" and SkillsManager.phantom_stack > 0:
		for i in range(SkillsManager.phantom_stack):
			typing.queued_mutations.append({ "type": "phantom" })
		_log("[Passive] Phantom queued x%d (stack=%d)" % [SkillsManager.phantom_stack, SkillsManager.phantom_stack])
		SkillsManager.phantom_stack = 0  # Consume the stack after queuing
	_log("[Round] Starting TYPING Phase | target_len=%d | round_id=%d" % [typing.target_sentence.length(), _server_round_id])
	if not GameManager.is_solo and GameManager.current_room != "" and _server_typing_started_at_ms > 0.0:
		_typing_go_at_ms = _server_typing_started_at_ms
	else:
		# No in-game countdown — the lobby handles the "Get Ready" before scene transition.
		_typing_go_at_ms = float(Time.get_ticks_msec())
	if announce_phase and not GameManager.is_solo and GameManager.current_room != "" and GameManager.is_host:
		_host_typing_phase_requested = true
		net.set_phase("typing", max(1, _server_round_id))
	# Fade in the typing label after 1s — timer starts when fade completes.
	_fade_in_typing_label()

func _update_skill_buttons() -> void:
	if SkillsManager.selected_skills.size() > 0:
		var s1 = SkillsManager.selected_skills[0]
		if has_node("HUD/OwnSkillSelect/HBoxContainer/Skill1"):
			var btn1 = $HUD/OwnSkillSelect/HBoxContainer/Skill1
			var new_text = "%s (%dM)" % [s1.capitalize(), SkillsManager.SKILL_COSTS.get(s1, 0)]
			if btn1.text != new_text: btn1.text = new_text
			var should_disable = not SkillsManager.can_pick_skill(s1) or chosen_skill_id != ""
			if btn1.disabled != should_disable:
				btn1.disabled = should_disable
				# Smooth visual feedback: fade opacity instead of hard enable/disable flash
				var tween = create_tween()
				tween.tween_property(btn1, "modulate:a", 0.4 if should_disable else 1.0, 0.15)
				_log("[SkillBtn] Skill1 '%s' disabled=%s | mana=%d cost=%d chosen='%s'" % [
					s1, should_disable, SkillsManager.player_mana,
					SkillsManager.SKILL_COSTS.get(s1, 0), chosen_skill_id])
	if SkillsManager.selected_skills.size() > 1:
		var s2 = SkillsManager.selected_skills[1]
		if has_node("HUD/OwnSkillSelect/HBoxContainer/Skill2"):
			var btn2 = $HUD/OwnSkillSelect/HBoxContainer/Skill2
			var new_text = "%s (%dM)" % [s2.capitalize(), SkillsManager.SKILL_COSTS.get(s2, 0)]
			if btn2.text != new_text: btn2.text = new_text
			var should_disable = not SkillsManager.can_pick_skill(s2) or chosen_skill_id != ""
			if btn2.disabled != should_disable:
				btn2.disabled = should_disable
				var tween = create_tween()
				tween.tween_property(btn2, "modulate:a", 0.4 if should_disable else 1.0, 0.15)
				_log("[SkillBtn] Skill2 '%s' disabled=%s | mana=%d cost=%d chosen='%s'" % [
					s2, should_disable, SkillsManager.player_mana,
					SkillsManager.SKILL_COSTS.get(s2, 0), chosen_skill_id])

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
		if _server_phase == "skill_select" and _server_phase_started_at_ms > 0.0 and current_round > 1:
			# Round 2+: use server time so both clients stay in sync
			var elapsed = (_get_synced_ms() - _server_phase_started_at_ms) / 1000.0
			skill_timer = max(0.0, 10.0 - elapsed)
		else:
			# Round 1: count down locally — server phase was announced during lobby
			# countdown so elapsed would already be 3-4s, making timer start at 6-7s
			skill_timer -= delta
	else:
		skill_timer -= delta
	if countdown_label:
		_set_countdown("Choose Skill: %d" % max(0, int(ceil(skill_timer))))
	if skill_timer <= 0:
		if not GameManager.is_solo and GameManager.current_room != "":
			# Host drives the typing phase transition on timer expiry.
			# No _server_phase guard here — the host is authoritative and must not stall
			# if the server already echoed "typing" back before the timer hit zero.
			if GameManager.is_host and not _host_typing_phase_requested:
				_host_typing_phase_requested = true
				net.set_phase("typing", max(1, _server_round_id))
		else:
			start_typing_phase()
	else:
		if GameManager.is_solo or GameManager.current_room == "":
			pass  # Solo: wait for timer — buttons stay visible even if unaffordable
		else:
			# Fast-forward: host can advance as soon as both players are done picking,
			# regardless of _server_phase — the host is the authority on phase transitions.
			# We only block if we already requested the typing phase this round.
			var host_can_fast_forward = GameManager.is_host and not _host_typing_phase_requested
			if host_can_fast_forward and _should_host_fast_forward():
				# Message already logged in _should_host_fast_forward()
				_host_typing_phase_requested = true
				net.set_phase("typing", max(1, _server_round_id))
	
	# Update skill button states every frame to reflect current mana
	_update_skill_buttons()
	_update_bars()

func _process_typing(delta: float) -> void:
	# Input is blocked until _typing_go_at_ms (handled in _unhandled_input).
	# The timer still ticks — we just suppress the countdown label during the fade-in window.
	var in_fade_window: bool = false
	if not GameManager.is_solo and GameManager.current_room != "" and _server_phase == "typing" and _server_typing_started_at_ms > 0.0:
		if _get_synced_ms() < _server_typing_started_at_ms:
			in_fade_window = true
	elif (GameManager.is_solo or GameManager.current_room == "") and _typing_go_at_ms > 0.0:
		if float(Time.get_ticks_msec()) < _typing_go_at_ms:
			in_fade_window = true
	# Timers — don't tick during the fade-in window so the 60s is fair.
	if not in_fade_window:
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
		if countdown_label:
			_set_countdown((" You: %d" if (enemy_finished and not i_finished) else " Opp: %d") % max(0, int(ceil(snap_timer))))
		if i_finished and enemy_finished:
			snap_active = false
			if countdown_label: countdown_label.hide(); _last_countdown_text = ""
			_log("[Decision] ✓ Both finished within 10s → BUFF mode")
			_resolve_and_advance("buff"); return
		if snap_timer <= 0.0:
			if enemy_finished and not i_finished:
				# Double-check: if server says WE finished first, don't DNF ourselves
				var i_finished_server = (_server_first_finish_by == "host" and GameManager.is_host) or \
										(_server_first_finish_by == "guest" and not GameManager.is_host)
				if i_finished_server:
					_log("[Decision] ✓ Server confirms we finished first → FULL_POWER mode (not DNF)")
					_resolve_and_advance("full_power")
				else:
					_log("[Decision] ✗ We DNF (opponent finished, we didn't) → DNF mode")
					_resolve_and_advance("dnf")
			else:
				# Check server confirmation before declaring FULL_POWER.
				# If server says opponent finished, treat as BUFF (both finished).
				var opp_finished_server = (_server_first_finish_by == "host" and not GameManager.is_host) or \
										  (_server_first_finish_by == "guest" and GameManager.is_host)
				if opp_finished_server:
					_log("[Decision] ✓ Server confirms opponent finished → BUFF mode (not FULL_POWER)")
					enemy_finished = true
					snap_active = false
					if countdown_label: countdown_label.hide(); _last_countdown_text = ""
					_resolve_and_advance("buff")
				else:
					_log("[Decision] ✓ Opponent DNF (we finished, they didn't) → FULL_POWER mode")
					_resolve_and_advance("full_power")
			return
	else:
		if countdown_label: _set_countdown("%d" % max(0, int(ceil(round_timer))))
		if round_timer <= 0.0:
			_log("[Decision] ✗ 60s timer expired, neither finished → NO_ATTACK mode (-5 HP both)")
			_resolve_and_advance("no_attack"); return
	# Stats HUD
	_update_stats_hud()
	# Progress bars
	own_progress_bar.max_value = 1.0
	var own_prog = typing.get_progress()
	# Clamp progress to 98% if accuracy warning is visible (matches server sync)
	if accuracy_warning != null and accuracy_warning.visible:
		own_prog = minf(own_prog, 0.98)
	own_progress_bar.value = own_prog
	enemy_progress_bar.max_value = 1.0
	enemy_progress_bar.value     = net.opp_progress
	# HP / Mana bars
	_update_bars()
	net.sync_progress_with_queue(typing.current_index, typing.target_sentence.length(),
		typing.typos_count, chosen_skill_id, typing.queued_mutations,
		accuracy_warning != null and accuracy_warning.visible)

var _last_countdown_text: String = ""
var _last_stats_text: String = ""
var _last_opp_stats_text: String = ""

func _set_countdown(text: String) -> void:
	if countdown_label and _last_countdown_text != text:
		_last_countdown_text = text
		countdown_label.text = text

func _update_bars() -> void:
	if hp_bar_own:
		hp_bar_own.max_value = HPManager.player_max_hp
		hp_bar_own.value     = HPManager.player_hp
		var lbl = hp_bar_own.get_node_or_null("OwnHpLabel")
		if lbl: lbl.text = "%d" % int(HPManager.player_hp)
	if hp_bar_opp:
		hp_bar_opp.max_value = HPManager.opponent_max_hp
		hp_bar_opp.value     = HPManager.opponent_hp
		var lbl = hp_bar_opp.get_node_or_null("EnemyHpLabel")
		if lbl: lbl.text = "%d" % int(HPManager.opponent_hp)
	if mana_bar_own:
		mana_bar_own.max_value = 10
		mana_bar_own.value     = SkillsManager.player_mana
		var lbl = mana_bar_own.get_node_or_null("OwnManaLabel")
		if lbl: lbl.text = "%d" % SkillsManager.player_mana
	if mana_bar_opp:
		mana_bar_opp.max_value = 10
		mana_bar_opp.value     = SkillsManager.opponent_mana
		var lbl = mana_bar_opp.get_node_or_null("EnemyManaLabel")
		if lbl: lbl.text = "%d" % SkillsManager.opponent_mana

func _update_stats_hud() -> void:
	if stats_label:
		var t = "WPM: %d | Typos: %d | Acc: %.1f%%" % [typing.get_wpm(), typing.typos_count, typing.get_accuracy()]
		if t != _last_stats_text:
			_last_stats_text = t
			stats_label.text = t
	if opp_stats_label:
		var opp_prog = net.opp_progress
		var sentence_len = float(typing.target_sentence.length())
		var opp_chars = opp_prog * sentence_len
		var opp_words = opp_chars / 5.0
		
		# Calculate opponent WPM
		var opp_wpm := 0
		if opp_prog >= 0.999:
			# Opponent finished - use their finish time to lock WPM
			if _server_first_finish_at_ms > 0.0 and _server_typing_started_at_ms > 0.0:
				var finish_elapsed_min = (_server_first_finish_at_ms - _server_typing_started_at_ms) / 60000.0
				opp_wpm = int(opp_words / finish_elapsed_min) if finish_elapsed_min > 0 else 0
		else:
			# Opponent still typing - calculate real-time WPM
			var elapsed_min := 0.0
			if not GameManager.is_solo and GameManager.current_room != "" and _server_typing_started_at_ms > 0.0:
				var now_ms := _get_synced_ms()
				if now_ms > _server_typing_started_at_ms:
					elapsed_min = (now_ms - _server_typing_started_at_ms) / 60000.0
			opp_wpm = int(opp_words / elapsed_min) if elapsed_min > 0 else 0
		
		var opp_total = opp_chars + float(net.opp_typos)
		var opp_acc = clampf((opp_chars / opp_total) * 100.0, 0.0, 100.0) if opp_total > 0 else 100.0
		var t2 = "WPM: %d | Typos: %d | Acc: %.1f%%" % [opp_wpm, net.opp_typos, opp_acc]
		if t2 != _last_opp_stats_text:
			_last_opp_stats_text = t2
			opp_stats_label.text = t2

# 
# Input
# 

func _unhandled_input(event: InputEvent) -> void:
	if not _initialized: return
	if event is InputEventKey and event.pressed:
		# ──────── DEBUG KEYS ────────
		if event.keycode == KEY_F4:
			if current_state == GameState.TYPING and not i_finished:
				print("[Debug] F4: Skipping sentence")
				typing.force_complete_sentence()
			return
		# ────────────────────────────

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_toggle_pause_panel(); return

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

func _on_accuracy_too_low() -> void:
	# Player finished but didn't meet the 60% accuracy threshold.
	# Skill is cancelled — mana is NOT refunded (mana is only gained from words).
	# This is the authoritative check; _resolve_and_advance will also verify.
	_log("[Accuracy] Warning: below 60%% threshold | acc=%.1f%%" % typing.get_accuracy())
	if chosen_skill_id != "":
		_log("[Accuracy] Skill '%s' cancelled, mana lost" % chosen_skill_id)
		chosen_skill_id = ""
		chosen_skill_index = -1

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
	# Opponent mana: sync from server regardless of phase so fast-forward
	# can detect when opponent has spent their mana during skill_select
	if net.opp_mana >= 0 and SkillsManager.opponent_mana != net.opp_mana:
		_log("[ManaSync] Updating opponent mana from server: %d → %d" % [SkillsManager.opponent_mana, net.opp_mana])
		SkillsManager.opponent_mana = net.opp_mana
	# Phase transitions
	if _server_phase == "typing" and current_state == GameState.SKILL_SELECT and _server_round_id <= _last_resolved_round_id:
		return
	if _server_phase == "typing" and current_state == GameState.SKILL_SELECT:
		_log("[Net] Phase->typing (server) | round_id=%d" % _server_round_id)
		start_typing_phase(false)
	elif _server_phase == "skill_select" and current_state != GameState.SKILL_SELECT:
		# Clear opponent's skill choice from previous round when entering new skill phase
		net.opp_chosen_skill = ""
		# Only transition to skill_select if this is a new round we haven't resolved yet.
		# Prevents spurious hide/show of stats labels when a stale poll arrives mid-transition.
		if _server_round_id > _last_resolved_round_id:
			# Host ignores its own skill_select announcement (it already called start_skill_phase)
			if not (GameManager.is_host and _host_skill_phase_requested):
				_log("[Net] Phase->skill_select (server) | round_id=%d" % _server_round_id)
				start_skill_phase(false)
		# Guest in RESOLVING state should also transition when host announces new round
		elif current_state == GameState.RESOLVING and _server_round_id == _last_resolved_round_id + 1:
			_log("[Net] Phase->skill_select (server, from RESOLVING) | round_id=%d" % _server_round_id)
			start_skill_phase(false)
	if current_state != GameState.TYPING: return
	# Apply incoming mutations
	for mut in net.consume_new_mutations():
		typing.apply_mutation(mut)
		anim.show_passive_popup(mut.get("type", ""))
	# Enemy finished detection - check both progress threshold and server confirmation
	var opp_finished_by_progress = net.opp_progress >= 0.99
	var opp_finished_by_server = (_server_first_finish_by == "host" and not GameManager.is_host) or \
								  (_server_first_finish_by == "guest" and GameManager.is_host)
	
	if not GameManager.is_solo and (opp_finished_by_progress or opp_finished_by_server) and not enemy_finished:
		enemy_finished = true
		if i_finished:
			_log("[Round] Enemy finished AFTER we finished")
		else:
			# Don't add +2 locally — the opponent already added it and synced to server.
			# The server value will arrive via the next poll and update opponent_mana correctly.
			_log("[Decision] ✓ Opponent finished FIRST (mana synced from server)")
			snap_active = true
	_opp_skills = net.opp_skills

func _on_opponent_forfeited() -> void:
	if _victory_shown: return
	_log("[Victory] Opponent forfeited — we win")
	_victory_shown = true
	GameManager.current_room = ""
	
	# Save match history as a win by forfeit
	_save_forfeit_victory()
	
	combat.show_opponent_forfeited_overlay($HUD)

func _on_you_forfeited() -> void:
	if _victory_shown: return
	_victory_shown = true
	GameManager.current_room = ""
	
	# Save match history as a loss by forfeit
	_save_forfeit_loss()
	
	# Apply penalty for forfeiting
	_apply_forfeit_penalty()
	
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")

func _on_match_ended(_reason: String) -> void:
	if _victory_shown: return
	_victory_shown = true
	GameManager.current_room = ""
	combat.show_match_ended_overlay($HUD, _reason)

var _pending_death_entity: String = ""  # set when entity dies during combat resolution

func _on_entity_died(entity: String) -> void:
	if _victory_shown: return
	if current_state == GameState.RESOLVING:
		# Don't interrupt combat animations — store and handle after they complete
		_log("[Victory] %s HP reached 0 — will show after animations" % entity)
		# If both die simultaneously, "player" death (we lose) takes priority for display
		if _pending_death_entity == "":
			_pending_death_entity = entity
		elif _pending_death_entity != entity:
			# Both died — treat as player loss (tie goes to opponent winning)
			_pending_death_entity = "player"
		return
	if current_state == GameState.TYPING or current_state == GameState.SKILL_SELECT:
		_log("[Victory] %s HP reached 0 — game over" % entity)
		_victory_shown = true
		current_state = GameState.RESOLVING
		combat.show_victory(entity, $HUD)

# ────────
# Round resolution
# 

func _on_i_finished() -> void:
	if i_finished: return
	i_finished = true
	typing_label.hide(); typing_label.modulate.a = 1.0
	# Keep stats labels visible after finishing so players can see their final WPM/accuracy
	
	var acc = typing.get_accuracy()
	var correct_letters = typing.total_keystrokes - typing.typos_count
	var required = int(ceil(float(typing.target_sentence.length()) * 0.6))
	_log("[Decision] Finished typing | Acc: %.1f%% | Correct: %d/%d (need %d)" % [acc, correct_letters, typing.total_keystrokes, required])
	
	if enemy_finished:
		snap_active = false
		if countdown_label: countdown_label.hide(); _last_countdown_text = ""
		net.sync_progress_immediate(typing.current_index, typing.target_sentence.length(), typing.typos_count, chosen_skill_id)
		_log("[Decision] ✓ Finished SECOND → DEBUFF mode")
		_resolve_and_advance("debuff")
	else:
		SkillsManager.on_finish_first()
		_log("[Decision] ✓ Finished FIRST → +2 Mana bonus (now %d)" % SkillsManager.player_mana)
		if SkillsManager.selected_passive == "reversal":
			typing.queued_mutations.append({ "type": "reversal" })
			_log("[Passive] Reversal queued (finished first)")
		if GameManager.is_solo:
			_resolve_and_advance("buff")
		else:
			snap_timer = min(10.0, round_timer)
			snap_active = true
			if _local_first_finish_at_ms <= 0.0:
				_local_first_finish_at_ms = _get_synced_ms()
				_local_first_finish_by = "host" if GameManager.is_host else "guest"
			net.sync_progress_immediate(typing.current_index, typing.target_sentence.length(), typing.typos_count, chosen_skill_id)
			_log("[Decision] Starting 10s SNAP timer, waiting for opponent...")
			countdown_label.show()

func _resolve_and_advance(finish_mode: String) -> void:
	if current_state == GameState.RESOLVING: return
	current_state = GameState.RESOLVING
	_last_resolved_round_id = max(_last_resolved_round_id, _server_round_id)
	if countdown_label:  countdown_label.hide(); _last_countdown_text = ""
	if typing_label:     typing_label.hide(); typing_label.modulate.a = 1.0
	# Keep stats labels visible during combat resolution so players can see their performance
	
	# Guard: clear skill if player didn't meet 60% accuracy requirement
	# This check applies to all finish modes where the player actually typed AND finished
	# Skip for DNF (didn't finish) since they have 0 progress
	if chosen_skill_id != "" and finish_mode != "no_attack" and finish_mode != "dnf":
		var correct_letters = typing.total_keystrokes - typing.typos_count
		var required = int(ceil(float(typing.target_sentence.length()) * 0.6))
		if correct_letters < required:
			_log("[Decision] ✗ Skill '%s' cancelled — accuracy too low (%d/%d correct, need %d) | Mana LOST" % 
				[chosen_skill_id, correct_letters, typing.total_keystrokes, required])
			chosen_skill_id = ""
		else:
			_log("[Decision] ✓ Skill '%s' validated — accuracy OK (%d/%d correct, need %d)" % 
				[chosen_skill_id, correct_letters, typing.total_keystrokes, required])
	
	var _result = combat.resolve(finish_mode, chosen_skill_id, net.opp_progress, _server_first_finish_at_ms, current_round)
	_update_bars()  # Reflect HP/mana changes from resolution immediately
	
	# Sync HP to server immediately after resolution so polling doesn't overwrite
	# correct local HP with stale server values during the animation window.
	if not GameManager.is_solo and GameManager.current_room != "" and GameManager.is_host:
		_log("[HP] Syncing to server — player=%.0f opp=%.0f" % [HPManager.player_hp, HPManager.opponent_hp])
		net.sync_hp()
	
	# Determine which skills should show in animation based on who finished
	var my_skill_for_anim = chosen_skill_id
	var opp_skill_for_anim = net.opp_chosen_skill
	
	if finish_mode == "full_power":
		# We finished, opponent didn't → hide opponent's skill
		_log("[Decision] Opponent DNF → opponent skill hidden in animation")
		opp_skill_for_anim = ""
	elif finish_mode == "dnf":
		# Opponent finished, we didn't → hide our skill
		_log("[Decision] We DNF → our skill hidden in animation")
		my_skill_for_anim = ""
	
	_log("[Combat] Resolving | Mode: %s | Our skill: %s | Opp skill: %s" % [finish_mode, my_skill_for_anim if my_skill_for_anim != "" else "none", opp_skill_for_anim if opp_skill_for_anim != "" else "none"])
	
	# Wait for combat animations to complete — with a safety timeout so victory
	# is never permanently blocked by a stuck animation sequence.
	await anim.play_combat_anims(my_skill_for_anim, opp_skill_for_anim, finish_mode)
	
	# Check if an entity died during combat resolution — show victory now
	if _pending_death_entity != "":
		var dead = _pending_death_entity
		_pending_death_entity = ""
		if not _victory_shown:
			_log("[Victory] Showing death result for %s after animations" % dead)
			_victory_shown = true
			combat.show_victory(dead, $HUD)
		return
	
	# Small delay before showing skill select UI
	await get_tree().create_timer(0.3).timeout
	
	if GameManager.is_solo:
		start_skill_phase()
	elif GameManager.is_host:
		start_skill_phase(true)
		net.last_poll_time = 0.0  # force immediate re-poll so both clients converge

# 
# Skill selection
# 

func _on_skill_pressed(skill_index: int) -> void:
	# Prevent multiple clicks - if a skill is already chosen, ignore
	if chosen_skill_id != "":
		return
	
	var idx = skill_index - 1
	if idx < SkillsManager.selected_skills.size():
		var skill = SkillsManager.selected_skills[idx]
		if SkillsManager.can_pick_skill(skill):
			chosen_skill_index = skill_index
			chosen_skill_id    = skill
			# Deduct mana immediately on pick so the bar reflects the cost
			var cost = SkillsManager.SKILL_COSTS.get(skill, 0)
			SkillsManager.player_mana = max(0, SkillsManager.player_mana - cost)
			_log("[Decision] ✓ Picked skill '%s' (cost %d) → mana now %d" % [skill, cost, SkillsManager.player_mana])
			
			# Immediately disable both buttons to prevent double-clicks
			if has_node("HUD/OwnSkillSelect/HBoxContainer/Skill1"):
				$HUD/OwnSkillSelect/HBoxContainer/Skill1.disabled = true
			if has_node("HUD/OwnSkillSelect/HBoxContainer/Skill2"):
				$HUD/OwnSkillSelect/HBoxContainer/Skill2.disabled = true
			# Sync skill choice immediately so opponent knows we picked
			if not GameManager.is_solo and GameManager.current_room != "":
				net.emit_skill_pick(chosen_skill_id)   # WebSocket fast path
				net.sync_progress_immediate(0, 1, 0, chosen_skill_id)  # HTTP persistence
				net.last_poll_time = 0.0
		else:
			_log("[Decision] ✗ Cannot afford skill '%s' (cost %d, have %d Mana)" % [skill, SkillsManager.SKILL_COSTS.get(skill, 0), SkillsManager.player_mana])

var _ff_last_log_time: float = 0.0

func _should_host_fast_forward() -> bool:
	# Only fast-forward if BOTH players have made their final choice (picked or can't pick)
	var i_am_done = chosen_skill_id != "" or not _can_pick_any_skill()
	if not i_am_done: return false

	# Opponent already synced their skill pick
	var opp_picked = net.opp_chosen_skill != ""
	if opp_picked:
		_log("[FastForward] ✓ Both players picked skills")
		return true

	# Wait a short moment before fallback fast-forward checks so late first polls can arrive.
	var elapsed_ms = float(Time.get_ticks_msec()) - _skill_phase_local_start_ms
	if elapsed_ms < 300.0: return false

	# If we don't know opponent's skills yet, wait
	if _opp_skills.is_empty():
		return false

	# Check if opponent CAN pick any of their skills based on their current mana
	var opp_can_pick = false
	for s_id in _opp_skills:
		if SkillsManager.can_pick_skill(s_id, true):
			opp_can_pick = true
			break

	if not opp_can_pick:
		_log("[FastForward] ✓ Opponent can't afford any skill — advancing")
		return true

	# Opponent has mana but hasn't picked yet — wait for them, BUT
	# if the skill timer is almost up (< 1s left), advance anyway so we don't stall
	if skill_timer <= 1.0:
		_log("[FastForward] ✓ Timer nearly expired, advancing regardless")
		return true

	# Throttle the waiting log to once per second to avoid spam
	var now = Time.get_ticks_msec() / 1000.0
	if now - _ff_last_log_time >= 1.0:
		_ff_last_log_time = now
		_log("[FastForward] ✗ Waiting for opponent to pick (opp_mana=%d)" % SkillsManager.opponent_mana)
	return false

func _update_skill_icons() -> void:
	if SkillsManager.selected_skills.size() > 0:
		var s1 = SkillsManager.selected_skills[0]
		if has_node("HUD/OwnSkillSelect/HBoxContainer/Skill1/TextureRect"):
			$HUD/OwnSkillSelect/HBoxContainer/Skill1/TextureRect.texture = SkillsManager.SKILL_ICONS.get(s1)
	if SkillsManager.selected_skills.size() > 1:
		var s2 = SkillsManager.selected_skills[1]
		if has_node("HUD/OwnSkillSelect/HBoxContainer/Skill2/TextureRect"):
			$HUD/OwnSkillSelect/HBoxContainer/Skill2/TextureRect.texture = SkillsManager.SKILL_ICONS.get(s2)
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
		# Save forfeit loss to history and apply penalty
		_save_forfeit_loss()
		_apply_forfeit_penalty()
		net.delete_room()
		GameManager.current_room = ""
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")

# ─────────────────────────────────────────────
# Utilities
# ─────────────────────────────────────────────

func _get_synced_ms() -> float:
	return Time.get_unix_time_from_system() * 1000.0 + net.server_time_offset_ms

func _fade_in_typing_label() -> void:
	# Block input during the 1s delay + 0.4s fade.
	var block_until = float(Time.get_ticks_msec()) + 1400.0
	if _typing_go_at_ms < block_until:
		_typing_go_at_ms = block_until
	await get_tree().create_timer(1.0).timeout
	if not is_instance_valid(typing_label): return
	var tween = create_tween()
	tween.tween_property(typing_label, "modulate:a", 1.0, 0.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	# Show the countdown label once the sentence is visible
	await tween.finished
	if countdown_label and current_state == GameState.TYPING:
		countdown_label.show()
		_last_countdown_text = ""  # force re-render

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

# ─────────────────────────────────────────────
#  Forfeit Penalty & History
# ─────────────────────────────────────────────

func _apply_forfeit_penalty() -> void:
	# Only apply penalty for matchmaking games
	if not GameManager.is_matchmaking: return
	if GameManager.user_data.id == 0: return
	
	# 60-second penalty for mid-match forfeit (6x lobby dodge penalty)
	var penalty_ms = 60000
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r,_c,_h,_b): http.queue_free())
	var body = JSON.stringify({
		"user_id": GameManager.user_data.id,
		"duration_ms": penalty_ms
	})
	http.request(GameManager.SERVER_URL + "/api/game/matchmaking-penalty", 
		GameManager.get_auth_headers(), HTTPClient.METHOD_POST, body)
	
	# Update local state so player sees the penalty immediately
	var now_unix_ms = Time.get_unix_time_from_system() * 1000.0
	GameManager.matchmaking_penalty_until_unix_ms = now_unix_ms + penalty_ms
	GameManager.auto_queue_matchmaking = false
	
	_log("[Penalty] Applied 60s matchmaking ban for forfeit")

func _save_forfeit_victory() -> void:
	if GameManager.user_data.id == 0: return
	var wpm = float(typing.get_wpm())
	var accuracy = typing.get_accuracy()
	wpm = clampf(wpm if is_finite(wpm) else 0.0, 0.0, 250.0)
	accuracy = clampf(accuracy if is_finite(accuracy) else 0.0, 0.0, 100.0)
	
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r,_c,_h,_b): http.queue_free())
	var data = {
		"user_id": GameManager.user_data.id,
		"username": GameManager.user_data.username,
		"match_type": "online" if GameManager.is_matchmaking else "custom",
		"wpm": wpm,
		"accuracy": accuracy,
		"typos": typing.typos_count,
		"won": true,
		"forfeit": "opponent"
	}
	http.request(GameManager.SERVER_URL + "/api/game/history", 
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST, JSON.stringify(data))
	
	_log("[History] Saved forfeit victory to match history")

func _save_forfeit_loss() -> void:
	if GameManager.user_data.id == 0: return
	var wpm = float(typing.get_wpm())
	var accuracy = typing.get_accuracy()
	wpm = clampf(wpm if is_finite(wpm) else 0.0, 0.0, 250.0)
	accuracy = clampf(accuracy if is_finite(accuracy) else 0.0, 0.0, 100.0)
	
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r,_c,_h,_b): http.queue_free())
	var data = {
		"user_id": GameManager.user_data.id,
		"username": GameManager.user_data.username,
		"match_type": "online" if GameManager.is_matchmaking else "custom",
		"wpm": wpm,
		"accuracy": accuracy,
		"typos": typing.typos_count,
		"won": false,
		"forfeit": "self"
	}
	http.request(GameManager.SERVER_URL + "/api/game/history", 
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST, JSON.stringify(data))
	
	_log("[History] Saved forfeit loss to match history")
