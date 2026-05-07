extends Node

## AnimationController
## Owns all character sprite creation, animation playback, and visual effects.
## Attach to a child node named "AnimationController" under the Game scene root.

# Character name → SpriteFrames resource path (legacy, kept for reference)
const CHARACTER_SPRITES = {
	"Riven":  "res://assets/spriteframes/riven.tres",
	"Zephon": "res://assets/spriteframes/zephone.tres",
	"Liora":  "res://assets/spriteframes/leora.tres",
}
# All characters use the same animation names — rows are remapped at spawn time
const CHARACTER_IDLE_ANIM = {
	"Riven":  "idle",
	"Zephon": "idle",
	"Liora":  "idle",
}
const CHARACTER_HURT_ANIM = {
	"Riven":  "hurt",
	"Zephon": "hurt",
	"Liora":  "hurt",
}
const CHARACTER_DEATH_ANIM = {
	"Riven":  "death",
	"Zephon": "death",
	"Liora":  "death",
}
const SKILL_ANIM_NAME = {
	"quickslash": "quickslash",
	"soulbreak":  "soulbreak",
	"whiplash":   "whiplash",
}

# Set by Game after spawning
var p1: Node = null
var p2: Node = null

# ─────────────────────────────────────────────
#  Sprite helpers
# ─────────────────────────────────────────────

func get_visual(node: Node) -> CanvasItem:
	if node == null:
		return null
	if node.has_node("Sprite2D"):
		return node.get_node("Sprite2D") as Sprite2D
	if node.has_node("AnimatedSprite2D"):
		return node.get_node("AnimatedSprite2D") as AnimatedSprite2D
	return null

func get_anim_player(node: Node) -> AnimationPlayer:
	if node == null:
		return null
	if node.has_node("AnimationPlayer"):
		return node.get_node("AnimationPlayer") as AnimationPlayer
	return null

func has_anim(node: Node, anim: String) -> bool:
	if anim == "":
		return false
	var anim_player := get_anim_player(node)
	if anim_player != null:
		return anim_player.has_animation(anim)
	var sprite := get_visual(node)
	if sprite != null and sprite is AnimatedSprite2D:
		var as2d := sprite as AnimatedSprite2D
		return as2d.sprite_frames != null and as2d.sprite_frames.has_animation(anim)
	return false

func safe_play_anim(node: Node, anim: String) -> void:
	if anim == "" or not has_anim(node, anim):
		print("[AnimController] safe_play_anim SKIPPED | anim='%s' | has_anim=%s" % [anim, has_anim(node, anim)])
		return
	print("[AnimController] safe_play_anim PLAYING | node=%s | anim='%s'" % [node.name if node else StringName("null"), anim])
	if node.has_method("play"):
		node.call("play", StringName(anim))
		return
	var anim_player := get_anim_player(node)
	if anim_player != null:
		anim_player.play(anim)
		return
	var sprite := get_visual(node)
	if sprite != null and sprite is AnimatedSprite2D:
		(sprite as AnimatedSprite2D).play(anim)

func fade_out_in(node: Node, out_s: float = 0.12, in_s: float = 0.12, hold_s: float = 0.03) -> void:
	var visual: CanvasItem = get_visual(node)
	if visual == null:
		return
	if visual.has_meta("fade_tween"):
		var prev = visual.get_meta("fade_tween")
		if prev != null and prev is Tween:
			(prev as Tween).kill()
	visual.modulate.a = 1.0
	var tween: Tween = create_tween()
	visual.set_meta("fade_tween", tween)
	tween.tween_property(visual, "modulate:a", 0.0, out_s).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.tween_interval(hold_s)
	tween.tween_property(visual, "modulate:a", 1.0, in_s).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

