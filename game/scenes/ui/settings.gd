extends Control

@onready var display_name_input = $VBoxContainer/DisplayNameInput
@onready var password_input = $VBoxContainer/PasswordInput
@onready var status_label = $VBoxContainer/StatusLabel
@onready var http_request = $HTTPRequest
@onready var save_button = $VBoxContainer/SaveButton
@onready var pfp_rect = $VBoxContainer/PFPHolder/PFP
@onready var file_dialog = $FileDialog
@onready var upload_request = $UploadRequest
@onready var pfp_load_request = $HTTPRequest
@onready var pfp_editor = $PFPEditor
@onready var editor_preview = $PFPEditor/VBox/EditorContainer/PFPPreview
@onready var scale_slider = $PFPEditor/VBox/ScaleSlider
@onready var capture_viewport = $CaptureViewport
@onready var capture_sprite = $CaptureViewport/CaptureSprite

var UPDATE_URL = GameManager.SERVER_URL + "/api/auth/update"
var UPLOAD_URL = GameManager.SERVER_URL + "/api/auth/upload-pfp"

func _ready():
	# Pre-fill current display name
	display_name_input.text = GameManager.user_data.display_name
	http_request.request_completed.connect(_on_request_completed)
	upload_request.request_completed.connect(_on_upload_completed)
	
	load_current_pfp()

func load_current_pfp():
	var icon = GameManager.user_data.profile_icon
	if icon == "default" or icon == "":
		return
		
	var url = GameManager.SERVER_URL + "/uploads/" + icon
	var loader = HTTPRequest.new()
	add_child(loader)
	loader.request_completed.connect(func(result, response_code, headers, body):
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
		original_image = img
		var tex = ImageTexture.create_from_image(img)
		editor_preview.texture = tex
		pfp_editor.show()
		# Reset editor
		editor_preview.position = Vector2(0, 0)
		scale_slider.value = 1.0
		editor_preview.scale = Vector2(1, 1)

func _on_pfp_preview_gui_input(event):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			dragging = event.pressed
	elif event is InputEventMouseMotion and dragging:
		editor_preview.position += event.relative

func _on_scale_slider_value_changed(value):
	editor_preview.scale = Vector2(value, value)

func _on_cancel_edit_pressed():
	pfp_editor.hide()

func _on_apply_edit_pressed():
	# 1. Setup capture sprite for WYSIWYG
	# Map 300x300 editor to 256x256 capture
	var ratio = 256.0 / 300.0
	capture_sprite.texture = editor_preview.texture
	capture_sprite.scale = editor_preview.scale * ratio
	
	# Center of editor is (150, 150)
	# editor_preview.position is relative to its anchor (center)
	capture_sprite.position = (Vector2(150, 150) + editor_preview.position) * ratio
	# Adjust for Sprite2D not being centered by default or centered=false
	capture_sprite.offset = -editor_preview.pivot_offset # If any, but we use defaults
	
	# 2. Capture
	capture_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	await get_tree().process_frame
	
	var captured_img = capture_viewport.get_texture().get_image()
	var buffer = captured_img.save_png_to_buffer()
	
	# 3. Upload
	_upload_buffer(buffer)
	pfp_editor.hide()

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

func upload_pfp(file_path: String):
	# This is now replaced by the editor flow
	pass

func _on_upload_completed(result, response_code, headers, body):
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
