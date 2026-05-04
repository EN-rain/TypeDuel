extends Node2D

var sentences = []
var target_sentence = ""
var current_index = 0
var typed_statuses = []

var sentence_start_time = 0.0
var is_typing = false
var typos_count = 0
var total_keystrokes = 0

enum GameState { SKILL_SELECT, TYPING }
var current_state = GameState.SKILL_SELECT
var skill_timer: float = 10.0
var chosen_skill_index: int = 1
var chosen_skill_id: String = ""
var enemy_typing_progress: float = 0.0
var typos_in_current_word: int = 0

var p1
var p2

@onready var typing_label = $HUD/TypingText
@onready var skill_select = $HUD/SkillSelect
@onready var countdown_label = $HUD/CountdownText
@onready var stats_label = $HUD/TypingStats
@onready var accuracy_warning = $HUD/AccuracyWarning
@onready var own_progress_bar  = $HUD/OwnProgress
@onready var enemy_progress_bar = $HUD/EnemyProgress

var SERVER: String:
	get: return GameManager.SERVER_URL
var last_progress_sync: float = 0.0
var last_poll_time: float     = 0.0

func _ready():
	HPManager.init_game()
	SkillsManager.reset_round_state()
	_spawn_players()
	if not GameManager.is_solo and GameManager.current_room != "":
		seed(GameManager.current_room.hash())
	else:
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
		
	HPManager.entity_died.connect(_on_entity_died)
		
	load_sentences()
	start_skill_phase()

func _on_entity_died(entity: String):
	if current_state == GameState.TYPING or current_state == GameState.SKILL_SELECT:
		# Game Over
		current_state = GameState.SKILL_SELECT # prevent input
		
		var victory_scene = load("res://scenes/ui/victory_screen.tscn").instantiate()
		$HUD.add_child(victory_scene)
		
		# If opponent died, we win. If player died, we lose.
		var won = (entity == "opponent")
		_save_match_history(won)
		victory_scene.set_result(won)

func start_skill_phase():
	current_state = GameState.SKILL_SELECT
	skill_timer = 10.0
	chosen_skill_index = 1
	chosen_skill_id = ""
	
	if SkillsManager.selected_skills.size() > 0:
		chosen_skill_id = SkillsManager.selected_skills[0]
		if has_node("HUD/SkillSelect/HBoxContainer/Skill1"):
			$HUD/SkillSelect/HBoxContainer/Skill1.text = SkillsManager.selected_skills[0].capitalize()
	if SkillsManager.selected_skills.size() > 1:
		if has_node("HUD/SkillSelect/HBoxContainer/Skill2"):
			$HUD/SkillSelect/HBoxContainer/Skill2.text = SkillsManager.selected_skills[1].capitalize()
			
	skill_select.show()
	countdown_label.show()
	typing_label.hide()

func start_typing_phase():
	current_state = GameState.TYPING
	skill_select.hide()
	countdown_label.hide()
	pick_random_sentence()
	typing_label.show()

func _spawn_players():
	var p1_scene = load("res://scenes/entities/riven/riven_sprite.tscn")
	if p1_scene:
		p1 = p1_scene.instantiate()
		if has_node("TileMap/P1"):
			$TileMap/P1.add_child(p1)
			p1.position = Vector2.ZERO
		else:
			p1.position = Vector2(300, 300)
			add_child(p1)
		
	var p2_scene = load("res://scenes/entities/player2.tscn")
	if p2_scene:
		p2 = p2_scene.instantiate()
		if has_node("TileMap/P2"):
			$TileMap/P2.add_child(p2)
			p2.position = Vector2.ZERO
		else:
			p2.position = Vector2(850, 300)
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
	typos_in_current_word = 0
	total_keystrokes = 0
	if stats_label:
		stats_label.text = "WPM: 0 | Typos: 0 | Accuracy: 100% | Mana: %d" % SkillsManager.player_mana
	update_typing_ui()

