extends Node

## BotManager - Handles AI opponent logic for TypeDuel
## Manages bot difficulty calculation, typing simulation, and skill AI

signal bot_match_started(bot_data: Dictionary)
signal bot_typing_progress(progress: float, typos: int)
signal bot_skill_selected(skill_id: String)
signal bot_finished_typing()

# ─────────────────────────────────────────────
#  Bot Configuration Constants
# ─────────────────────────────────────────────

const PERSONALITIES = {
	"aggressive": {
		"wpm_multiplier": 1.2,
		"accuracy_base": 0.85,
		"skill_preference": ["quickslash", "soulbreak"],
		"risk_factor": 0.8,  # Higher = more likely to make mistakes
		"description": "Fast but reckless"
	},
	"defensive": {
		"wpm_multiplier": 0.85,
		"accuracy_base": 0.97,
		"skill_preference": ["whiplash"],
		"risk_factor": 0.3,  # Lower = fewer mistakes
		"description": "Slow but accurate"
	},
	"balanced": {
		"wpm_multiplier": 1.0,
		"accuracy_base": 0.92,
		"skill_preference": ["quickslash", "whiplash", "soulbreak"],
		"risk_factor": 0.5,  # Moderate risk
		"description": "Well-rounded"
	}
}

const BOT_NAMES = [
	"ShadowType", "PixelFury", "CodeBlade", "NeonStrike", "CyberWolf",
	"DigitalStorm", "ByteForce", "DataKnight", "LogicEdge", "VoidRunner",
	"FluxCaster", "GridWalker", "PulseFang", "RiftBlade", "CoreBreaker"
]

const BOT_AVATARS = [
	"bot_avatar_1.png", "bot_avatar_2.png", "bot_avatar_3.png",
	"bot_avatar_4.png", "bot_avatar_5.png"
]

# ─────────────────────────────────────────────
#  Bot State
# ─────────────────────────────────────────────

var current_bot: Dictionary = {}
var is_bot_active: bool = false
var player_wpm_history: Array = []
var bot_typing_start_time: float = 0.0
var bot_target_sentence: String = ""
var bot_current_progress: float = 0.0
var bot_typos: int = 0
var bot_typing_finished_internal: bool = false
var bot_finish_time: float = 0.0
var _typing_simulation_timer: float = 0.0

# ─────────────────────────────────────────────
#  Initialization
# ─────────────────────────────────────────────

func _ready():
	load_player_history()

func load_player_history():
	# TODO: Fetch from server API endpoint
	# For now, use empty array - will be populated on first match
	player_wpm_history = []
	print("[BotManager] Player history loaded: %d matches" % player_wpm_history.size())

func fetch_player_history_from_server():
	# Make HTTP request to fetch player's match history
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_history_fetched.bind(http))
	http.request(
		GameManager.SERVER_URL + "/api/game/history?limit=20",
		GameManager.get_auth_headers()
	)

