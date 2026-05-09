extends Control

@onready var skill_container = $HBoxContainer

func _ready():
	_update_button_visuals()
	
	# If we are guest, we should probably wait for host to start
	# but for now, let's keep it simple.
	if not GameManager.is_host:
		$StartButton.hide()
		$Title.text = "Wait for Host..."

func _on_back_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/lobby/custom_room.tscn")

func _on_skill_pressed(skill_name: String):
	SkillsManager.toggle_skill(skill_name)
	_update_button_visuals()

func _on_start_game_pressed():
	if SkillsManager.selected_skills.size() == 0:
		print("[SkillSelection] Select at least one skill!")
		return
		
	# In a real networked game, host would send a 'start' signal to the guest.
	# For now, let's just transition.
	get_tree().change_scene_to_file("res://scenes/game/game.tscn")

func _update_button_visuals():
	for child in skill_container.get_children():
		if child is Button:
			var skill_id = child.name.to_snake_case()
			if SkillsManager.selected_skills.has(skill_id):
				child.add_theme_color_override("font_color", Color.GREEN)
				child.text = child.name.capitalize() + "\n(Equipped)"
			else:
				child.remove_theme_color_override("font_color")
				child.text = child.name.capitalize()
