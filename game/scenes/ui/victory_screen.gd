extends Control

@onready var result_label = $CenterContainer/VBoxContainer/ResultLabel
@onready var back_button = $CenterContainer/VBoxContainer/HBoxContainer/BackButton
@onready var match_again_button = $CenterContainer/VBoxContainer/HBoxContainer/MatchAgainButton

func _ready():
	back_button.pressed.connect(_on_back_pressed)
	match_again_button.pressed.connect(_on_match_again_pressed)
	
	if GameManager.is_solo:
		match_again_button.text = "Restart"
	else:
		match_again_button.text = "Match Again"

func set_result(won: bool):
	if won:
		result_label.text = "VICTORY!"
		result_label.modulate = Color.GREEN
	else:
		result_label.text = "DEFEAT!"
		result_label.modulate = Color.RED

func _on_back_pressed():
	GameManager.current_room = ""
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")

func _on_match_again_pressed():
	if GameManager.is_solo:
		get_tree().change_scene_to_file("res://scenes/game/game.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/ui/custom_room.tscn")
