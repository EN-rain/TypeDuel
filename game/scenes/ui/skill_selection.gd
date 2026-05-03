extends Control
@onready var char_btn_1 = $VBoxContainer/Character1
@onready var char_btn_2 = $VBoxContainer/Character2
@onready var char_btn_3 = $VBoxContainer/Character3

@onready var skill_btns = {
	"quick_strike": $HBoxContainer/QuickStrike,
	"drain_touch": $HBoxContainer/DrainTouch,
	"whiplash": $HBoxContainer/Whiplash,
	"soulbreak": $HBoxContainer/Soulbreak,
	"rupture": $HBoxContainer/Rupture,
	"deathmark": $HBoxContainer/Deathmark
}

func _ready():
	char_btn_1.text = "Riven"
	char_btn_2.text = "Zephon"
	char_btn_3.text = "Liora"
	
	char_btn_1.pressed.connect(_on_char_selected.bind("Riven"))
	char_btn_2.pressed.connect(_on_char_selected.bind("Zephon"))
	char_btn_3.pressed.connect(_on_char_selected.bind("Liora"))
	
	_update_ui()

func _on_char_selected(char_name: String):
	GameManager.selected_character = char_name
	print("Character selected: ", char_name)
	_update_ui()

func _on_skill_pressed(skill_name: String):
	print("Skill toggled: ", skill_name)
	
	var sm = get_node_or_null("/root/SkillsManager")
	if sm:
		sm.toggle_skill(skill_name)
	else:
		push_error("SkillsManager not found in /root!")
	
	_update_ui()

func _update_ui():
	# Characters
	char_btn_1.modulate = Color.GREEN if GameManager.selected_character == "Riven" else Color.WHITE
	char_btn_2.modulate = Color.GREEN if GameManager.selected_character == "Zephon" else Color.WHITE
	char_btn_3.modulate = Color.GREEN if GameManager.selected_character == "Liora" else Color.WHITE
	
	# Skills
	var sm = get_node_or_null("/root/SkillsManager")
	if sm:
		for id in skill_btns:
			if sm.selected_skills.has(id):
				skill_btns[id].modulate = Color.CYAN
			else:
				skill_btns[id].modulate = Color.WHITE

func _on_start_game_pressed():
	get_tree().change_scene_to_file("res://scenes/game/game.tscn")

func _on_back_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
