extends Control

func _on_skill_1_pressed():
	print("Skill 1 selected")
	get_tree().change_scene_to_file("res://scenes/ui/game.tscn")

func _on_skill_2_pressed():
	print("Skill 2 selected")
	get_tree().change_scene_to_file("res://scenes/ui/game.tscn")

func _on_skill_3_pressed():
	print("Skill 3 selected")
	get_tree().change_scene_to_file("res://scenes/ui/game.tscn")

func _on_back_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
