extends Node2D

var sentences = []
var target_sentence = ""
var current_index = 0
var typed_statuses = []

var sentence_start_time = 0.0
var is_typing = false
var typos_count = 0
var total_keystrokes = 0

var p1
var p2

@onready var typing_label = $HUD/TypingText
@onready var skill_select = $HUD/SkillSelect
@onready var countdown_label = $HUD/CountdownText
@onready var stats_label = $HUD/TypingStats
@onready var accuracy_warning = $HUD/AccuracyWarning

func _ready():
	_spawn_players()
	randomize()
	
	skill_select.hide()
	countdown_label.hide()
	typing_label.show()
	if accuracy_warning:
		accuracy_warning.hide()
		
	if has_node("HUD/SkillSelect/HBoxContainer/Skill1"):
		$HUD/SkillSelect/HBoxContainer/Skill1.pressed.connect(_on_skill_pressed.bind(1))
	if has_node("HUD/SkillSelect/HBoxContainer/Skill2"):
		$HUD/SkillSelect/HBoxContainer/Skill2.pressed.connect(_on_skill_pressed.bind(2))
		
	load_sentences()
	pick_random_sentence()

func _spawn_players():
	var p1_scene = load("res://scenes/entities/riven/riven_sprite.tscn")
	if p1_scene:
		p1 = p1_scene.instantiate()
		if has_node("TileMap/P1"):
			$TileMap/P1.add_child(p1)
			p1.position = Vector2.ZERO
		else:
			p1.position = Vector2(300, 480)
			add_child(p1)
		
	var p2_scene = load("res://scenes/entities/player2.tscn")
	if p2_scene:
		p2 = p2_scene.instantiate()
		if has_node("TileMap/P2"):
			$TileMap/P2.add_child(p2)
			p2.position = Vector2.ZERO
		else:
			p2.position = Vector2(850, 480)
			add_child(p2)

func load_sentences():
	var path = "c:/Users/LENOVO/Documents/type-duel/server/data/sentences.json"
	var file = FileAccess.open(path, FileAccess.READ)
	if file:
		var text = file.get_as_text()
		var json = JSON.parse_string(text)
		if json is Array:
			for item in json:
				if item.has("text"):
					sentences.append(item["text"])
		file.close()
	
	if sentences.is_empty():
		sentences.append("The quick brown fox jumps over the lazy dog.")
		sentences.append("Type this sentence to practice your skills.")

func pick_random_sentence():
	if sentences.size() > 0:
		target_sentence = sentences[randi() % sentences.size()]
	current_index = 0
	typed_statuses.clear()
	is_typing = false
	typos_count = 0
	total_keystrokes = 0
	if stats_label:
		stats_label.text = "WPM: 0 | Typos: 0 | Accuracy: 100%"
	update_typing_ui()

func _process(delta):
	if is_typing and sentence_start_time > 0:
		var time_elapsed_min = (Time.get_ticks_msec() - sentence_start_time) / 60000.0
		var words = current_index / 5.0
		var wpm = int(words / time_elapsed_min) if time_elapsed_min > 0 else 0
		
		var accuracy = 100.0
		if total_keystrokes > 0:
			accuracy = (float(total_keystrokes - typos_count) / float(total_keystrokes)) * 100.0
			
		if stats_label:
			stats_label.text = "WPM: %d | Typos: %d | Accuracy: %.1f%%" % [wpm, typos_count, accuracy]

func update_typing_ui():
	if accuracy_warning:
		accuracy_warning.hide()
		
	var bbcode = "[center]"
	for i in range(current_index):
		var color = "green" if typed_statuses[i] else "red"
		bbcode += "[color=" + color + "]" + target_sentence[i] + "[/color]"
		
	if current_index < target_sentence.length():
		bbcode += "[color=yellow][u]" + target_sentence[current_index] + "[/u][/color]"
		if current_index + 1 < target_sentence.length():
			bbcode += "[color=white]" + target_sentence.substr(current_index + 1) + "[/color]"
			
	bbcode += "[/center]"
	typing_label.text = bbcode

func _unhandled_input(event):
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_BACKSPACE:
			if current_index > 0:
				current_index -= 1
				typed_statuses.pop_back()
				update_typing_ui()
			return
			
		if not event.echo and event.unicode != 0:
			if not is_typing:
				is_typing = true
				sentence_start_time = Time.get_ticks_msec()
				
			var char_typed = char(event.unicode)
			if char_typed.length() > 0 and current_index < target_sentence.length():
				var expected_char = target_sentence[current_index]
				var is_correct = (char_typed == expected_char)
				
				total_keystrokes += 1
				if not is_correct:
					typos_count += 1
				
				typed_statuses.append(is_correct)
				current_index += 1
				update_typing_ui()
				
				if current_index >= target_sentence.length():
					var accuracy = 100.0
					if total_keystrokes > 0:
						accuracy = (float(total_keystrokes - typos_count) / float(total_keystrokes)) * 100.0
						
					if accuracy < 60.0:
						if accuracy_warning:
							accuracy_warning.show()
					else:
						_on_sentence_completed()

func _on_sentence_completed():
	var time_elapsed_min = (Time.get_ticks_msec() - sentence_start_time) / 60000.0
	var words = target_sentence.length() / 5.0
	var wpm = int(words / time_elapsed_min) if time_elapsed_min > 0 else 0
	
	var accuracy = 100.0
	if total_keystrokes > 0:
		accuracy = (float(total_keystrokes - typos_count) / float(total_keystrokes)) * 100.0
		
	print("--- Sentence Completed ---")
	print("WPM: ", wpm)
	print("Typos: ", typos_count)
	print("Accuracy: ", ("%.1f" % accuracy) + "%")
	print("--------------------------")
	
	typing_label.hide()
	skill_select.show()

func _on_skill_pressed(skill_index: int):
	skill_select.hide()
	
	print("Skill ", skill_index, " clicked!")
	print("Waiting for animation...")
	
	# Trigger attack animation
	if p1 and p1.has_node("AnimationPlayer"):
		# Using quickstrike for both skills right now, can be changed later based on skill_index
		p1.get_node("AnimationPlayer").play("quickstrike")
		
	# Wait 2 seconds for the animation to play out
	await get_tree().create_timer(2.0).timeout
		
	# Start countdown
	_start_countdown()

func _start_countdown():
	countdown_label.show()
	
	for i in range(3, 0, -1):
		countdown_label.text = str(i)
		await get_tree().create_timer(1.0).timeout
		
	countdown_label.hide()
	typing_label.show()
	pick_random_sentence()
