extends Node

## CombatResolver
## Owns round resolution: damage calculation, HP application, match history saving,
## and the victory/forfeit overlays.
## Attach to "CombatResolver" under the Game scene root.

signal match_ended

# Set by Game
var typing_handler  # ref to TypingHandler node
var network_sync    # ref to NetworkSync node
var anim_controller # ref to AnimationController node

# ─────────────────────────────────────────────
#  Round resolution
# ─────────────────────────────────────────────

func resolve(finish_mode: String, chosen_skill: String, enemy_typing_progress: float,
		server_first_finish_at_ms: float, _current_round: int) -> Dictionary:

	var sentence_length = typing_handler.target_sentence.length()
	var words: float = float(sentence_length) / 5.0

	# Use the locked final WPM if available (captured at the exact finish moment).
	# Fall back to calculating from elapsed time only if the sentence wasn't completed.
	var wpm: int
	if typing_handler._final_wpm >= 0:
		wpm = typing_handler._final_wpm
	else:
		var elapsed_ms: float = float(Time.get_ticks_msec() - typing_handler.sentence_start_time)
		var safe_elapsed_ms: float = max(250.0, elapsed_ms)
		var time_elapsed_min: float = safe_elapsed_ms / 60000.0
		wpm = clamp(int(words / time_elapsed_min) if time_elapsed_min > 0.0 else 0, 0, 250)

	var accuracy = typing_handler.get_accuracy()
	var typos    = typing_handler.typos_count

	var result = SkillsManager.resolve_round(
		float(wpm), accuracy, typos,
		network_sync.opp_typos,  # synced from poll, no meta needed
		finish_mode, chosen_skill,
		HPManager.opponent_hp, HPManager.player_hp,
		"player"
	)

	# Host resolves opponent authoritatively
	if not GameManager.is_solo and GameManager.is_host:
		var opp_finish_mode = _mirror_finish_mode(finish_mode)
		var opp_wpm = _estimate_opp_wpm(opp_finish_mode, words, server_first_finish_at_ms)
		var opp_typos = network_sync.opp_typos
		var opp_acc = _derive_opp_accuracy(enemy_typing_progress, sentence_length, opp_typos)

		var opp_result = SkillsManager.resolve_round(
			float(opp_wpm), opp_acc, opp_typos, typos,
			opp_finish_mode, network_sync.opp_chosen_skill,
			HPManager.player_hp, HPManager.opponent_hp,
			"opponent",
			false  # streaks already updated by the player resolve call
		)

		result.player_hp_delta += opp_result.opp_hp_delta
		result.opp_hp_delta    += opp_result.player_hp_delta
		result["opp_player_damage"] = opp_result.player_damage

		for line in opp_result.log:
			result.log.append(line)

	_apply_hp(result)
	_log_result(result, finish_mode, chosen_skill)
	_update_phantom_stack()

	return result

func _mirror_finish_mode(fm: String) -> String:
	match fm:
		"buff":       return "debuff"
		"debuff":     return "buff"
		"full_power": return "dnf"
		"dnf":        return "full_power"
		"tie":        return "tie"
		"no_attack":  return "no_attack"
		_:            return "debuff"

func _estimate_opp_wpm(opp_finish_mode: String, words: float, server_first_finish_at_ms: float) -> int:
	if opp_finish_mode in ["buff", "tie"]:
		var start_ms = network_sync.server_typing_started_at_ms
		if start_ms <= 0:
			return 60  # safe fallback — average typist
		if server_first_finish_at_ms <= 0 or server_first_finish_at_ms <= start_ms:
			return 60  # finish time invalid or before start
		var dur_min = (server_first_finish_at_ms - start_ms) / 60000.0
		if dur_min <= 0.0:
			return 60
		# Cap at 120 WPM — anything higher is likely a debug skip (F4) artifact
		return clamp(int(words / dur_min), 0, 120)
	elif opp_finish_mode == "debuff":
		return 40
	return 0

