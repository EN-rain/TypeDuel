extends Control

func _on_play_pressed():
	print("Play pressed - Transitioning to Skill Selection...")
	get_tree().change_scene_to_file("res://scenes/ui/skill_selection.tscn")

func _on_leaderboard_pressed():
	print("Leaderboard pressed")

func _on_logout_pressed():
	# Simple logout: go back to login scene
	get_tree().change_scene_to_file("res://scenes/ui/login_scene.tscn")
