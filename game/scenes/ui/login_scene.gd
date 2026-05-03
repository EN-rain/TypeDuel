extends Control

@onready var login_mode_btn = $VBoxContainer/ModeSelection/LoginMode
@onready var register_mode_btn = $VBoxContainer/ModeSelection/RegisterMode
@onready var username_input = $VBoxContainer/UsernameInput
@onready var password_input = $VBoxContainer/PasswordInput
@onready var confirm_password_input = $VBoxContainer/ConfirmPasswordInput
@onready var confirm_button = $VBoxContainer/ConfirmButton
@onready var error_label = $VBoxContainer/ErrorLabel
@onready var http_request = $HTTPRequest

const BASE_URL = "http://34.126.180.170:3000/api/auth"
var is_login_mode = true

func _ready():
	login_mode_btn.pressed.connect(_on_mode_selected.bind(true))
	register_mode_btn.pressed.connect(_on_mode_selected.bind(false))
	confirm_button.pressed.connect(_on_confirm_pressed)
	http_request.request_completed.connect(_on_request_completed)

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

func _on_request_completed(result, response_code, headers, body):
	confirm_button.disabled = false
	var response = JSON.parse_string(body.get_string_from_utf8())
	
	if response_code in [200, 201]:
		if is_login_mode:
			error_label.text = "Success!"
			print("Token: ", response.token)
		else:
			error_label.text = "Registered! Please login."
			_on_mode_selected(true)
	else:
		error_label.text = response.message if response and response.has("message") else "Failed"
