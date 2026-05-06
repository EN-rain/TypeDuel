extends Control

@onready var display_name_input = $VBoxContainer/DisplayNameInput
@onready var password_input = $VBoxContainer/PasswordInput
@onready var status_label = $VBoxContainer/StatusLabel
@onready var http_request = $HTTPRequest
@onready var save_button = $VBoxContainer/SaveButton
@onready var pfp_rect = $PFP
@onready var file_dialog = $FileDialog
@onready var upload_request = $UploadRequest
@onready var pfp_load_request = $HTTPRequest


var UPDATE_URL = GameManager.SERVER_URL + "/api/auth/update"
var UPLOAD_URL = GameManager.SERVER_URL + "/api/auth/upload-pfp"

func _ready():
	# Fade in UI content only (background stays visible)
	$VBoxContainer.modulate.a = 0.0
	$PFP.modulate.a = 0.0
	$BackButton.modulate.a = 0.0
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property($VBoxContainer, "modulate:a", 1.0, 0.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property($PFP, "modulate:a", 1.0, 0.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property($BackButton, "modulate:a", 1.0, 0.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

	# Pre-fill current display name
	display_name_input.text = GameManager.user_data.display_name
	http_request.request_completed.connect(_on_request_completed)
	upload_request.request_completed.connect(_on_upload_completed)
	
	load_current_pfp()

func load_current_pfp():
	var icon = GameManager.user_data.profile_icon
	if icon == "default" or icon == "":
		return
	
	# Prevent the scene's placeholder texture from flashing while we fetch the real avatar.
	# (The PFP TextureRect has a default texture set in `account.tscn`.)
	pfp_rect.texture = null
		
	var url = GameManager.SERVER_URL + "/uploads/" + icon
	var loader = HTTPRequest.new()
	add_child(loader)
	loader.request_completed.connect(func(_result, response_code, _headers, body):
		if response_code == 200:
			var image = Image.new()
			var error = image.load_png_from_buffer(body)
			if error != OK:
				error = image.load_jpg_from_buffer(body)
			
			if error == OK:
				pfp_rect.texture = ImageTexture.create_from_image(image)
		loader.queue_free()
	)
	loader.request(url)

var dragging = false
var original_image: Image

func _on_change_pfp_button_pressed():
	file_dialog.popup_centered()

func _on_file_dialog_file_selected(path):
	var img = Image.load_from_file(path)
	if img:
		# Center-crop the image to a square before resizing and uploading
		var img_size = img.get_size()
		var min_dim = min(img_size.x, img_size.y)
		var crop_rect = Rect2i(
			(img_size.x - min_dim) / 2,
			(img_size.y - min_dim) / 2,
			min_dim,
			min_dim
		)
		var cropped_img = img.get_region(crop_rect)
		
		# Show the cropped version immediately
		var tex = ImageTexture.create_from_image(cropped_img)
		pfp_rect.texture = tex
		
		# Avoid always resampling avatars before upload.
		# Bilinear downscaling can heavily distort pixel-art style images.
		# Only downscale when the source is very large to keep uploads reasonable.
		const MAX_UPLOAD_DIM := 512
		if min_dim > MAX_UPLOAD_DIM:
			cropped_img.resize(MAX_UPLOAD_DIM, MAX_UPLOAD_DIM, Image.INTERPOLATE_CUBIC)
		var buffer = cropped_img.save_png_to_buffer()
		
		# Upload directly
		_upload_buffer(buffer)

func _upload_buffer(buffer: PackedByteArray):
	var boundary = "GodotFileUploadBoundary"
	var headers = [
		"Content-Type: multipart/form-data; boundary=" + boundary
	]
	
	var body = PackedByteArray()
	# userId field
	body.append_array(("--" + boundary + "\r\n").to_utf8_buffer())
	body.append_array(("Content-Disposition: form-data; name=\"userId\"\r\n\r\n").to_utf8_buffer())
	body.append_array((str(GameManager.user_data.id) + "\r\n").to_utf8_buffer())
	
	# pfp file
	body.append_array(("--" + boundary + "\r\n").to_utf8_buffer())
	body.append_array(("Content-Disposition: form-data; name=\"pfp\"; filename=\"pfp.png\"\r\n").to_utf8_buffer())
	body.append_array(("Content-Type: image/png\r\n\r\n").to_utf8_buffer())
	body.append_array(buffer)
	body.append_array(("\r\n").to_utf8_buffer())
	
	body.append_array(("--" + boundary + "--\r\n").to_utf8_buffer())
	
	upload_request.request_raw(UPLOAD_URL, headers, HTTPClient.METHOD_POST, body)
	status_label.text = "Uploading picture..."

func upload_pfp(_file_path: String):
	# This is now replaced by the editor flow
	pass

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
	
	var headers = ["Content-Type: application/json"]
	http_request.request(UPDATE_URL, headers, HTTPClient.METHOD_POST, body)
	save_button.disabled = true
	status_label.text = "Updating..."

func _on_request_completed(_result, response_code, _headers, body):
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
