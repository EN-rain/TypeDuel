extends Control

func _on_play_pressed():
	print("Play pressed - Transitioning to Game...")
	# Replace with your actual game scene path
	# get_tree().change_scene_to_file("res://game/scenes/main_game.tscn")

func _on_leaderboard_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/leaderboard.tscn")

func _on_logout_pressed():
	# Simple logout: go back to login scene
	get_tree().change_scene_to_file("res://scenes/ui/login_scene.tscn")
