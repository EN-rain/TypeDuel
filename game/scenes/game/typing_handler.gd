extends Node

## TypingHandler
## Owns sentence state, keyboard input processing, mutation application,
## and the typing UI label. Attach to "TypingHandler" under the Game scene root.

signal word_completed_accurately(wpm: float)
signal sentence_finished
signal accuracy_too_low

@export var correct_color:      Color = Color.GREEN
@export var wrong_color:        Color = Color.RED
@export var current_char_color: Color = Color.YELLOW
@export var upcoming_color:     Color = Color.WHITE

# Sentence state
var sentences: Array         = []
var target_sentence: String  = ""
var current_index: int       = 0
var typed_statuses: Array    = []

# Typing stats
var is_typing: bool          = false
var sentence_start_time: float = 0.0
var typos_count: int         = 0
var total_keystrokes: int    = 0
var typos_in_current_word: int = 0
var _perfect_words_streak: int = 0

# Queued mutations to send to opponent
var queued_mutations: Array  = []

# UI nodes — set by Game after scene is ready
var typing_label: RichTextLabel = null
var accuracy_warning: Label     = null

# ─────────────────────────────────────────────
#  Sentence loading
# ─────────────────────────────────────────────

func load_sentences() -> void:
	var path = "res://assets/data/sentences.json"
	var file = FileAccess.open(path, FileAccess.READ)
	if file:
		var json = JSON.parse_string(file.get_as_text())
		if json is Array:
			for item in json:
				if item.has("text"): sentences.append(item["text"])
		file.close()
	if sentences.is_empty():
		sentences.append("The quick brown fox jumps over the lazy dog.")
		sentences.append("Type this sentence to practice your skills.")

func pick_sentence(room_code: String, round_num: int) -> void:
	if room_code != "":
		seed(room_code.hash() + int(round_num))
	if sentences.size() > 0:
		target_sentence = sentences[randi() % sentences.size()]
	_reset_typing_state()

func _reset_typing_state() -> void:
	current_index          = 0
	typed_statuses.clear()
	is_typing              = false
	sentence_start_time    = 0.0
	typos_count            = 0
	total_keystrokes       = 0
	typos_in_current_word  = 0
	_perfect_words_streak  = 0
	queued_mutations.clear()
	set_meta("jumble_triggered_this_round", false)
	if accuracy_warning: accuracy_warning.hide()
	update_ui()

# ─────────────────────────────────────────────
#  Stats helpers
# ─────────────────────────────────────────────

func get_wpm() -> int:
	if not is_typing or sentence_start_time <= 0: return 0
	var elapsed_min = (Time.get_ticks_msec() - sentence_start_time) / 60000.0
	if elapsed_min <= 0: return 0
	return int((float(current_index) / 5.0) / elapsed_min)

func get_accuracy() -> float:
	if total_keystrokes <= 0: return 100.0
	return (float(total_keystrokes - typos_count) / float(total_keystrokes)) * 100.0

func get_progress() -> float:
	if target_sentence.length() == 0: return 0.0
	return float(current_index) / float(target_sentence.length())

# ─────────────────────────────────────────────
#  Input processing
# ─────────────────────────────────────────────

func handle_key(event: InputEventKey, can_type: bool) -> void:
	if not event.pressed: return

	if event.keycode == KEY_BACKSPACE:
		_handle_backspace()
		return

	if not can_type: return
	if event.echo or event.unicode == 0: return

	if not is_typing:
		is_typing = true
		sentence_start_time = Time.get_ticks_msec()

	var char_typed = char(event.unicode)
	if char_typed.length() == 0 or current_index >= target_sentence.length(): return

	var expected = target_sentence[current_index]
	var is_correct = (char_typed == expected)

	total_keystrokes += 1
	if not is_correct:
		typos_count += 1
		typos_in_current_word += 1

	if expected == " ":
		_on_word_boundary()

	typed_statuses.append(is_correct)
	current_index += 1
	update_ui()

	if current_index >= target_sentence.length():
		_check_sentence_complete()

func _handle_backspace() -> void:
	if current_index <= 0: return
	var was_typo = typed_statuses.size() > 0 and not typed_statuses.back()
	if was_typo:
		typos_in_current_word = max(0, typos_in_current_word - 1)
		typos_count           = max(0, typos_count - 1)
		total_keystrokes      = max(0, total_keystrokes - 1)
	else:
		total_keystrokes = max(0, total_keystrokes - 1)
	current_index -= 1
	typed_statuses.pop_back()
	update_ui()