func restore_idle_after(node: Node, char_name: String, seconds: float) -> void:
	if not is_instance_valid(node): return
	var idle_anim: String = str(CHARACTER_IDLE_ANIM.get(char_name, "idle"))
	
	var call_id = Time.get_ticks_msec() + randi()
	node.set_meta("last_idle_call", call_id)
	
	await get_tree().create_timer(seconds).timeout
	
	if not is_instance_valid(node): return
	# Don't restore idle if this character's death animation has played
	var is_p1 = (node == p1)
	if is_p1 and _p1_death_played: return
	if not is_p1 and _p2_death_played: return
	if node.get_meta("last_idle_call") == call_id:
		safe_play_anim(node, idle_anim)

func attack_anim_for(_char_name: String, skill_id: String) -> String:
	var base: String = str(SKILL_ANIM_NAME.get(skill_id, ""))
	if base == "": base = "quickslash"
	# All characters currently use the same animation names from player.tscn.
	# When character-specific animations are added, add prefix logic here.
	return base

# ─────────────────────────────────────────────
#  Combat animations
# ─────────────────────────────────────────────

func _teleport_to_marker(attacker: Node, target: Node) -> void:
	if attacker == null or target == null: return
	var marker = target.get_node_or_null("Marker2D")
	if marker == null: return
	attacker.global_position = marker.global_position

