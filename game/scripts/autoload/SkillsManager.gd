extends Node

## Skills Manager Singleton
## Tracks player skills and cooldowns

signal skill_activated(skill_name: String)
signal skill_cooldown_finished(skill_name: String)

var active_skills = []

func activate_skill(skill_name: String):
	print("Skill activated: ", skill_name)
	active_skills.append(skill_name)
	skill_activated.emit(skill_name)

func get_active_skills():
	return active_skills
