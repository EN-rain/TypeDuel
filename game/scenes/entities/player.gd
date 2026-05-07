# Player script with manual AnimationPlayer support
extends Node2D

@export var default_autoplay: StringName = &"idle"

signal hit_triggered

func _ready() -> void:
	if default_autoplay != &"" and has_node("AnimationPlayer"):
		$AnimationPlayer.play(default_autoplay)

func play(anim: StringName) -> void:
	var anim_player: AnimationPlayer = get_node_or_null("AnimationPlayer")
	if anim == StringName(&"") or anim_player == null:
		return
	if anim_player.has_animation(anim):
		anim_player.play(anim)

## Called by AnimationPlayer via "Call Method Track" at specific frames
func trigger_hit() -> void:
	hit_triggered.emit()

# ── SFX playback functions ──────────────────────────────────────────

## Play female death vocal SFX
func play_sfx_female_death() -> void:
	$SfxFemaleDeathVocal.play()

## Play male death vocal SFX
func play_sfx_male_death() -> void:
	$SfxMaleDeathVocal.play()

## Play sword draw SFX
func play_sfx_sword_draw() -> void:
	$SfxSwordDraw.play()

## Play sword hit flesh/bone variant 1 SFX
func play_sfx_sword_hit_1() -> void:
	$SfxSwordHit1.play()

## Play sword hit flesh/bone variant 2 SFX
func play_sfx_sword_hit_2() -> void:
	$SfxSwordHit2.play()
