extends Control

func _on_skill_pressed(skill_name: String):
	print("Skill selected: ", skill_name)
	
	# Using get_node fallback in case the Autoload identifier isn't indexed yet
	var sm = get_node_or_null("/root/SkillsManager")
	if sm:
		sm.set_skill(skill_name)
	else:
		# Fallback if singleton is somehow not loaded
		push_error("SkillsManager not found in /root!")
		
	get_tree().change_scene_to_file("res://scenes/game/game.tscn")

func _on_back_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