func play_combat_anims(skill_id: String, opp_skill_id: String = "", finish_mode: String = "") -> void:
	var my_char: String = GameManager.selected_character
	var opp_char: String = GameManager.opponent_character

	print("[AnimController] play_combat_anims called | skill_id='%s' | opp_skill_id='%s' | finish_mode='%s'" % [skill_id, opp_skill_id, finish_mode])

	# Guard: if a combat sequence is already running, wait for it to finish first
	# with a safety timeout to prevent infinite blocking
	if _in_combat_sequence:
		print("[AnimController] Waiting for previous combat sequence to finish...")
		var wait_frames := 0
		while _in_combat_sequence and wait_frames < 300:  # max ~5s at 60fps
			await get_tree().process_frame
			wait_frames += 1
		if _in_combat_sequence:
			print("[AnimController] TIMEOUT: forced reset of _in_combat_sequence after %d frames" % wait_frames)
			_in_combat_sequence = false

	await get_tree().process_frame
	print("[AnimController] Starting combat sequence | skill='%s' opp='%s' mode='%s'" % [skill_id, opp_skill_id, finish_mode])
	_in_combat_sequence = true
	# Only reset per-character death flags if that character is still alive
	if HPManager.player_hp > 0:
		_p1_death_played = false
	if HPManager.opponent_hp > 0:
		_p2_death_played = false

	var hud_anim: AnimationPlayer = null
	if get_parent() and get_parent().has_node("HUD/Animation/AnimationPlayer"):
		hud_anim = get_parent().get_node("HUD/Animation/AnimationPlayer")

	var player_has_skill: bool = skill_id != ""
	var opp_has_skill:    bool = opp_skill_id != ""
	var any_skill:        bool = player_has_skill or opp_has_skill

	print("[AnimController] player_has_skill=%s | opp_has_skill=%s | any_skill=%s" % [player_has_skill, opp_has_skill, any_skill])

	# If no skills at all, skip all animations and just stay idle
	if not any_skill:
		print("[AnimController] No skills - staying idle, skipping combat sequence")
		_in_combat_sequence = false
		await get_tree().create_timer(0.5).timeout
		return

	if any_skill and hud_anim and hud_anim.has_animation("anim"):
		hud_anim.play("anim")
		await hud_anim.animation_finished

	var player_won:   bool = finish_mode in ["buff", "full_power", "tie"]
	var simultaneous: bool = finish_mode == "no_attack" or finish_mode == ""

	print("[AnimController] player_won=%s | simultaneous=%s" % [player_won, simultaneous])

	if simultaneous:
		await get_tree().create_timer(0.15).timeout
		_on_self_penalty()
		await get_tree().create_timer(0.4).timeout

	elif player_won:
		# ── Step 1: winner (p1) attacks ──────────────────────────────────────
		if player_has_skill:
			var atk = attack_anim_for(my_char, skill_id)
			print("[AnimController] P1 attacking | char=%s skill=%s anim=%s" % [my_char, skill_id, atk])
			if skill_id in ["whiplash", "soulbreak"]:
				_teleport_to_marker(p1, p2)
			safe_play_anim(p1, atk)
			var p1_anim = get_anim_player(p1)
			if p1_anim and p1_anim.has_animation(atk):
				var dur = p1_anim.get_animation(atk).length
				print("[AnimController] P1 attack anim length=%.2f" % dur)
				await get_tree().create_timer(dur).timeout
			else:
				print("[AnimController] P1 attack anim not found, using fallback 0.5s")
				await get_tree().create_timer(0.5).timeout
			if is_instance_valid(p1): p1.global_position = p1.get_parent().global_position

		print("[AnimController] P1 attack done, waiting for hurt...")
		await get_tree().create_timer(0.35).timeout

		if opp_has_skill:
			var opp_atk = attack_anim_for(opp_char, opp_skill_id)
			print("[AnimController] P2 retaliating | char=%s skill=%s anim=%s" % [opp_char, opp_skill_id, opp_atk])
			if opp_skill_id in ["whiplash", "soulbreak"]:
				_teleport_to_marker(p2, p1)
			safe_play_anim(p2, opp_atk)
			var p2_anim = get_anim_player(p2)
			if p2_anim and p2_anim.has_animation(opp_atk):
				var dur = p2_anim.get_animation(opp_atk).length
				print("[AnimController] P2 retaliate anim length=%.2f" % dur)
				await get_tree().create_timer(dur).timeout
			else:
				print("[AnimController] P2 retaliate anim not found, using fallback 0.5s")
				await get_tree().create_timer(0.5).timeout
			if is_instance_valid(p2): p2.global_position = p2.get_parent().global_position
			print("[AnimController] P2 retaliate done, waiting for hurt...")
			await get_tree().create_timer(0.35).timeout

	else:
		# ── Step 1: winner (p2) attacks ──────────────────────────────────────
		if opp_has_skill:
			var opp_atk = attack_anim_for(opp_char, opp_skill_id)
			print("[AnimController] P2 attacking | char=%s skill=%s anim=%s" % [opp_char, opp_skill_id, opp_atk])
			if opp_skill_id in ["whiplash", "soulbreak"]:
				_teleport_to_marker(p2, p1)
			safe_play_anim(p2, opp_atk)
			var p2_anim = get_anim_player(p2)
			if p2_anim and p2_anim.has_animation(opp_atk):
				var dur = p2_anim.get_animation(opp_atk).length
				print("[AnimController] P2 attack anim length=%.2f" % dur)
				await get_tree().create_timer(dur).timeout
			else:
				print("[AnimController] P2 attack anim not found, using fallback 0.5s")
				await get_tree().create_timer(0.5).timeout
			if is_instance_valid(p2): p2.global_position = p2.get_parent().global_position

		print("[AnimController] P2 attack done, waiting for hurt...")
		await get_tree().create_timer(0.35).timeout

		if player_has_skill:
			var atk = attack_anim_for(my_char, skill_id)
			print("[AnimController] P1 retaliating | char=%s skill=%s anim=%s" % [my_char, skill_id, atk])
			if skill_id in ["whiplash", "soulbreak"]:
				_teleport_to_marker(p1, p2)
			safe_play_anim(p1, atk)
			var p1_anim = get_anim_player(p1)
			if p1_anim and p1_anim.has_animation(atk):
				var dur = p1_anim.get_animation(atk).length
				print("[AnimController] P1 retaliate anim length=%.2f" % dur)
				await get_tree().create_timer(dur).timeout
			else:
				print("[AnimController] P1 retaliate anim not found, using fallback 0.5s")
				await get_tree().create_timer(0.5).timeout
			if is_instance_valid(p1): p1.global_position = p1.get_parent().global_position
			print("[AnimController] P1 retaliate done, waiting for hurt...")
			await get_tree().create_timer(0.35).timeout

	# ── Restore idles ─────────────────────────────────────────────────────
	print("[AnimController] Combat sequence complete, restoring idles")
	_in_combat_sequence = false
	# Check death FIRST — so _death_played is set before restore_idle_after runs
	_check_death_final()
	# Only restore idle for characters that are still alive
	if HPManager.player_hp > 0:
		restore_idle_after(p1, my_char, 0.1)
	if HPManager.opponent_hp > 0:
		restore_idle_after(p2, opp_char, 0.1)

	if any_skill and hud_anim and hud_anim.has_animation("anim"):
		# Use a timer equal to the animation length instead of awaiting animation_finished,
		# which is unreliable on reverse playback in Godot 4.
		var anim_len: float = hud_anim.get_animation("anim").length
		hud_anim.speed_scale = -1.0
		hud_anim.seek(anim_len, true)
		hud_anim.play("anim")
		await get_tree().create_timer(anim_len).timeout
		hud_anim.stop()
		hud_anim.speed_scale = 1.0