func _on_word_boundary() -> void:
	if typos_in_current_word == 0:
		var cur_wpm = 0.0
		var elapsed_min = (Time.get_ticks_msec() - sentence_start_time) / 60000.0
		if elapsed_min > 0:
			cur_wpm = (float(current_index) / 5.0) / elapsed_min
		SkillsManager.on_accurate_word(cur_wpm)
		word_completed_accurately.emit(cur_wpm)

		_perfect_words_streak += 1
		if SkillsManager.selected_passive == "erosion" and _perfect_words_streak % 3 == 0:
			queued_mutations.append({ "type": "erosion" })

	typos_in_current_word = 0

	if has_meta("stutter_effect2_pending") and bool(get_meta("stutter_effect2_pending")):
		set_meta("stutter_effect2_pending", false)
		apply_mutation({ "type": "stutter_effect2" })

	var jumble_done = has_meta("jumble_triggered_this_round") and bool(get_meta("jumble_triggered_this_round"))
	if SkillsManager.selected_passive == "jumble" and SkillsManager.player_mana >= 7 and not jumble_done:
		set_meta("jumble_triggered_this_round", true)
		queued_mutations.append({ "type": "jumble" })

func _check_sentence_complete() -> void:
	if typos_in_current_word == 0:
		var elapsed_min = (Time.get_ticks_msec() - sentence_start_time) / 60000.0
		var cur_wpm = (float(current_index) / 5.0) / elapsed_min if elapsed_min > 0 else 0.0
		SkillsManager.on_accurate_word(cur_wpm)

	var correct_letters = total_keystrokes - typos_count
	var required = int(ceil(float(target_sentence.length()) * 0.6))
	if correct_letters < required:
		if accuracy_warning: accuracy_warning.show()
		accuracy_too_low.emit()
	else:
		sentence_finished.emit()

# ─────────────────────────────────────────────
#  Mutations
# ─────────────────────────────────────────────

func apply_mutation(mut: Dictionary) -> void:
	if not GameManager.is_solo and GameManager.current_room != "":
		seed(GameManager.current_room.hash() + int(get_parent().current_round) + str(mut.get("type")).hash())

	var type = mut.get("type", "")

	if type == "stutter_effect2":
		var prev_space = target_sentence.rfind(" ", current_index - 2)
		var start_idx = prev_space + 1 if prev_space != -1 else 0
		var word_just_typed = target_sentence.substr(start_idx, current_index - start_idx).strip_edges()
		if word_just_typed.length() > 0:
			target_sentence = target_sentence.substr(0, current_index) + " " + word_just_typed + target_sentence.substr(current_index)
			update_ui()
		return

	var remaining = target_sentence.substr(current_index)
	var first_space = remaining.find(" ")
	if first_space == -1: return

	var unstarted = remaining.substr(first_space + 1)
	var words = unstarted.split(" ", false)
	if words.size() == 0: return

	match type:
		"jumble":
			words.shuffle()
		"erosion":
			var w_idx = randi() % words.size()
			var w = words[w_idx]
			if w.length() > 0:
				var c_idx = randi() % w.length()
				words[w_idx] = w.substr(0, c_idx) + "_" + w.substr(c_idx + 1)
		"stutter":
			var w_idx = randi() % words.size()
			words[w_idx] = words[w_idx] + " " + words[w_idx]
			set_meta("stutter_effect2_pending", true)
			set_meta("passive_highlight_word", words[w_idx].split(" ")[0])
		"reversal":
			var full = " ".join(words)
			var rev = ""
			for i in range(full.length() - 1, -1, -1):
				rev += full[i]
			words = [rev]
		"phantom":
			if words.size() >= 2:
				var i1 = randi() % words.size()
				var i2 = randi() % words.size()
				var tmp = words[i1]; words[i1] = words[i2]; words[i2] = tmp

	target_sentence = target_sentence.substr(0, current_index + first_space + 1) + " ".join(words)
	update_ui()

func pop_queued_mutation():
	if queued_mutations.size() > 0:
		return queued_mutations.pop_front()
	return null

# ─────────────────────────────────────────────
#  UI
# ─────────────────────────────────────────────

func update_ui() -> void:
	if accuracy_warning: accuracy_warning.hide()
	if typing_label == null: return

	var c_hex   = "#" + correct_color.to_html(false)
	var w_hex   = "#" + wrong_color.to_html(false)
	var cur_hex = "#" + current_char_color.to_html(false)
	var up_hex  = "#" + upcoming_color.to_html(false)

	var highlight_word: String = ""
	if has_meta("passive_highlight_word"):
		highlight_word = str(get_meta("passive_highlight_word"))
	var highlight_hex = "#ffcc00"

	var bbcode = "[center]"
	for i in range(current_index):
		var color = c_hex if typed_statuses[i] else w_hex
		bbcode += "[color=" + color + "]" + target_sentence[i] + "[/color]"

	if current_index < target_sentence.length():
		bbcode += "[color=" + cur_hex + "][u]" + target_sentence[current_index] + "[/u][/color]"
		if current_index + 1 < target_sentence.length():
			var upcoming = target_sentence.substr(current_index + 1)
			if highlight_word != "":
				upcoming = upcoming.replace(" " + highlight_word + " ",
					" [color=" + highlight_hex + "]" + highlight_word + "[/color] ")
			bbcode += "[color=" + up_hex + "]" + upcoming + "[/color]"

	bbcode += "[/center]"
	typing_label.text = bbcode
