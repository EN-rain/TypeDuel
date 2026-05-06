extends Control

func _ready():
	# Fade in UI content only
	$VBoxContainer.modulate.a = 0.0
	var tween = create_tween()
	tween.tween_property($VBoxContainer, "modulate:a", 1.0, 0.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

func _on_back_button_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