func play_death_anim(entity: String) -> void:
	play_death_anim_and_get_duration(entity)

## Plays the death animation for the given entity and returns the total wait time
## the caller should observe before showing the victory screen.
## If the hit callback already triggered the death sequence (hurt → death),
## we return the remaining time so the caller still waits for it to finish.
func play_death_anim_and_get_duration(entity: String) -> float:
	var my_char:  String = GameManager.selected_character
	var opp_char: String = GameManager.opponent_character

	var node: Node
	var char_name: String
	var already_played: bool

	if entity == "player":
		node = p1; char_name = my_char; already_played = _p1_death_played
	else:
		node = p2; char_name = opp_char; already_played = _p2_death_played

	var death_anim: String = str(CHARACTER_DEATH_ANIM.get(char_name, "death"))

	if not already_played:
		# Death wasn't triggered by a hit callback — play it now directly
		if entity == "player": _p1_death_played = true
		else:                  _p2_death_played = true
		safe_play_anim(node, death_anim)

	# Return the death animation length so the caller can wait for it
	var anim_player = get_anim_player(node)
	if anim_player != null and anim_player.has_animation(death_anim):
		var death_len: float = anim_player.get_animation(death_anim).length
		if already_played:
			# Hit callback played hurt (0.35s) then death — estimate remaining time
			# conservatively so we never cut it short
			return death_len + 0.35
		return death_len
	return 0.6  # fallback if animation metadata unavailable

# ─────────────────────────────────────────────
#  Spawning
# ─────────────────────────────────────────────

func create_character_sprite(char_name: String, flip: bool) -> Node2D:
	var player_scene = load("res://scenes/entities/player.tscn")
	var node = player_scene.instantiate()
	
	if flip:
		node.scale.x = -1

	# Remap animation atlas regions to the correct character row
	_apply_character_row(node, char_name)

	var idle_anim = CHARACTER_IDLE_ANIM.get(char_name, "idle")
	safe_play_anim(node, str(idle_anim))
	return node

# Each character occupies a different row in the shared sprite sheets.
# Row offsets: y offset for each animation type per character.
const CHAR_ROW = {
	"Riven": {
		"idle": 150, "death": 75, "hurt": 75,
		"quickslash": 75, "soulbreak": 100, "whiplash": 100
	},
	"Zephon": {
		"idle": 0, "death": 0, "hurt": 0,
		"quickslash": 0, "soulbreak": 0, "whiplash": 0
	},
	"Liora": {
		"idle": 300, "death": 150, "hurt": 150,
		"quickslash": 150, "soulbreak": 200, "whiplash": 200
	},
}

