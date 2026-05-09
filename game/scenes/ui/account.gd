extends Control

@onready var display_name_input = %DisplayNameInput
@onready var password_input     = %PasswordInput
@onready var status_label       = %StatusLabel
@onready var http_request       = %HTTPRequest
@onready var save_button        = %SaveButton
@onready var pfp_rect           = %PFP
@onready var file_dialog        = %FileDialog
@onready var upload_request     = %UploadRequest

var UPDATE_URL = GameManager.SERVER_URL + "/api/auth/update"
var UPLOAD_URL = GameManager.SERVER_URL + "/api/auth/upload-pfp"

func _ready():
	$AnimationPlayer.play("fade_in")

	display_name_input.text = GameManager.user_data.display_name
	%UsernameDisplay.text = GameManager.user_data.username
	%UsernameDisplay.editable = false
	http_request.request_completed.connect(_on_request_completed)
	upload_request.request_completed.connect(_on_upload_completed)

	# Button press shrink animation
	_connect_press_anim(save_button)
	_connect_press_anim(%ChangePFPButton)
	_connect_press_anim($BackButton)

	load_current_pfp()

func load_current_pfp():
	GameManager.load_pfp_into(GameManager.user_data.profile_icon, pfp_rect, self)

func _on_change_pfp_button_pressed():
	file_dialog.popup_centered()

func _on_file_dialog_file_selected(path):
	var img = Image.load_from_file(path)
	if img:
		var img_size = img.get_size()
		var min_dim = min(img_size.x, img_size.y)
		var crop_rect = Rect2i(
			(img_size.x - min_dim) / 2,
			(img_size.y - min_dim) / 2,
			min_dim,
			min_dim
		)
		var cropped_img = img.get_region(crop_rect)

		var tex = ImageTexture.create_from_image(cropped_img)
		pfp_rect.texture = tex

		const MAX_UPLOAD_DIM := 512
		if min_dim > MAX_UPLOAD_DIM:
			cropped_img.resize(MAX_UPLOAD_DIM, MAX_UPLOAD_DIM, Image.INTERPOLATE_CUBIC)
		var buffer = cropped_img.save_png_to_buffer()
		_upload_buffer(buffer)

func _upload_buffer(buffer: PackedByteArray):
	var boundary = "GodotFileUploadBoundary"
	var headers = GameManager.get_auth_headers()
	headers.append("Content-Type: multipart/form-data; boundary=" + boundary)

	var body = PackedByteArray()
	body.append_array(("--" + boundary + "\r\n").to_utf8_buffer())
	body.append_array(("Content-Disposition: form-data; name=\"userId\"\r\n\r\n").to_utf8_buffer())
	body.append_array((str(GameManager.user_data.id) + "\r\n").to_utf8_buffer())
	body.append_array(("--" + boundary + "\r\n").to_utf8_buffer())
	body.append_array(("Content-Disposition: form-data; name=\"pfp\"; filename=\"pfp.png\"\r\n").to_utf8_buffer())
	body.append_array(("Content-Type: image/png\r\n\r\n").to_utf8_buffer())
	body.append_array(buffer)
	body.append_array(("\r\n").to_utf8_buffer())
	body.append_array(("--" + boundary + "--\r\n").to_utf8_buffer())

	upload_request.request_raw(UPLOAD_URL, headers, HTTPClient.METHOD_POST, body)
	status_label.text = "Uploading picture..."

func _on_upload_completed(_result, response_code, _headers, body):
	var response = JSON.parse_string(body.get_string_from_utf8())
	if response_code == 200:
		status_label.text = "Picture updated!"
		GameManager.user_data.profile_icon = response.profile_icon
		load_current_pfp()
	else:
		status_label.text = response.message if response and response.has("message") else "Upload failed"

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

	http_request.request(UPDATE_URL, GameManager.get_auth_headers(), HTTPClient.METHOD_POST, body)
	save_button.disabled = true
	status_label.text = "Updating..."

func _on_request_completed(_result, response_code, _headers, body):
	save_button.disabled = false
	var response = JSON.parse_string(body.get_string_from_utf8())

	if response_code == 200:
		status_label.text = "Profile updated!"
		GameManager.user_data.display_name = display_name_input.text
	else:
		status_label.text = response.message if response and response.has("message") else "Update failed"

func _on_back_button_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")

func _connect_press_anim(button: Button) -> void:
	if button == null: return
	button.button_down.connect(_on_btn_shrink.bind(button))
	button.button_up.connect(_on_btn_grow.bind(button))

func _on_btn_shrink(btn: Button) -> void:
	btn.pivot_offset = btn.size / 2.0
	var tween = create_tween()
	tween.tween_property(btn, "scale", Vector2(0.9, 0.9), 0.08).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)

func _on_btn_grow(btn: Button) -> void:
	btn.pivot_offset = btn.size / 2.0
	var tween = create_tween()
	tween.tween_property(btn, "scale", Vector2(1.0, 1.0), 0.12).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
