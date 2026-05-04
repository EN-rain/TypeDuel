extends Control

@export var poll_interval: float = 1.5
@export var panel_slide_time: float = 0.3

@onready var messages_vbox = %MessagesVBox
@onready var fake_input = %FakeInput
@onready var real_input = %RealInput
@onready var send_button = %SendButton
@onready var chat_panel = %ChatPanel
@onready var scroll_container = chat_panel.get_node("VBoxContainer/ScrollContainer")
@onready var global_btn = %GlobalBtn
@onready var friend_btn = %FriendBtn

var room_id: String = "global"
var current_tab: String = "global" # "global" or "friends"
var last_message_ids: Dictionary = {"global": 0, "friends": 0}
var message_histories: Dictionary = {"global": [], "friends": []}
var poll_timer: float = 0.0
var is_expanded: bool = false

var pfp_cache: Dictionary = {}

func _ready():
	# Start with panel off-screen to the left
	chat_panel.position.x = -chat_panel.size.x - 20
	
	# Tab buttons
	global_btn.pressed.connect(_switch_tab.bind("global"))
	friend_btn.pressed.connect(_switch_tab.bind("friends"))
	_update_tab_visuals()
	
	# Clicking the design-only fake input expands the panel
	fake_input.focus_entered.connect(_expand_panel)
	
	# Real input logic
	real_input.text_submitted.connect(_on_send_pressed)
	send_button.pressed.connect(func(): _on_send_pressed(real_input.text))
	
	_fetch_messages("global")
	_fetch_messages("friends")

func _input(event):
	# Collapse if clicking outside the panel while expanded
	if event is InputEventMouseButton and event.pressed and is_expanded:
		var panel_rect = chat_panel.get_global_rect()
		var fake_rect = fake_input.get_global_rect()
		
		if not panel_rect.has_point(event.global_position) and not fake_rect.has_point(event.global_position):
			_collapse_panel()

func _process(delta):
	poll_timer += delta
	if poll_timer >= poll_interval:
		poll_timer = 0.0
		_fetch_messages("global")
		_fetch_messages("friends")

func _switch_tab(tab_name: String):
	if current_tab == tab_name: return
	
	current_tab = tab_name
	_rebuild_chat_view()
	_update_tab_visuals()

func _update_tab_visuals():
	global_btn.disabled = (current_tab == "global")
	friend_btn.disabled = (current_tab == "friends")

func _rebuild_chat_view():
	for child in messages_vbox.get_children():
		child.queue_free()
	
	for msg in message_histories[current_tab]:
		_add_message_to_vbox(msg)
	
	await get_tree().process_frame
	scroll_container.scroll_vertical = int(scroll_container.get_v_scroll_bar().max_value)

func _expand_panel():
	if is_expanded: return
	is_expanded = true
	
	var tween = create_tween()
	tween.tween_property(chat_panel, "position:x", 0, panel_slide_time).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	
	real_input.grab_focus()
	fake_input.release_focus()

func _collapse_panel():
	if not is_expanded: return
	is_expanded = false
	real_input.release_focus()
	
	var tween = create_tween()
	tween.tween_property(chat_panel, "position:x", -chat_panel.size.x - 20, panel_slide_time).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)

func _fetch_messages(tab: String):
	var http = HTTPRequest.new()
	add_child(http)
	
	var target_room = room_id if tab == "global" else "friends"
	http.request_completed.connect(_on_messages_received.bind(http, tab))
	http.request(GameManager.SERVER_URL + "/api/chat/messages?room_id=" + target_room + "&since=" + str(last_message_ids[tab]))

func _on_messages_received(_result, code, _headers, body, http: HTTPRequest, tab: String):
	if is_instance_valid(http):
		http.queue_free()
	
	if code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json is Array and json.size() > 0:
			for msg in json:
				message_histories[tab].append(msg)
				last_message_ids[tab] = max(last_message_ids[tab], msg.id)
				
				if current_tab == tab:
					_add_message_to_vbox(msg)
			
			if current_tab == tab:
				await get_tree().process_frame
				scroll_container.scroll_vertical = int(scroll_container.get_v_scroll_bar().max_value)
			
			if tab == "global":
				var last = json[-1]
				fake_input.placeholder_text = "%s: %s" % [last.username, last.message]

func _add_message_to_vbox(msg: Dictionary):
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	messages_vbox.add_child(row)
	
	# PFP
	var pfp = TextureRect.new()
	pfp.custom_minimum_size = Vector2(24, 24)
	pfp.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pfp.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(pfp)
	
	_load_pfp_into(msg.get("profile_icon", "default"), pfp)
	
	# Message Text
	var label = RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.text = "[b]%s:[/b] %s" % [msg.username, msg.message]
	row.add_child(label)

func _load_pfp_into(icon_name: String, rect: TextureRect):
	if icon_name == "default" or icon_name == "":
		return # Could set a default 👤 texture here
		
	if pfp_cache.has(icon_name):
		rect.texture = pfp_cache[icon_name]
		return
		
	var url = GameManager.SERVER_URL + "/uploads/" + icon_name
	var loader = HTTPRequest.new()
	add_child(loader)
	loader.request_completed.connect(func(_result, response_code, _headers, body):
		if response_code == 200:
			var image = Image.new()
			var err = image.load_png_from_buffer(body)
			if err != OK: err = image.load_jpg_from_buffer(body)
			
			if err == OK:
				var tex = ImageTexture.create_from_image(image)
				pfp_cache[icon_name] = tex
				if is_instance_valid(rect):
					rect.texture = tex
		loader.queue_free()
	)
	loader.request(url)

func _on_send_pressed(text: String):
	if text.strip_edges() == "":
		return
	
	real_input.text = ""
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r, _c, _h, _b): http.queue_free())
	
	var my_name = GameManager.user_data.display_name
	if my_name == "": my_name = GameManager.user_data.username
		
	var target_room = room_id if current_tab == "global" else "friends"
	var body = JSON.stringify({
		"user_id": GameManager.user_data.id,
		"username": my_name,
		"room_id": target_room,
		"message": text
	})
	http.request(GameManager.SERVER_URL + "/api/chat/send", ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
