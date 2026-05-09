extends Control

@onready var status_label   = $TitleContainer/StatusLabel
@onready var player1_name   = $CenterContainer/VBoxContainer/PlayerSlots/Player1Slot/Player1Name
@onready var player2_name   = $CenterContainer/VBoxContainer/PlayerSlots/Player2Slot/Player2Name
@onready var player2_status = $CenterContainer/VBoxContainer/PlayerSlots/Player2Slot/Player2Status
@onready var timer_label    = $TitleContainer/TimerLabel

var _dot_count: int = 0
var _search_timer: float = 0.0
var _total_search_time: float = 0.0

func _ready():
	var my_name = GameManager.user_data.display_name
	if my_name == "":
		my_name = GameManager.user_data.username
	player1_name.text = my_name

func _process(delta: float):
	# Animate the "Searching..." dots
	_search_timer += delta
	_total_search_time += delta
	if _search_timer >= 0.5:
		_search_timer = 0.0
		_dot_count = (_dot_count + 1) % 4
		status_label.text = "Searching for a match" + ".".repeat(_dot_count)
	
	# Update visible timer
	var minutes = int(_total_search_time / 60.0)
	var seconds = int(_total_search_time) % 60
	timer_label.text = "Time: %d:%02d" % [minutes, seconds]

func _on_back_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/menus/main_menu.tscn")
