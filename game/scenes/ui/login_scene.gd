extends Control

@onready var login_mode_btn = $VBoxContainer/ModeSelection/LoginMode
@onready var register_mode_btn = $VBoxContainer/ModeSelection/RegisterMode
@onready var username_input = $VBoxContainer/UsernameInput
@onready var password_input = $VBoxContainer/PasswordInput
@onready var confirm_password_input = $VBoxContainer/ConfirmPasswordInput
@onready var confirm_button = $VBoxContainer/ConfirmButton
@onready var error_label = $VBoxContainer/ErrorLabel
@onready var http_request = $HTTPRequest

var BASE_URL: String:
	get: return GameManager.SERVER_URL + "/api/auth"

var is_login_mode = true

func _enter_tree():
	# Don't touch root modulate — background stays visible always
	pass

func _ready():
	login_mode_btn.pressed.connect(_on_mode_selected.bind(true))

	register_mode_btn.pressed.connect(_on_mode_selected.bind(false))
	confirm_button.pressed.connect(_on_confirm_pressed)
	http_request.request_completed.connect(_on_request_completed)
	
	# Fade in only the form elements, not the background
	$TextureRect2.modulate.a = 0.0
	$VBoxContainer.modulate.a = 0.0
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property($TextureRect2, "modulate:a", 1.0, 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property($VBoxContainer, "modulate:a", 1.0, 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

func _on_mode_selected(login):
	is_login_mode = login
	login_mode_btn.button_pressed = is_login_mode
	register_mode_btn.button_pressed = !is_login_mode
	confirm_password_input.visible = !is_login_mode
	error_label.text = ""

func _on_confirm_pressed():
	var username = username_input.text
	var password = password_input.text
	var confirm_password = confirm_password_input.text
	
	if username == "" or password == "":
		error_label.text = "Fields required"
		return
		
	if !is_login_mode and password != confirm_password:
		error_label.text = "Passwords do not match"
		return
	
	var endpoint = "/login" if is_login_mode else "/register"
	var body = JSON.stringify({"username": username, "password": password})
	var headers = ["Content-Type: application/json"]
	
	http_request.request(BASE_URL + endpoint, headers, HTTPClient.METHOD_POST, body)
	confirm_button.disabled = true
	error_label.text = "..."

func _on_request_completed(_result, response_code, _headers, body):
	confirm_button.disabled = false
	var body_string = body.get_string_from_utf8()
	var response = JSON.parse_string(body_string)
	
	if response == null:
		error_label.text = "Server error (Non-JSON response)"
		print("Raw Body: ", body_string)
		return
	
	if response_code in [200, 201]:
		if is_login_mode:
			error_label.text = "Success!"
			# Store user data in global GameManager
			GameManager.user_data.id = response.user.id
			GameManager.user_data.username = response.user.username
			GameManager.user_data.display_name = response.user.display_name
			GameManager.user_data.profile_icon = response.user.get("profile_icon", "default")
			GameManager.user_data.token = response.token
			
			# Transition to Main Menu with fade out
			_fade_out_and_transition("res://scenes/ui/main_menu.tscn")
		else:
			error_label.text = "Registered! Please login."
			_on_mode_selected(true)
	else:
		error_label.text = response.message if response and response.has("message") else "Failed"

func _fade_out_and_transition(scene_path: String):
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property($TextureRect2, "modulate:a", 0.0, 0.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.tween_property($VBoxContainer, "modulate:a", 0.0, 0.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(func(): get_tree().change_scene_to_file(scene_path))
