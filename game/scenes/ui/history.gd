extends Control

@onready var list = $VBoxContainer/ScrollContainer/List
@onready var stats_label = $VBoxContainer/StatsLabel
@onready var http_request = $HTTPRequest

var BASE_URL: String:
	get: 
		var target_id = GameManager.user_data.id
		if "viewing_history_id" in GameManager and GameManager.viewing_history_id != 0:
			target_id = GameManager.viewing_history_id
		return GameManager.SERVER_URL + "/api/game/history/" + str(target_id)

func _ready():
	http_request.request_completed.connect(_on_request_completed)
	fetch_history()

func fetch_history():
	http_request.request(BASE_URL, GameManager.get_auth_headers())
	GameManager.viewing_history_id = 0 # Reset after fetching

func _on_request_completed(result, response_code, headers, body):
	if response_code != 200:
		print("Failed to fetch history")
		return
		
	var data = JSON.parse_string(body.get_string_from_utf8())
	if data == null: return
	
	# Populate overall stats
	var stats = data.stats
	stats_label.text = "Matches: %d  |  Wins: %d  |  Avg WPM: %.1f  |  Avg Acc: %.1f%%" % [
		stats.total_matches,
		stats.total_wins,
		stats.avg_wpm,
		stats.avg_accuracy
	]
	
	# Clear existing list
	for child in list.get_children():
		child.queue_free()
		
	# Populate list
	for match in data.history:
		var row = HBoxContainer.new()
		row.add_theme_constant_override("separation", 20)
		
		var type_lbl = Label.new()
		type_lbl.custom_minimum_size = Vector2(80, 0)
		type_lbl.text = match.match_type.capitalize()
		
		var res_lbl = Label.new()
		res_lbl.custom_minimum_size = Vector2(60, 0)
		res_lbl.text = "WIN" if match.won else "LOSS"
		if match.won: res_lbl.add_theme_color_override("font_color", Color.GREEN)
		else: res_lbl.add_theme_color_override("font_color", Color.RED)
		
		var wpm_lbl = Label.new()
		wpm_lbl.custom_minimum_size = Vector2(60, 0)
		wpm_lbl.text = "%.1f WPM" % match.wpm
		
		var acc_lbl = Label.new()
		acc_lbl.custom_minimum_size = Vector2(60, 0)
		acc_lbl.text = "%.1f%%" % match.accuracy
		
		var typo_lbl = Label.new()
		typo_lbl.custom_minimum_size = Vector2(80, 0)
		typo_lbl.text = "%d Typos" % match.typos
		
		var date_lbl = Label.new()
		date_lbl.custom_minimum_size = Vector2(120, 0)
		date_lbl.text = match.created_at.split(" ")[0].split("T")[0] # Simple date formatting
		
		row.add_child(type_lbl)
		row.add_child(res_lbl)
		row.add_child(wpm_lbl)
		row.add_child(acc_lbl)
		row.add_child(typo_lbl)
		row.add_child(date_lbl)
		
		list.add_child(row)

func _on_back_button_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
