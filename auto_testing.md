# PvP Autoplay Testing Suite Archive

This document contains the temporary automation code used to verify character innates, passives, and combat math.

## 1. The Autoload (`AutoplayTester.gd`)
```gdscript
extends Node

var is_active: bool = false
var test_step: int = 0

const CHARACTERS = ["Riven", "Zephon", "Liora"]
const PASSIVES = ["reversal", "jumble", "phantom", "stutter", "erosion"]
const CHARACTERS_INNATES = {
	"Riven": "Bloodlust",
	"Zephon": "Overdrive",
	"Liora": "Grace"
}

func advance_step():
	test_step += 1

func get_character(is_host: bool) -> String:
	# Use step to cycle combinations. Host and Guest get different chars.
	var offset = 0 if is_host else 1
	return CHARACTERS[(test_step + offset) % CHARACTERS.size()]

func get_passive(is_host: bool) -> String:
	var offset = 0 if is_host else 2
	return PASSIVES[(test_step + offset) % PASSIVES.size()]

func get_skills(is_host: bool) -> Array:
	if is_host: return [0, 1] # Quickslash, Whiplash
	else: return [1, 2]      # Whiplash, Soulbreak
```

## 2. Lobby Injection (`custom_room.gd`)
Hooks to auto-select and start.
```gdscript
# Inside _process or _on_f2_pressed
if AutoplayTester.is_active and not _autoplay_lobby_done:
    _autoplay_lobby_done = true
    var char_name = AutoplayTester.get_character(GameManager.is_host)
    var passive_id = AutoplayTester.get_passive(GameManager.is_host)
    _on_character_selected(char_name)
    _on_passive_selected(passive_id)
    
    var skills_idx = AutoplayTester.get_skills(GameManager.is_host)
    _on_skill_selected(SKILLS[skills_idx[0]]["id"])
    _on_skill_selected(SKILLS[skills_idx[1]]["id"])
    
    _on_ready_pressed()
    if GameManager.is_host:
        await get_tree().create_timer(1.0).timeout
        _on_start_pressed()
```

## 3. Combat Injection (`game.gd`)
Capping damage and cycling states.
```gdscript
# Inside _resolve_and_advance
if AutoplayTester.is_active:
    player_damage = 1.0 # Force 1 HP for infinite testing
    AutoplayTester.advance_step()
    
    # Switch for next round
    var new_char = AutoplayTester.get_character(GameManager.is_host)
    var new_passive = AutoplayTester.get_passive(GameManager.is_host)
    HPManager.player_innate = AutoplayTester.CHARACTERS_INNATES.get(new_char, "")
    SkillsManager.selected_passive = new_passive
```

## 4. Victory Screen Injection
Auto-rematch.
```gdscript
if AutoplayTester.is_active:
    await get_tree().create_timer(2.0).timeout
    _on_rematch_pressed()
```
