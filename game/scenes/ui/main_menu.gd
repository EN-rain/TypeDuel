extends Control

@onready var greeting_label = $Greeting

func _ready():
	# Update greeting with display_name or username
	var name_to_show = GameManager.user_data.display_name
	if name_to_show == "":
		name_to_show = GameManager.user_data.username
	
	greeting_label.text = "Hi, " + name_to_show + "!"

func _on_play_pressed():
	print("Play pressed - Transitioning to Skill Selection...")
	get_tree().change_scene_to_file("res://scenes/ui/skill_selection.tscn")

func _on_leaderboard_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/leaderboard.tscn")

func _on_settings_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/settings.tscn")

func _on_logout_pressed():
	# Clear session
	GameManager.user_data = {
		"id": 0,
		"username": "",
		"display_name": "",
		"token": ""
	}
	get_tree().change_scene_to_file("res://scenes/ui/login_scene.tscn")