func _derive_opp_accuracy(opp_progress: float, sentence_length: int, opp_typos: int) -> float:
	var chars_typed = opp_progress * float(sentence_length)
	var total_typed = chars_typed + float(opp_typos)
	if total_typed <= 0: return 100.0
	return clampf((chars_typed / total_typed) * 100.0, 0.0, 100.0)

func _apply_hp(result: Dictionary) -> void:
	# In multiplayer, only the host authoritatively applies HP changes
	# Guests will receive HP updates via server sync (apply_hp_from_room)
	if GameManager.is_solo or GameManager.is_host:
		var role = "SOLO" if GameManager.is_solo else "HOST"
		print("[HP][%s] Before apply — player=%.0f opp=%.0f" % [role, HPManager.player_hp, HPManager.opponent_hp])
		# Apply damage first, then heals — so heals aren't wasted when at full HP
		# (e.g. Liora's Grace heal after taking damage this round)
		if result.player_damage > 0:
			HPManager.take_damage("opponent", result.player_damage)
		if not GameManager.is_solo:
			var opp_dmg = result.get("opp_player_damage", 0.0)
			if opp_dmg > 0:
				HPManager.take_damage("player", opp_dmg)
		if result.player_hp_delta != 0:
			HPManager.heal("player", result.player_hp_delta)
		if result.opp_hp_delta != 0:
			HPManager.heal("opponent", result.opp_hp_delta)
		print("[HP][%s] After apply  — player=%.0f opp=%.0f | dmg_dealt=%.0f opp_dmg=%.0f" % [
			role, HPManager.player_hp, HPManager.opponent_hp,
			result.player_damage, result.get("opp_player_damage", 0.0)])
	else:
		print("[HP][GUEST] Skipping local apply — waiting for server sync | dmg_dealt=%.0f" % result.player_damage)

func _update_phantom_stack() -> void:
	if SkillsManager.selected_passive != "phantom": return
	var acc = typing_handler.get_accuracy()
	if acc >= 90.0 and SkillsManager.phantom_stack > 0:
		SkillsManager.phantom_stack = min(3, SkillsManager.phantom_stack + 1)
	elif acc >= 85.0 and SkillsManager.phantom_stack == 0:
		SkillsManager.phantom_stack = 1
	else:
		SkillsManager.phantom_stack = 0

func _log_result(result: Dictionary, finish_mode: String, chosen_skill: String) -> void:
	for line in result.log:
		print("[Combat] ", line)
	
	# For display purposes only:
	# - Host/Solo: Use actual HPManager values (already updated)
	# - Guest: Show pre-round HP with self-effects applied.
	#   Incoming opponent damage is unknown until server sync — don't guess it.
	var display_player_hp: float = HPManager.player_hp
	var display_opp_hp: float = HPManager.opponent_hp
	
	# Guest applies only self-effects (hp_delta = Bloodlust self-damage, heals, etc.)
	# Opponent HP shown is pre-round value since we don't know their incoming damage yet.
	if not GameManager.is_solo and not GameManager.is_host:
		display_player_hp = clampf(HPManager.player_hp + result.player_hp_delta, 0, HPManager.player_max_hp)
		# Don't subtract player_damage from opp display — that would show a misleading
		# partial result. The server sync will update both HPs correctly after resolution.
		display_opp_hp = clampf(HPManager.opponent_hp, 0, HPManager.opponent_max_hp)
	
	print("╔══════════════════════════════════════════╗")
	if chosen_skill == "":
		print("║  [NO SKILL] — Base attack only           ║")
	else:
		match finish_mode:
			"buff":        print("║  🎯 [%s] — BUFF  (you finished 1st)   ║" % chosen_skill.to_upper())
			"debuff":      print("║  ⬇️ [%s] — DEBUFF (you finished 2nd) ║" % chosen_skill.to_upper())
			"full_power":  print("║  💥 [%s] — FULL POWER! (opp timed out)║" % chosen_skill.to_upper())
			"tie":         print("║  ⚡ [%s] — TIE (both get buff)        ║" % chosen_skill.to_upper())
			"no_attack":   print("║  ⏱️ [TIMEOUT] — No skill fires         ║")
	print("║  Player: %-30s  ║" % GameManager.user_data.username)
	print("║  DMG dealt:  %-5.0f                         ║" % result.player_damage)
	print("║  HP delta:   %+.0f                          ║" % result.player_hp_delta)
	print("║  Your HP:    %.0f / %.0f                     ║" % [display_player_hp, HPManager.player_max_hp])
	print("║  Opp HP:     %.0f / %.0f                     ║" % [display_opp_hp, HPManager.opponent_max_hp])
	print("║  Mana:       %d                             ║" % SkillsManager.player_mana)
	print("╚══════════════════════════════════════════╝")