func _apply_character_row(node: Node, char_name: String) -> void:
	if not CHAR_ROW.has(char_name): return
	var rows: Dictionary = CHAR_ROW[char_name]
	var anim_player = node.get_node_or_null("AnimationPlayer")
	if anim_player == null: return

	var anim_to_row_key = {
		"idle": "idle", "death": "death", "hurt": "hurt",
		"quickslash": "quickslash", "soulbreak": "soulbreak", "whiplash": "whiplash"
	}

	for lib_name in anim_player.get_animation_library_list():
		# Duplicate the entire library so we don't modify the shared resource
		var orig_lib = anim_player.get_animation_library(lib_name)
		var new_lib: AnimationLibrary = AnimationLibrary.new()

		for anim_name in orig_lib.get_animation_list():
			var orig_anim: Animation = orig_lib.get_animation(anim_name)
			var row_key = anim_to_row_key.get(anim_name, "")

			if row_key == "" or not rows.has(row_key):
				# Keep animation as-is (e.g. RESET)
				new_lib.add_animation(anim_name, orig_anim)
				continue

			var target_y: int = rows[row_key]
			var anim: Animation = orig_anim.duplicate()

			for t in anim.get_track_count():
				if anim.track_get_path(t) != NodePath("Sprite2D:texture"): continue
				for k in anim.track_get_key_count(t):
					var tex = anim.track_get_key_value(t, k)
					if tex is AtlasTexture:
						var new_tex: AtlasTexture = tex.duplicate()
						var r: Rect2 = new_tex.region
						new_tex.region = Rect2(r.position.x, target_y, r.size.x, r.size.y)
						anim.track_set_key_value(t, k, new_tex)

			new_lib.add_animation(anim_name, anim)

		# Replace the library with our per-instance duplicate
		anim_player.remove_animation_library(lib_name)
		anim_player.add_animation_library(lib_name, new_lib)

func spawn_players(parent: Node) -> void:
	if parent.has_node("Player"):  parent.get_node("Player").hide()
	if parent.has_node("Player2"): parent.get_node("Player2").hide()

	var my_side_node    = "TileMap/P1"
	var enemy_side_node = "TileMap/P2"

	var own_char = GameManager.selected_character
	var opp_char = GameManager.opponent_character

	p1 = create_character_sprite(own_char, false)
	if p1.has_signal("hit_triggered"):
		p1.connect("hit_triggered", _on_p1_hit)
	
	if parent.has_node(my_side_node):
		parent.get_node(my_side_node).add_child(p1)
		p1.position = Vector2.ZERO
	else:
		p1.position = Vector2(300, 300)
		parent.add_child(p1)

	p2 = create_character_sprite(opp_char, true)
	if p2.has_signal("hit_triggered"):
		p2.connect("hit_triggered", _on_p2_hit)
		
	if parent.has_node(enemy_side_node):
		parent.get_node(enemy_side_node).add_child(p2)
		p2.position = Vector2.ZERO
	else:
		p2.position = Vector2(850, 300)
		parent.add_child(p2)

var _in_combat_sequence: bool = false
var _p1_death_played: bool = false  # p1 (player) death animation played
var _p2_death_played: bool = false  # p2 (opponent) death animation played

func _on_p1_hit() -> void:
	var opp_char: String = GameManager.opponent_character
	spawn_blood_particles(p2.global_position)
	if HPManager.opponent_hp <= 0 and not _p2_death_played:
		_p2_death_played = true
		safe_play_anim(p2, str(CHARACTER_HURT_ANIM.get(opp_char, "hurt")))
		fade_out_in(p2)
		get_tree().create_timer(0.35).timeout.connect(func():
			if is_instance_valid(p2): safe_play_anim(p2, str(CHARACTER_DEATH_ANIM.get(opp_char, "death")))
		)
	else:
		safe_play_anim(p2, str(CHARACTER_HURT_ANIM.get(opp_char, "hurt")))
		fade_out_in(p2)
		if not _in_combat_sequence:
			restore_idle_after(p2, opp_char, 0.4)

