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
