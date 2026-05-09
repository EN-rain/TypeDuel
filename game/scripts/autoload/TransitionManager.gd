extends CanvasLayer

## TransitionManager — persistent scene transition overlay.
## Instantiates transition.tscn and survives scene changes as an autoload.
## Usage: TransitionManager.to("res://path/scene.tscn")
##        TransitionManager.to_game("res://scenes/game/game.tscn")

const TRANSITION_SCENE     = preload("res://scenes/ui/transitions/transition.tscn")
const TRANSITION_TWO_SCENE = preload("res://scenes/ui/transitions/transition_two.tscn")

var _transition: Control = null
var _anim: AnimationPlayer = null
var _transition_two: Control = null
var _anim_two: AnimationPlayer = null
var _pending_scene: String = ""
var _busy: bool = false

func _ready() -> void:
	layer = 100
	# Transition one (wipe — menu ↔ lobby)
	_transition = TRANSITION_SCENE.instantiate()
	add_child(_transition)
	_anim = _transition.get_node("AnimationPlayer")
	_anim.play("RESET")
	# Transition two (cinematic — lobby → game)
	_transition_two = TRANSITION_TWO_SCENE.instantiate()
	add_child(_transition_two)
	_anim_two = _transition_two.get_node("AnimationPlayer")
	_anim_two.play("RESET")
	_transition_two.hide()

## Call this to trigger the transition to a new scene.
## Starts background loading immediately so the scene is ready by the time
## the animation covers the screen.
func to(scene_path: String) -> void:
	if _busy:
		return
	_busy = true
	_pending_scene = scene_path
	# Kick off background load right away — by the time the animation
	# reaches the scene-change point (~0.4s) it should be fully loaded.
	ResourceLoader.load_threaded_request(scene_path)
	_anim.play("transition")

## Play transition backwards then change scene (used for back navigation).
func back(scene_path: String) -> void:
	to(scene_path)

## Cinematic transition to game scene using TransitionTwo.
## Flow: intro plays → screen covered → scene changes → intro plays backwards → done
func to_game(scene_path: String) -> void:
	if _busy:
		return
	_busy = true
	_pending_scene = scene_path
	ResourceLoader.load_threaded_request(scene_path)

	# Phase 1: play intro forward until screen is covered
	_transition_two.show()
	_anim_two.play("intro")
	await _anim_two.animation_finished

	# Screen fully covered — swap scene
	_do_scene_change()
	await get_tree().process_frame
	await get_tree().process_frame

	# Phase 2: play intro backwards to reveal the new scene
	var anim_length = _anim_two.get_animation("intro").length
	_anim_two.play("intro", -1, -1.0, true)
	_anim_two.seek(anim_length, true)
	await _anim_two.animation_finished

	_anim_two.play("RESET")
	_transition_two.hide()
	_busy = false

func _do_scene_change() -> void:
	if _pending_scene == "":
		_busy = false
		return
	# Poll until the background load is done (should already be ready)
	var status = ResourceLoader.load_threaded_get_status(_pending_scene)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		var packed = ResourceLoader.load_threaded_get(_pending_scene)
		get_tree().change_scene_to_packed(packed)
	else:
		# Fallback — load wasn't ready yet, do it synchronously
		get_tree().call_deferred("change_scene_to_file", _pending_scene)
	_pending_scene = ""
	_busy = false