func _on_p2_hit() -> void:
	var my_char: String = GameManager.selected_character
	spawn_blood_particles(p1.global_position)
	if HPManager.player_hp <= 0 and not _p1_death_played:
		_p1_death_played = true
		safe_play_anim(p1, str(CHARACTER_HURT_ANIM.get(my_char, "hurt")))
		fade_out_in(p1)
		get_tree().create_timer(0.35).timeout.connect(func():
			if is_instance_valid(p1): safe_play_anim(p1, str(CHARACTER_DEATH_ANIM.get(my_char, "death")))
		)
	else:
		safe_play_anim(p1, str(CHARACTER_HURT_ANIM.get(my_char, "hurt")))
		fade_out_in(p1)
		if not _in_combat_sequence:
			restore_idle_after(p1, my_char, 0.4)

## Timeout penalty (-5 HP to both, no attacker).
## Both characters take the hit simultaneously — hurt anim + blood on each.
func _on_self_penalty() -> void:
	var my_char:  String = GameManager.selected_character
	var opp_char: String = GameManager.opponent_character
	# Player side
	spawn_blood_particles(p1.global_position)
	if HPManager.player_hp <= 0 and not _p1_death_played:
		_p1_death_played = true
		safe_play_anim(p1, str(CHARACTER_DEATH_ANIM.get(my_char, "death")))
	else:
		safe_play_anim(p1, str(CHARACTER_HURT_ANIM.get(my_char, "hurt")))
		fade_out_in(p1)
		restore_idle_after(p1, my_char, 0.4)
	# Opponent side
	spawn_blood_particles(p2.global_position)
	if HPManager.opponent_hp <= 0 and not _p2_death_played:
		_p2_death_played = true
		safe_play_anim(p2, str(CHARACTER_DEATH_ANIM.get(opp_char, "death")))
	else:
		safe_play_anim(p2, str(CHARACTER_HURT_ANIM.get(opp_char, "hurt")))
		fade_out_in(p2)
		restore_idle_after(p2, opp_char, 0.4)

func spawn_blood_particles(pos: Vector2) -> void:
	var particles = CPUParticles2D.new()
	get_parent().add_child(particles)
	particles.global_position = pos
	
	# Blood-like aesthetics
	particles.amount = 15
	particles.lifetime = 0.5
	particles.one_shot = true
	particles.explosiveness = 0.8
	particles.spread = 180.0
	particles.gravity = Vector2(0, 500)
	particles.initial_velocity_min = 100.0
	particles.initial_velocity_max = 250.0
	particles.scale_amount_min = 3.0
	particles.scale_amount_max = 6.0
	particles.color = Color(0.8, 0.1, 0.1, 1.0) # Deep Red
	
	particles.emitting = true
	
	# Auto-cleanup
	get_tree().create_timer(1.0).timeout.connect(func():
		if is_instance_valid(particles): particles.queue_free()
	)

func _check_death_final() -> void:
	# Fallback if death is needed but no hit was triggered — only play once per character
	if HPManager.opponent_hp <= 0 and not _p2_death_played:
		_p2_death_played = true
		var opp_char: String = GameManager.opponent_character
		safe_play_anim(p2, str(CHARACTER_DEATH_ANIM.get(opp_char, "death")))
	if HPManager.player_hp <= 0 and not _p1_death_played:
		_p1_death_played = true
		var my_char: String = GameManager.selected_character
		safe_play_anim(p1, str(CHARACTER_DEATH_ANIM.get(my_char, "death")))

# ─────────────────────────────────────────────
#  Passive popup
# ─────────────────────────────────────────────

func show_passive_popup(passive_type: String) -> void:
	if GameManager.is_solo: return
	if p2 == null: return
	var label: Label = Label.new()
	label.text = passive_type.capitalize() + " activated"
	label.modulate = Color(1, 1, 1, 1)
	get_parent().add_child(label)
	label.global_position = p2.global_position + Vector2(0, -80)
	var tween: Tween = create_tween()
	tween.tween_property(label, "global_position:y", label.global_position.y - 30, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(label, "modulate:a", 0.0, 0.6)
	tween.finished.connect(func():
		if is_instance_valid(label): label.queue_free()
	)
