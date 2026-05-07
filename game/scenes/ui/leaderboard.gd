extends Control

@onready var list = $VBoxContainer/ScrollContainer/List
@onready var http_request = $HTTPRequest

var BASE_URL: String:
	get: return GameManager.SERVER_URL + "/api/game/leaderboard"

func _ready():
	# Fade in UI content only
	$VBoxContainer.modulate.a = 0.0
	$Scroll.modulate.a = 0.0
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property($VBoxContainer, "modulate:a", 1.0, 0.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property($Scroll, "modulate:a", 1.0, 0.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

	http_request.request_completed.connect(_on_request_completed)
	fetch_leaderboard()

func fetch_leaderboard():
	http_request.request(BASE_URL, GameManager.get_auth_headers())

func _on_request_completed(result, response_code, headers, body):
	if response_code != 200:
		var body_str = body.get_string_from_utf8()
		print("Failed to fetch leaderboard. Code: ", response_code)
		print("Response: ", body_str)
		return
		
	var data = JSON.parse_string(body.get_string_from_utf8())
	if data == null: return
	
	# Clear existing list
	for child in list.get_children():
		child.queue_free()
		
	# Populate list
	var font = load("res://assets/fonts/pixel_operator/PixelOperator-Bold.ttf")
	var rank = 1
	for entry in data:
		var row = HBoxContainer.new()
		row.add_theme_constant_override("separation", 40)
		
		var rank_lbl = Label.new()
		rank_lbl.custom_minimum_size = Vector2(50, 0)
		rank_lbl.text = str(rank)
		rank_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		rank_lbl.add_theme_font_override("font", font)
		rank_lbl.add_theme_font_size_override("font_size", 18)
		rank_lbl.add_theme_color_override("font_color", Color.WHITE)
		rank_lbl.add_theme_color_override("font_outline_color", Color.BLACK)
		rank_lbl.add_theme_constant_override("outline_size", 3)
		
		var name_lbl = Label.new()
		name_lbl.custom_minimum_size = Vector2(200, 0)
		name_lbl.text = entry.username
		name_lbl.add_theme_font_override("font", font)
		name_lbl.add_theme_font_size_override("font_size", 18)
		name_lbl.add_theme_color_override("font_color", Color.WHITE)
		name_lbl.add_theme_color_override("font_outline_color", Color.BLACK)
		name_lbl.add_theme_constant_override("outline_size", 3)
		
		var wins_lbl = Label.new()
		wins_lbl.custom_minimum_size = Vector2(80, 0)
		wins_lbl.text = str(entry.wins)
		wins_lbl.add_theme_font_override("font", font)
		wins_lbl.add_theme_font_size_override("font_size", 18)
		wins_lbl.add_theme_color_override("font_color", Color.WHITE)
		wins_lbl.add_theme_color_override("font_outline_color", Color.BLACK)
		wins_lbl.add_theme_constant_override("outline_size", 3)
		
		var wpm_lbl = Label.new()
		wpm_lbl.custom_minimum_size = Vector2(80, 0)
		wpm_lbl.text = str(snapped(entry.wpm, 0.1))
		wpm_lbl.add_theme_font_override("font", font)
		wpm_lbl.add_theme_font_size_override("font_size", 18)
		wpm_lbl.add_theme_color_override("font_color", Color.WHITE)
		wpm_lbl.add_theme_color_override("font_outline_color", Color.BLACK)
		wpm_lbl.add_theme_constant_override("outline_size", 3)
		
		row.add_child(rank_lbl)
		row.add_child(name_lbl)
		row.add_child(wins_lbl)
		row.add_child(wpm_lbl)
		
		list.add_child(row)
		rank += 1

func _on_back_button_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