func _on_history_fetched(result, code, _headers, body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()
	
	if code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json and json.has("matches"):
			player_wpm_history = json.matches
			print("[BotManager] Fetched %d matches from server" % player_wpm_history.size())

# ─────────────────────────────────────────────
#  Bot Creation & Configuration
# ─────────────────────────────────────────────

func create_bot_opponent() -> Dictionary:
	"""Create a new bot opponent based on player's historical performance"""
	
	# Calculate player's average WPM from history
	var avg_wpm = calculate_player_avg_wpm()
	if avg_wpm == 0:
		avg_wpm = 50  # Default if no history
	
	# Random timeout between 30-50 seconds
	var timeout_seconds = randf_range(30.0, 50.0)
	print("[BotManager] Bot will spawn after %.1f seconds if no human opponent found" % timeout_seconds)
	
	# Select random personality
	var personality_keys = PERSONALITIES.keys()
	var selected_personality = personality_keys[randi() % personality_keys.size()]
	
	# Calculate bot WPM based on player history and personality
	var bot_wpm = int(avg_wpm * PERSONALITIES[selected_personality]["wpm_multiplier"])
	bot_wpm = clamp(bot_wpm, 20, 150)  # Reasonable bounds
	
	# Select random bot name and avatar
	var bot_name = BOT_NAMES[randi() % BOT_NAMES.size()]
	var bot_avatar = BOT_AVATARS[randi() % BOT_AVATARS.size()]
	
	# Choose character, skills, and passive
	var character = select_bot_character(selected_personality)
	var skills = select_bot_skills(selected_personality)
	var passive = select_bot_passive(selected_personality)
	
	current_bot = {
		"name": bot_name,
		"avatar": bot_avatar,
		"personality": selected_personality,
		"wpm": bot_wpm,
		"accuracy": PERSONALITIES[selected_personality]["accuracy_base"],
		"character": character,
		"skills": skills,
		"passive": passive,
		"risk_factor": PERSONALITIES[selected_personality]["risk_factor"],
		"is_bot": true,
		"timeout_reached": false
	}
	
	print("[BotManager] Bot created: %s (%s) - WPM: %d, Personality: %s" % [
		bot_name, character, bot_wpm, selected_personality
	])
	
	return current_bot

func calculate_player_avg_wpm() -> float:
	"""Calculate player's average WPM from match history"""
	if player_wpm_history.is_empty():
		return 50.0  # Default WPM
	
	var total_wpm = 0.0
	var valid_matches = 0
	
	for match in player_wpm_history:
		if match.has("wpm") and match.wpm > 0:
			total_wpm += float(match.wpm)
			valid_matches += 1
	
	if valid_matches == 0:
		return 50.0
	
	return total_wpm / valid_matches

func select_bot_character(personality: String) -> String:
	"""Select character based on personality"""
	match personality:
		"aggressive":
			# Aggressive bots prefer Riven (high damage, self-damage risk)
			return "Riven" if randf() < 0.7 else "Zephon"
		"defensive":
			# Defensive bots prefer Liora (healing, survivability)
			return "Liora" if randf() < 0.7 else "Zephon"
		"balanced":
			# Balanced bots can use any character
			var chars = ["Riven", "Zephon", "Liora"]
			return chars[randi() % chars.size()]
	return "Zephon"

func select_bot_skills(personality: String) -> Array:
	"""Select 2 skills based on personality"""
	var preferred = PERSONALITIES[personality]["skill_preference"]
	var all_skills = ["quickslash", "whiplash", "soulbreak"]
	var selected = []
	
	# Always include at least one preferred skill
	selected.append(preferred[randi() % preferred.size()])
	
	# Second skill: prefer another from preferred list, fallback to any
	var remaining = all_skills.filter(func(s): return not selected.has(s))
	if randf() < 0.6 and remaining.size() > 0:
		# Try to pick another preferred skill
		var preferred_remaining = remaining.filter(func(s): return preferred.has(s))
		if not preferred_remaining.is_empty():
			selected.append(preferred_remaining[randi() % preferred_remaining.size()])
		else:
			selected.append(remaining[randi() % remaining.size()])
	else:
		selected.append(remaining[randi() % remaining.size()])
	
	return selected

func select_bot_passive(personality: String) -> String:
	"""Select passive based on personality"""
	match personality:
		"aggressive":
			# Aggressive: Reversal or Stutter (disrupt opponent)
			return ["reversal", "stutter"][randi() % 2]
		"defensive":
			# Defensive: Phantom or Erosion (subtle disruption)
			return ["phantom", "erosion"][randi() % 2]
		"balanced":
			# Balanced: Any passive
			var passives = ["reversal", "jumble", "phantom", "stutter", "erosion"]
			return passives[randi() % passives.size()]
	return "reversal"

# ─────────────────────────────────────────────
#  Bot Typing Simulation
# ─────────────────────────────────────────────

func start_typing_simulation(sentence: String):
	"""Start simulating bot typing for a given sentence"""
	bot_target_sentence = sentence
	bot_current_progress = 0.0
	bot_typos = 0
	bot_typing_finished_internal = false
	bot_typing_start_time = Time.get_ticks_msec() / 1000.0
	_typing_simulation_timer = 0.0
	
	print("[BotManager] Started typing simulation: '%s' (WPM: %d)" % [
		sentence.substr(0, min(20, sentence.length())), current_bot.wpm
	])

func simulate_typing(delta: float) -> Dictionary:
	"""Update bot typing progress. Returns {progress, typos, finished}"""
	if bot_typing_finished_internal or not is_bot_active:
		return {"progress": bot_current_progress, "typos": bot_typos, "finished": bot_typing_finished_internal}
	
	_typing_simulation_timer += delta
	
	# Calculate expected time to finish based on WPM
	var chars_in_sentence = bot_target_sentence.length()
	var words_in_sentence = chars_in_sentence / 5.0  # Standard word length
	var minutes_to_finish = words_in_sentence / current_bot.wpm
	var seconds_to_finish = minutes_to_finish * 60.0
	
	# Add some randomness to typing speed (human-like variation)
	var speed_variation = 1.0 + (randf() - 0.5) * 0.3  # ±15% variation
	seconds_to_finish *= speed_variation
	
	# Calculate progress based on elapsed time
	var elapsed = (Time.get_ticks_msec() / 1000.0) - bot_typing_start_time
	var target_progress = elapsed / seconds_to_finish
	
	# Add small random fluctuations to progress (simulate typing bursts/pauses)
	var fluctuation = sin(_typing_simulation_timer * 3.0) * 0.02
	target_progress += fluctuation
	
	# Generate typos based on accuracy
	if randf() > current_bot.accuracy:
		# Make a typo - reduce progress slightly
		bot_typos += 1
		target_progress = max(0.0, target_progress - 0.01)
	
	# Clamp progress
	bot_current_progress = clamp(target_progress, 0.0, 1.0)
	
	# Check if finished
	if bot_current_progress >= 0.999:
		bot_current_progress = 1.0
		bot_typing_finished_internal = true
		bot_finish_time = Time.get_ticks_msec() / 1000.0
		print("[BotManager] Bot finished typing in %.2f seconds" % (bot_finish_time - bot_typing_start_time))
		bot_finished_typing.emit()
	
	return {
		"progress": bot_current_progress,
		"typos": bot_typos,
		"finished": bot_typing_finished_internal
	}

func get_bot_wpm() -> float:
	"""Calculate bot's WPM based on current progress and time"""
	if bot_typing_start_time == 0.0:
		return 0.0
	
	var elapsed_min = ((Time.get_ticks_msec() / 1000.0) - bot_typing_start_time) / 60.0
	if elapsed_min <= 0:
		return 0.0
	
	var chars_typed = bot_current_progress * bot_target_sentence.length()
	var words_typed = chars_typed / 5.0
	return words_typed / elapsed_min

# ─────────────────────────────────────────────
#  Bot Skill Selection AI
# ─────────────────────────────────────────────

func select_bot_skill(available_skills: Array, current_mana: int, 
					 player_hp: float, bot_hp: float, 
					 player_streak: int, bot_streak: int) -> String:
	"""AI decision for which skill to use"""
	
	if available_skills.is_empty():
		return ""
	
	# Filter skills bot can afford
	var affordable_skills = available_skills.filter(func(s): 
		return SkillsManager.SKILL_COSTS.get(s, 99) <= current_mana
	)
	
	if affordable_skills.is_empty():
		return ""
	
	match current_bot.personality:
		"aggressive":
			return aggressive_skill_selection(affordable_skills, player_hp, bot_hp, bot_streak)
		"defensive":
			return defensive_skill_selection(affordable_skills, player_streak, current_mana)
		"balanced":
			return balanced_skill_selection(affordable_skills, player_hp, bot_hp, 
										  player_streak, bot_streak, current_mana)
	
	return affordable_skills[randi() % affordable_skills.size()]

func aggressive_skill_selection(skills: Array, player_hp: float, 
							   bot_hp: float, bot_streak: int) -> String:
	"""Aggressive AI: prioritize damage and streaks"""
	
	# Prefer Quickslash for consistent damage
	if skills.has("quickslash"):
		# Use more aggressively when on a streak
		if bot_streak >= 1 or player_hp < 30:
			return "quickslash"
	
	# Use Soulbreak when mana is high or player HP is low
	if skills.has("soulbreak") and (bot_streak >= 1 or player_hp < 40):
		return "soulbreak"
	
	# Fallback to any available skill
	return skills[randi() % skills.size()]

func defensive_skill_selection(skills: Array, player_streak: int, 
							  current_mana: int) -> String:
	"""Defensive AI: counter opponent streaks, preserve mana"""
	
	# Use Whiplash when opponent has streak (counter play)
	if skills.has("whiplash") and player_streak >= 1:
		return "whiplash"
	
	# Use skills only when we have plenty of mana
	if current_mana >= 8 and skills.has("soulbreak"):
		return "soulbreak"
	
	# Use Quickslash if we must pick something
	if skills.has("quickslash") and current_mana >= 4:
		return "quickslash"
	
	# Otherwise, save mana
	return ""

func balanced_skill_selection(skills: Array, player_hp: float, bot_hp: float,
							 player_streak: int, bot_streak: int,
							 current_mana: int) -> String:
	"""Balanced AI: mix of offense and defense"""
	
	# Counter opponent streaks
	if skills.has("whiplash") and player_streak >= 2:
		return "whiplash"
	
	# Push advantage when ahead
	if skills.has("quickslash") and bot_streak >= 1:
		return "quickslash"
	
	# Use Soulbreak when mana is high
	if skills.has("soulbreak") and current_mana >= 8:
		return "soulbreak"
	
	# Default: use Quickslash if affordable
	if skills.has("quickslash") and current_mana >= 2:
		return "quickslash"
	
	return ""

# ─────────────────────────────────────────────
#  Bot Match Management
# ─────────────────────────────────────────────

func start_bot_match():
	"""Initialize a bot match"""
	is_bot_active = true
	bot_match_started.emit(current_bot)
	print("[BotManager] Bot match started")

func end_bot_match():
	"""Clean up after bot match ends"""
	is_bot_active = false
	current_bot = {}
	bot_typing_finished_internal = false
	print("[BotManager] Bot match ended")

func reset_bot_round():
	"""Reset bot state for new round"""
	bot_current_progress = 0.0
	bot_typos = 0
	bot_typing_finished_internal = false
	bot_typing_start_time = 0.0
	_typing_simulation_timer = 0.0

# ─────────────────────────────────────────────
#  Utility Functions
# ─────────────────────────────────────────────

func get_bot_display_name() -> String:
	"""Get the bot's display name"""
	return current_bot.get("name", "AI Opponent")

func get_bot_character() -> String:
	"""Get the bot's selected character"""
	return current_bot.get("character", "Zephon")

func get_bot_passive() -> String:
	"""Get the bot's selected passive"""
	return current_bot.get("passive", "reversal")

func get_bot_skills() -> Array:
	"""Get the bot's selected skills"""
	return current_bot.get("skills", [])

func is_playing_bot() -> bool:
	"""Check if current match is against a bot"""
	return is_bot_active and not current_bot.is_empty()

func get_timeout_range() -> Dictionary:
	"""Get the random timeout range for bot spawning"""
	return {"min": 30, "max": 50}
