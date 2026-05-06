extends Node

## AnimationController
## Owns all character sprite creation, animation playback, and visual effects.
## Attach to a child node named "AnimationController" under the Game scene root.

# Character name → SpriteFrames resource path
const CHARACTER_SPRITES = {
	"Riven":  "res://assets/spriteframes/riven.tres",
	"Zephon": "res://assets/spriteframes/zephone.tres",
	"Liora":  "res://assets/spriteframes/leora.tres",
}
const CHARACTER_IDLE_ANIM = {
	"Riven":  "idle",
	"Zephon": "zephon-idle",
	"Liora":  "idle",
}
const CHARACTER_HURT_ANIM = {
	"Riven":  "hurt",
	"Zephon": "zephone-hurt",
	"Liora":  "hurt",
}
const CHARACTER_DEATH_ANIM = {
	"Riven":  "death",
	"Zephon": "zephone-death",
	"Liora":  "death",
}
const SKILL_ANIM_NAME = {
	"quickslash": "quickslash",
	"soulbreak":  "soulbreak",
	"whiplash":   "whiplash", # Fixed to match player.tscn
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
		return
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
	
	# Unique ID for this specific call to prevent multiple hits from clashing
	var call_id = Time.get_ticks_msec() + randi()
	node.set_meta("last_idle_call", call_id)
	
	await get_tree().create_timer(seconds).timeout
	
	if not is_instance_valid(node): return
	
	# Only proceed if no newer restore_idle_after has been called since
	if node.get_meta("last_idle_call") == call_id:
		safe_play_anim(node, idle_anim)

func attack_anim_for(char_name: String, skill_id: String) -> String:
	var base: String = str(SKILL_ANIM_NAME.get(skill_id, ""))
	if base == "": base = "quickslash"
	if char_name == "Zephon": return "zephone-" + base
	return base

# ─────────────────────────────────────────────
#  Combat animations
# ─────────────────────────────────────────────

func play_combat_anims(skill_id: String, opp_skill_id: String = "", finish_mode: String = "") -> void:
	var my_char: String = GameManager.selected_character
	var opp_char: String = GameManager.opponent_character

	# Yield one frame so the scene tree is fully settled before playing animations.
	await get_tree().process_frame

	var hud_anim: AnimationPlayer = null
	if get_parent() and get_parent().has_node("HUD/Animation/AnimationPlayer"):
		hud_anim = get_parent().get_node("HUD/Animation/AnimationPlayer")

	var player_has_skill: bool = skill_id != ""
	var opp_has_skill:    bool = opp_skill_id != ""
	var any_skill:        bool = player_has_skill or opp_has_skill

	# ── HUD "anim" forward — only when at least one skill fires ──────────
	if any_skill and hud_anim and hud_anim.has_animation("anim"):
		hud_anim.play("anim")
		await hud_anim.animation_finished

	# ── Determine sequencing from finish_mode ────────────────────────────
	# player_won  → player attacks first, then opponent (if they have a skill)
	# opp_won     → opponent attacks first, then player (if they have a skill)
	# simultaneous (no_attack / "") → timeout penalty, no skill anims
	var player_won:    bool = finish_mode in ["buff", "full_power", "tie"]
	var simultaneous:  bool = finish_mode == "no_attack" or finish_mode == ""

	if simultaneous:
		# Timeout: both take the penalty hit at the same time, no skill anims.
		await get_tree().create_timer(0.15).timeout
		_on_self_penalty()
		await get_tree().create_timer(0.4).timeout

	elif player_won:
		# ── Winner (player) attacks first ────────────────────────────────
		if player_has_skill:
			var atk = attack_anim_for(my_char, skill_id)
			var sprite = get_visual(p1)
			var marker = p2.get_node_or_null("Marker2D") if p2 else null
			if skill_id != "quickslash" and marker and sprite:
				sprite.global_position = marker.global_position
			safe_play_anim(p1, atk)
			var wait = 1.0 if skill_id == "whiplash" else 0.8
			await get_tree().create_timer(wait).timeout
			# Reset player position after their attack
			var s1 = get_visual(p1)
			if s1: s1.position = Vector2.ZERO

		# ── Loser (opponent) retaliates after (if they have a skill) ─────
		if opp_has_skill:
			var opp_atk = attack_anim_for(opp_char, opp_skill_id)
			var opp_sprite = get_visual(p2)
			var marker = p1.get_node_or_null("Marker2D") if p1 else null
			if opp_skill_id != "quickslash" and marker and opp_sprite:
				opp_sprite.global_position = marker.global_position
			safe_play_anim(p2, opp_atk)
			var wait = 1.0 if opp_skill_id == "whiplash" else 0.8
			await get_tree().create_timer(wait).timeout
			# Reset opponent position after their attack
			var s2 = get_visual(p2)
			if s2: s2.position = Vector2.ZERO

	else:
		# ── Winner (opponent) attacks first ──────────────────────────────
		if opp_has_skill:
			var opp_atk = attack_anim_for(opp_char, opp_skill_id)
			var opp_sprite = get_visual(p2)
			var marker = p1.get_node_or_null("Marker2D") if p1 else null
			if opp_skill_id != "quickslash" and marker and opp_sprite:
				opp_sprite.global_position = marker.global_position
			safe_play_anim(p2, opp_atk)
			var wait = 1.0 if opp_skill_id == "whiplash" else 0.8
			await get_tree().create_timer(wait).timeout
			var s2 = get_visual(p2)
			if s2: s2.position = Vector2.ZERO

		# ── Loser (player) retaliates after (if they have a skill) ───────
		if player_has_skill:
			var atk = attack_anim_for(my_char, skill_id)
			var sprite = get_visual(p1)
			var marker = p2.get_node_or_null("Marker2D") if p2 else null
			if skill_id != "quickslash" and marker and sprite:
				sprite.global_position = marker.global_position
			safe_play_anim(p1, atk)
			var wait = 1.0 if skill_id == "whiplash" else 0.8
			await get_tree().create_timer(wait).timeout
			var s1 = get_visual(p1)
			if s1: s1.position = Vector2.ZERO

	# ── Restore idles ─────────────────────────────────────────────────────
	restore_idle_after(p1, my_char, 0.1)
	restore_idle_after(p2, opp_char, 0.1)

	_check_death_final()

	# ── HUD "anim" backwards — only when at least one skill fired ─────────
	if any_skill and hud_anim and hud_anim.has_animation("anim"):
		hud_anim.play_backwards("anim")
		await hud_anim.animation_finished

func play_death_anim(entity: String) -> void:
	var my_char:  String = GameManager.selected_character
	var opp_char: String = GameManager.opponent_character
	if entity == "player":
		safe_play_anim(p1, str(CHARACTER_DEATH_ANIM.get(my_char, "death")))
	else:
		safe_play_anim(p2, str(CHARACTER_DEATH_ANIM.get(opp_char, "death")))

# ─────────────────────────────────────────────
#  Spawning
# ─────────────────────────────────────────────

func create_character_sprite(char_name: String, flip: bool) -> Node2D:
	var player_scene = load("res://scenes/entities/player.tscn")
	var node = player_scene.instantiate()
	
	# Note: player.gd no longer uses apply_sprite_frames, 
	# it uses the manual AnimationPlayer we just built.
	
	if flip:
		node.scale.x = -1

	var idle_anim = CHARACTER_IDLE_ANIM.get(char_name, "idle")
	safe_play_anim(node, str(idle_anim))
	return node

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

func _on_p1_hit() -> void:
	var opp_char: String = GameManager.opponent_character
	spawn_blood_particles(p2.global_position)
	if HPManager.opponent_hp <= 0:
		safe_play_anim(p2, str(CHARACTER_DEATH_ANIM.get(opp_char, "death")))
	else:
		safe_play_anim(p2, str(CHARACTER_HURT_ANIM.get(opp_char, "hurt")))
		fade_out_in(p2)
		restore_idle_after(p2, opp_char, 0.4)

func _on_p2_hit() -> void:
	var my_char: String = GameManager.selected_character
	spawn_blood_particles(p1.global_position)
	if HPManager.player_hp <= 0:
		safe_play_anim(p1, str(CHARACTER_DEATH_ANIM.get(my_char, "death")))
	else:
		safe_play_anim(p1, str(CHARACTER_HURT_ANIM.get(my_char, "hurt")))
		fade_out_in(p1)
		restore_idle_after(p1, my_char, 0.4)

## Timeout penalty (-5 HP to both, no attacker).
## Both characters take the hit simultaneously — hurt anim + blood on each.
func _on_self_penalty() -> void:
	var my_char:  String = GameManager.selected_character
	var opp_char: String = GameManager.opponent_character
	# Player side
	spawn_blood_particles(p1.global_position)
	if HPManager.player_hp <= 0:
		safe_play_anim(p1, str(CHARACTER_DEATH_ANIM.get(my_char, "death")))
	else:
		safe_play_anim(p1, str(CHARACTER_HURT_ANIM.get(my_char, "hurt")))
		fade_out_in(p1)
		restore_idle_after(p1, my_char, 0.4)
	# Opponent side
	spawn_blood_particles(p2.global_position)
	if HPManager.opponent_hp <= 0:
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
	# Fallback if death is needed but no hit was triggered
	if HPManager.opponent_hp <= 0:
		var opp_char: String = GameManager.opponent_character
		safe_play_anim(p2, str(CHARACTER_DEATH_ANIM.get(opp_char, "death")))
	if HPManager.player_hp <= 0:
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