func _process(delta):
	if current_state == GameState.SKILL_SELECT:
		skill_timer -= delta
		if countdown_label:
			countdown_label.text = "Choose Skill: %d" % max(0, int(ceil(skill_timer)))
		if skill_timer <= 0:
			start_typing_phase()
			
	elif current_state == GameState.TYPING:
		var time_elapsed_min = 0.0
		if is_typing and sentence_start_time > 0:
			time_elapsed_min = (Time.get_ticks_msec() - sentence_start_time) / 60000.0
		var words = current_index / 5.0
		var wpm = int(words / time_elapsed_min) if time_elapsed_min > 0 else 0
		
		var accuracy = 100.0
		if total_keystrokes > 0:
			accuracy = (float(total_keystrokes - typos_count) / float(total_keystrokes)) * 100.0
			
		if stats_label:
			stats_label.text = "WPM: %d | Typos: %d | Accuracy: %.1f%% | Mana: %d" % [wpm, typos_count, accuracy, SkillsManager.player_mana]
	
	# Update visual progress lines to show HP
	own_progress_bar.max_value = HPManager.player_max_hp
	own_progress_bar.value = HPManager.player_hp
	enemy_progress_bar.max_value = HPManager.opponent_max_hp
	enemy_progress_bar.value = HPManager.opponent_hp
	
	# Networking sync
	var now = Time.get_ticks_msec() / 1000.0
	if now - last_progress_sync > 0.3:
		last_progress_sync = now
		_sync_progress_to_server()
	
	if now - last_poll_time > 1.0:
		last_poll_time = now
		_poll_opponent_progress()

func _sync_progress_to_server():
	if GameManager.current_room == "" or GameManager.user_data.id == 0: return
	var prog = 0.0
	if target_sentence.length() > 0:
		prog = float(current_index) / float(target_sentence.length())
	
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r,_c,_h,_b): http.queue_free())
	var body = JSON.stringify({
		"user_id": GameManager.user_data.id,
		"progress": prog,
		"typos": typos_count
	})
	http.request(SERVER + "/api/rooms/" + GameManager.current_room + "/progress", GameManager.get_auth_headers(), HTTPClient.METHOD_PATCH, body)

func _poll_opponent_progress():
	if GameManager.current_room == "": return
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_poll_progress_done.bind(http))
	http.request(SERVER + "/api/rooms/" + GameManager.current_room, GameManager.get_auth_headers())

func _on_poll_progress_done(_result, _code, _headers, body, http):
	http.queue_free()
	var json = JSON.parse_string(body.get_string_from_utf8())
	if json:
		var opp_prog = 0.0
		var opp_typos = 0
		if GameManager.is_host:
			opp_prog = json.get("guest_progress", 0.0)
			opp_typos = json.get("guest_typos", 0)
		else:
			opp_prog = json.get("host_progress", 0.0)
			opp_typos = json.get("host_typos", 0)
		
		enemy_typing_progress = opp_prog * 100.0
		
		# Save opp_typos temporarily so we can pass it to resolve_round
		set_meta("opp_typos", opp_typos)
		
		if not GameManager.is_solo and enemy_typing_progress >= 100.0:
			if current_state == GameState.TYPING:
				typing_label.hide()
				_on_sentence_completed()

@export var correct_color: Color = Color.GREEN
@export var wrong_color: Color = Color.RED
@export var current_char_color: Color = Color.YELLOW
@export var upcoming_color: Color = Color.WHITE