# ─────────────────────────────────────────────
#  Victory / forfeit overlays
# ─────────────────────────────────────────────

func show_victory(entity: String, hud: Node) -> void:
	anim_controller.play_death_anim(entity)
	await get_tree().create_timer(0.6).timeout

	var victory_scene = load("res://scenes/ui/victory_screen.tscn").instantiate()
	# Don't pause the game - victory screen needs to poll for rematch status
	get_tree().paused = false
	victory_scene.process_mode = Node.PROCESS_MODE_ALWAYS
	hud.add_child(victory_scene)

	var won = (entity == "opponent")
	_save_match_history(won)
	victory_scene.set_result(won)
	match_ended.emit()

func show_opponent_forfeited_overlay(hud: Node) -> void:
	var overlay = Panel.new()
	overlay.set_anchors_preset(Control.PRESET_CENTER)
	overlay.custom_minimum_size = Vector2(380, 200)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	hud.add_child(overlay)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 24; vbox.offset_top = 24
	vbox.offset_right = -24; vbox.offset_bottom = -24
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
	leave_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn"))
	vbox.add_child(leave_btn)

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

func show_match_ended_overlay(hud: Node, reason: String) -> void:
	var overlay = Panel.new()
	overlay.set_anchors_preset(Control.PRESET_CENTER)
	overlay.custom_minimum_size = Vector2(420, 220)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	hud.add_child(overlay)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 24; vbox.offset_top = 24
	vbox.offset_right = -24; vbox.offset_bottom = -24
	vbox.add_theme_constant_override("separation", 14)
	overlay.add_child(vbox)

	var msg = Label.new()
	msg.text = "Match ended."
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.add_theme_font_size_override("font_size", 24)
	vbox.add_child(msg)

	var detail = Label.new()
	detail.text = "Reason: %s" % reason
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(detail)

	var leave_btn = Button.new()
	leave_btn.text = "Return to Main Menu"
	leave_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn"))
	vbox.add_child(leave_btn)

# ─────────────────────────────────────────────
#  Match history
# ─────────────────────────────────────────────

func _save_match_history(won: bool) -> void:
	if GameManager.user_data.id == 0: return
	# Use the locked final WPM if available (most accurate — captured at finish moment).
	# Fall back to calculating from sentence_length / elapsed if still typing (shouldn't happen).
	var wpm = float(typing_handler.get_wpm())
	var accuracy = typing_handler.get_accuracy()
	wpm      = clampf(wpm if is_finite(wpm) else 0.0, 0.0, 250.0)
	accuracy = clampf(accuracy if is_finite(accuracy) else 0.0, 0.0, 100.0)

	var SERVER = GameManager.SERVER_URL
	var req = HTTPRequest.new()
	add_child(req)
	var data = {
		"user_id":    GameManager.user_data.id,
		"username":   GameManager.user_data.username,
		"match_type": "custom" if GameManager.is_solo else ("online" if GameManager.is_matchmaking else "custom"),
		"wpm":        wpm,
		"accuracy":   accuracy,
		"typos":      typing_handler.typos_count,
		"won":        won
	}
	req.request(SERVER + "/api/game/history", ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, JSON.stringify(data))
