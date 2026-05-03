extends Control

@onready var display_name_input = $VBoxContainer/DisplayNameInput
@onready var password_input = $VBoxContainer/PasswordInput
@onready var status_label = $VBoxContainer/StatusLabel
@onready var http_request = $HTTPRequest
@onready var save_button = $VBoxContainer/SaveButton

const UPDATE_URL = "http://34.126.180.170:3000/api/auth/update"

func _ready():
	# Pre-fill current display name
	display_name_input.text = GameManager.user_data.display_name
	http_request.request_completed.connect(_on_request_completed)

func _on_save_button_pressed():
	var new_name = display_name_input.text
	var new_pass = password_input.text
	
	if new_name == "":
		status_label.text = "In-game name cannot be empty"
		return
		
	var body = JSON.stringify({
		"userId": GameManager.user_data.id,
		"newDisplayName": new_name,
		"newPassword": new_pass
	})
	
	var headers = ["Content-Type: application/json"]
	http_request.request(UPDATE_URL, headers, HTTPClient.METHOD_POST, body)
	save_button.disabled = true
	status_label.text = "Updating..."

func _on_request_completed(result, response_code, headers, body):
	save_button.disabled = false
	var response = JSON.parse_string(body.get_string_from_utf8())
	
	if response_code == 200:
		status_label.text = "Profile updated!"
		# Update global data
		GameManager.user_data.display_name = display_name_input.text
	else:
		status_label.text = response.message if response and response.has("message") else "Update failed"

func _on_back_button_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