func update_typing_ui():
	if accuracy_warning:
		accuracy_warning.hide()
		
	var c_hex = "#" + correct_color.to_html(false)
	var w_hex = "#" + wrong_color.to_html(false)
	var cur_hex = "#" + current_char_color.to_html(false)
	var up_hex = "#" + upcoming_color.to_html(false)
		
	var bbcode = "[center]"
	for i in range(current_index):
		var color = c_hex if typed_statuses[i] else w_hex
		bbcode += "[color=" + color + "]" + target_sentence[i] + "[/color]"
		
	if current_index < target_sentence.length():
		bbcode += "[color=" + cur_hex + "][u]" + target_sentence[current_index] + "[/u][/color]"
		if current_index + 1 < target_sentence.length():
			bbcode += "[color=" + up_hex + "]" + target_sentence.substr(current_index + 1) + "[/color]"
			
	bbcode += "[/center]"
	typing_label.text = bbcode

func _unhandled_input(event):
	if current_state != GameState.TYPING: return
	
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
					typos_in_current_word += 1
					
				if expected_char == " ":
					if typos_in_current_word == 0:
						SkillsManager.player_mana = min(10, SkillsManager.player_mana + 1)
					typos_in_current_word = 0
				
				typed_statuses.append(is_correct)
				current_index += 1
				update_typing_ui()
				
				if current_index >= target_sentence.length():
					if typos_in_current_word == 0:
						SkillsManager.player_mana = min(10, SkillsManager.player_mana + 1)
						
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
	
	# Determine if we won the round
	var won = (current_index >= target_sentence.length())
	
	# Execute round combat logic
	var result = SkillsManager.resolve_round(
		float(wpm), accuracy, typos_count,
		get_meta("opp_typos", 0), # now synchronized!
		won, HPManager.opponent_hp, HPManager.player_hp,
		chosen_skill_id
	)
	
	# Apply damage and healing locally
	if result.player_hp_delta != 0:
		HPManager.heal("player", result.player_hp_delta)
	if result.opp_hp_delta != 0:
		HPManager.heal("opponent", result.opp_hp_delta)
		
	# Deal the attack damage
	if result.player_damage > 0:
		HPManager.take_damage("opponent", result.player_damage)
	if result.opp_damage > 0:
		HPManager.take_damage("player", result.opp_damage)
		
	for line in result.log:
		print("[Combat] ", line)
	
	typing_label.hide()
	
	print("Executing Skill ", chosen_skill_index)
	print("Waiting for animation...")
	
	if p1 and p1.has_node("AnimationPlayer"):
		p1.get_node("AnimationPlayer").play("quickstrike")
		
	await get_tree().create_timer(2.0).timeout
	
	if p1 and p1.has_node("AnimationPlayer"):
		var anim = p1.get_node("AnimationPlayer")
		anim.stop()
		anim.seek(0, true)
		if p1.has_node("Sprite2D"):
			p1.get_node("Sprite2D").texture = load("res://assets/sprites/riven/riven-quickstrike1.png")
		
	start_skill_phase()

func _on_skill_pressed(skill_index: int):
	if skill_index - 1 < SkillsManager.selected_skills.size():
		chosen_skill_index = skill_index
		chosen_skill_id = SkillsManager.selected_skills[skill_index - 1]
		print("Selected skill: ", chosen_skill_id)
	skill_select.hide()

func _save_match_history(won: bool):
	var wpm = 0.0
	var accuracy = 0.0
	# we just use some simple stats for now, or total average if possible.
	if total_keystrokes > 0:
		accuracy = (float(total_keystrokes - typos_count) / float(total_keystrokes)) * 100.0
	
	var time_elapsed_min = (Time.get_ticks_msec() - sentence_start_time) / 60000.0
	if time_elapsed_min > 0:
		wpm = (total_keystrokes / 5.0) / time_elapsed_min

	var req = HTTPRequest.new()
	add_child(req)
	
	var data = {
		"user_id": GameManager.user_data.id,
		"username": GameManager.user_data.username,
		"match_type": "online" if not GameManager.is_solo else "custom",
		"wpm": wpm,
		"accuracy": accuracy,
		"typos": typos_count,
		"won": won
	}
	
	var headers = ["Content-Type: application/json"]
	req.request(SERVER + "/api/game/history", headers, HTTPClient.METHOD_POST, JSON.stringify(data))
