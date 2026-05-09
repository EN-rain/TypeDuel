extends Control

@onready var feedback_input = $VBoxContainer/FeedbackInput
@onready var send_button = $VBoxContainer/SendButton
@onready var status_label = $VBoxContainer/StatusLabel
@onready var http_request = $HTTPRequest

func _ready():
	# Fade in UI content only
	$VBoxContainer.modulate.a = 0.0
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property($VBoxContainer, "modulate:a", 1.0, 0.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	# Signal connection for HTTPRequest is defined in the .tscn file

func _on_send_button_pressed():
	var text = feedback_input.text.strip_edges()
	if text == "":
		status_label.text = "Please enter some feedback."
		return

	var body = JSON.stringify({
		"user_id": GameManager.user_data.id,
		"feedback": text
	})
	var headers = ["Content-Type: application/json"]
	http_request.request(GameManager.SERVER_URL + "/api/feedback", headers, HTTPClient.METHOD_POST, body)
	send_button.disabled = true
	status_label.text = "Sending..."

func _on_request_completed(_result, response_code, _headers, body):
	send_button.disabled = false
	var response = JSON.parse_string(body.get_string_from_utf8())
	if response_code == 200:
		status_label.text = "Thank you for your feedback!"
		feedback_input.text = ""
	else:
		status_label.text = response.message if response and response.has("message") else "Failed to send feedback."

func _on_back_button_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/menus/main_menu.tscn")
