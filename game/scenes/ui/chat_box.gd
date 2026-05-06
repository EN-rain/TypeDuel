extends Control
signal friends_updated

@export var poll_interval: float = 1.5
@export var panel_slide_time: float = 0.3

@onready var messages_vbox = %MessagesVBox
@onready var fake_input = %FakeInput
@onready var real_input = %RealInput
@onready var send_button = %SendButton
@onready var chat_panel = %ChatPanel
@onready var scroll_container = %ScrollContainer
@onready var friends_list_scroll = %FriendsListScroll
@onready var friends_list_vbox = %FriendsListVBox
@onready var global_btn = %GlobalBtn
@onready var friend_btn = %FriendBtn

var room_id: String = "":
	set(val):
		room_id = val
		if is_inside_tree():
			if room_id == "" or room_id == "global":
				%LocalBtn.hide()
			else:
				%LocalBtn.show()
				_fetch_messages("local")
				_switch_tab("local")

var current_tab: String = "global" # "global", "local", or "friends"
var last_message_ids: Dictionary = {"global": 0}
var message_histories: Dictionary = {"global": []}
var current_dm_room: String = ""
var accepted_friends_data: Array = []
var poll_timer: float = 0.0
var is_expanded: bool = false

var pfp_cache: Dictionary = {}
var pfp_popup: PopupMenu
var current_target_username: String = ""
# Tracks messages we've already shown optimistically to prevent poll duplicates
var _pending_sent: Array = [] # Array of {room_key, username, text}

func _ready():
	# Start with panel off-screen to the left and hidden
	chat_panel.position.x = -chat_panel.size.x - 20
	chat_panel.hide()
	
	# Tab buttons
	global_btn.pressed.connect(_switch_tab.bind("global"))
	%LocalBtn.pressed.connect(_switch_tab.bind("local"))
	friend_btn.pressed.connect(_switch_tab.bind("friends"))
	_update_tab_visuals()
	
	# Use gui_input or a dedicated Button instead of focus_entered to avoid toggle loops
	fake_input.gui_input.connect(_on_fake_input_gui_input)
	
	# Real input logic
	real_input.text_submitted.connect(_on_send_pressed)
	send_button.pressed.connect(func(): _on_send_pressed(real_input.text))
	
	if room_id == "" or room_id == "global":
		%LocalBtn.hide()
	else:
		%LocalBtn.show()
		_switch_tab("local")

	
	_fetch_messages("global")
	if room_id != "" and room_id != "global":
		_fetch_messages("local")
	
func _on_fake_input_gui_input(event: InputEvent):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not is_expanded:
			_expand_panel()

func _input(event):
	# Collapse if clicking outside the panel while expanded
	if event is InputEventMouseButton and event.pressed and is_expanded:
		var panel_rect = chat_panel.get_global_rect()
		var fake_rect = fake_input.get_global_rect()
		
		if not panel_rect.has_point(event.global_position) and not fake_rect.has_point(event.global_position):
			# Use call_deferred to avoid conflict with the click event that might be triggering a reopen
			_collapse_panel.call_deferred()

func _process(delta):
	poll_timer += delta
	if poll_timer >= poll_interval:
		poll_timer = 0.0
		_fetch_messages("global")
		if room_id != "" and room_id != "global":
			_fetch_messages("local")
		if current_dm_room != "":
			_fetch_messages(current_dm_room)
	
func _switch_tab(tab_name: String):
	if current_tab == tab_name: return
	
	current_tab = tab_name
	
	if current_tab == "friends":
		friends_list_scroll.show()
		_fetch_friends_for_sidebar()
		if is_expanded and current_dm_room != "":
			_mark_dm_read(current_dm_room)
		fake_input.placeholder_text = "Send a message..."
	elif current_tab == "local":
		friends_list_scroll.hide()
		fake_input.placeholder_text = "Local chat..."
	else: # global
		friends_list_scroll.hide()
		fake_input.placeholder_text = "Global chat..."
		
	_rebuild_chat_view()
	_update_tab_visuals()

func _update_tab_visuals():
	global_btn.disabled = (current_tab == "global")
	%LocalBtn.disabled = (current_tab == "local")
	friend_btn.disabled = (current_tab == "friends")

func _rebuild_chat_view():
	for child in messages_vbox.get_children():
		child.queue_free()
	
	var room_to_show = ""
	if current_tab == "global": room_to_show = "global"
	elif current_tab == "local": room_to_show = "local"
	else: room_to_show = current_dm_room
	if room_to_show == "" or not message_histories.has(room_to_show):
		return
		
	for msg in message_histories[room_to_show]:
		_add_message_to_vbox(msg)
	
	await get_tree().process_frame
	scroll_container.scroll_vertical = int(scroll_container.get_v_scroll_bar().max_value)

func _expand_panel():
	if is_expanded: return
	is_expanded = true
	chat_panel.show()
	
	# Force process to update transform so mouse filters work correctly
	chat_panel.set_process_unhandled_input(true)
	
	var tween = create_tween()
	if current_tab == "global" and room_id != "" and room_id != "global":
		_switch_tab("local")
	
	tween.tween_property(chat_panel, "position:x", 0, panel_slide_time).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	
	real_input.grab_focus()
	fake_input.release_focus()
	
	if current_tab == "friends" and current_dm_room != "":
		_mark_dm_read(current_dm_room)

func _collapse_panel():
	if not is_expanded: return
	is_expanded = false
	real_input.release_focus()
	
	var tween = create_tween()
	tween.tween_property(chat_panel, "position:x", -chat_panel.size.x - 20, panel_slide_time).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.finished.connect(func(): 
		chat_panel.hide()
	)

func _fetch_messages(room_name: String):
	if room_name == "": return
	if not last_message_ids.has(room_name):
		last_message_ids[room_name] = 0
		message_histories[room_name] = []
		
	var http = HTTPRequest.new()
	add_child(http)
	
	var target_room = "global"
	if room_name == "local": target_room = room_id
	elif room_name != "global": target_room = room_name
	http.request_completed.connect(_on_messages_received.bind(http, room_name))
	http.request(GameManager.SERVER_URL + "/api/chat/messages?room_id=" + target_room + "&since=" + str(last_message_ids[room_name]), GameManager.get_auth_headers())

func _on_messages_received(_result, code, _headers, body, http: HTTPRequest, room_name: String):
	if is_instance_valid(http):
		http.queue_free()
	
	if code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json is Array and json.size() > 0:
			var needs_scroll = false
			for msg in json:
				# Update the poll cursor first
				last_message_ids[room_name] = max(last_message_ids[room_name], msg.id)
				
				# Check if this is a message WE sent that's already shown optimistically
				var is_pending = false
				for i in _pending_sent.size():
					var p = _pending_sent[i]
					if p.room_key == room_name and p.text == msg.message and p.username == msg.username:
						_pending_sent.remove_at(i)
						is_pending = true
						break
				
				if is_pending:
					continue # Already shown, skip
					
				message_histories[room_name].append(msg)
				
				var is_already_showing_this_room = (current_tab == "global" and room_name == "global") or (current_tab == "local" and room_name == "local") or (current_tab == "friends" and room_name == current_dm_room)
				if is_already_showing_this_room:
					_add_message_to_vbox(msg)
					needs_scroll = true
			
			var is_showing_this_room = (current_tab == "global" and room_name == "global") or (current_tab == "local" and room_name == "local") or (current_tab == "friends" and room_name == current_dm_room)
			if needs_scroll and is_showing_this_room:
				await get_tree().process_frame
				scroll_container.scroll_vertical = int(scroll_container.get_v_scroll_bar().max_value)
				if is_expanded and room_name.begins_with("dm_"):
					_mark_dm_read(room_name)
			
			if room_name == "global":
				var last = json[-1]
				fake_input.placeholder_text = "%s: %s" % [last.username, last.message]
			elif room_name == "local":
				fake_input.placeholder_text = "Local chat..."
			elif room_name.begins_with("dm_"):
				# Signal main menu to refresh friends list for unread badges
				friends_updated.emit()



func _add_message_to_vbox(msg: Dictionary):
	var my_name = GameManager.user_data.display_name if GameManager.user_data.display_name != "" else GameManager.user_data.username
	var is_mine = (msg.username == my_name or msg.username == GameManager.user_data.username)
	
	# Outer row: PFP | Content  (or Content | PFP for own messages)
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	messages_vbox.add_child(row)
	
	# --- PFP column ---
	var pfp = TextureRect.new()
	pfp.custom_minimum_size = Vector2(32, 32)
	pfp.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pfp.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pfp.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	pfp.mouse_filter = Control.MOUSE_FILTER_PASS
	pfp.gui_input.connect(_on_pfp_gui_input.bind(msg.username))
	_load_pfp_into(msg.get("profile_icon", "default"), pfp)
	
	# --- Content column: name row + message row ---
	var content_vbox = VBoxContainer.new()
	content_vbox.add_theme_constant_override("separation", 2)
	content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	var name_label = Label.new()
	name_label.text = msg.username
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
	
	var msg_label = RichTextLabel.new()
	msg_label.bbcode_enabled = true
	msg_label.fit_content = true
	msg_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	msg_label.text = msg.message
	
	if is_mine:
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		msg_label.text = "[right]%s[/right]" % msg.message
		content_vbox.add_child(name_label)
		content_vbox.add_child(msg_label)
		row.add_child(content_vbox)
		row.add_child(pfp)
	else:
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		content_vbox.add_child(name_label)
		content_vbox.add_child(msg_label)
		row.add_child(pfp)
		row.add_child(content_vbox)

func _on_pfp_gui_input(event: InputEvent, username: String):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if username == GameManager.user_data.username or username == GameManager.user_data.display_name:
			return # Don't popup on own pfp
		
		if not is_instance_valid(pfp_popup):
			pfp_popup = PopupMenu.new()
			add_child(pfp_popup)
			pfp_popup.add_item("Add Friend", 0)
			pfp_popup.add_item("Message", 1)
			pfp_popup.id_pressed.connect(_on_pfp_popup_id_pressed)
		
		current_target_username = username
		pfp_popup.position = get_global_mouse_position()
		pfp_popup.popup()

func _on_pfp_popup_id_pressed(id: int):
	if id == 0:
		# Add Friend
		var http = HTTPRequest.new()
		add_child(http)
		http.request_completed.connect(func(_r, _c, _h, _b): http.queue_free())
		var body = JSON.stringify({
			"user_id": GameManager.user_data.id,
			"friend_username": current_target_username
		})
		http.request(GameManager.SERVER_URL + "/api/friends/request", GameManager.get_auth_headers(), HTTPClient.METHOD_POST, body)
	elif id == 1:
		# Message
		_switch_tab("friends")
		_expand_panel()
		
		# Find the friend's user_id
		for f in accepted_friends_data:
			if f.username == current_target_username or f.get("display_name", "") == current_target_username:
				_on_friend_sidebar_clicked(f)
				break

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
	if text.strip_edges() == "": return
	if current_tab == "friends" and current_dm_room == "": return
	
	real_input.text = ""
	
	var my_name = GameManager.user_data.display_name
	if my_name == "": my_name = GameManager.user_data.username
	
	var target_room = "global"
	var state_key = current_tab # "global", "local", or "dm_..."
	if current_tab == "local": 
		target_room = room_id
	elif current_tab == "friends": 
		target_room = current_dm_room
		state_key = current_dm_room
	
	# --- Optimistic render: show message instantly without waiting for poll ---
	var local_msg = {
		"id": -1,
		"user_id": GameManager.user_data.id,
		"username": my_name,
		"message": text,
		"room_id": target_room,
		"profile_icon": GameManager.user_data.get("profile_icon", "default")
	}
	
	if not message_histories.has(state_key):
		message_histories[state_key] = []
		last_message_ids[state_key] = 0
	
	# Register as pending so the poll doesn't show it again
	_pending_sent.append({ "room_key": state_key, "username": my_name, "text": text })
	
	message_histories[state_key].append(local_msg)
	_add_message_to_vbox(local_msg)
	await get_tree().process_frame
	scroll_container.scroll_vertical = int(scroll_container.get_v_scroll_bar().max_value)
	
	# --- Send to server and update last_message_id to avoid duplicate on poll ---
	var http = HTTPRequest.new()
	add_child(http)
	var body = JSON.stringify({
		"user_id": GameManager.user_data.id,
		"username": my_name,
		"room_id": target_room,
		"message": text
	})
	http.request_completed.connect(func(_r, code, _h, resp_body):
		if code == 201:
			var json = JSON.parse_string(resp_body.get_string_from_utf8())
			if json is Dictionary and json.has("id"):
				# Advance the poll cursor past this message so it isn't fetched again
				if last_message_ids.has(state_key):
					last_message_ids[state_key] = max(last_message_ids[state_key], json.id)
				else:
					last_message_ids[state_key] = json.id
		http.queue_free()
	)
	http.request(GameManager.SERVER_URL + "/api/chat/send", GameManager.get_auth_headers(), HTTPClient.METHOD_POST, body)

func _fetch_friends_for_sidebar():
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_sidebar_friends_received.bind(http))
	http.request(GameManager.SERVER_URL + "/api/friends/" + str(GameManager.user_data.id), GameManager.get_auth_headers())
	# Signal main menu to sync unread badges
	friends_updated.emit()

func _on_sidebar_friends_received(_res, code, _headers, body, http):
	http.queue_free()
	if code != 200: return
	var json = JSON.parse_string(body.get_string_from_utf8())
	if json is Array:
		accepted_friends_data.clear()
		for c in friends_list_vbox.get_children():
			c.queue_free()
			
		for f in json:
			var is_online = bool(f.get("is_online", false))
			var has_chat = int(f.get("has_chat", 0)) == 1
			if f.status == "accepted" and (is_online or has_chat):
				accepted_friends_data.append(f)
				
				# Build a proper row: [PFP] [Name]
				var entry = PanelContainer.new()
				entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				
				var hbox = HBoxContainer.new()
				hbox.add_theme_constant_override("separation", 8)
				entry.add_child(hbox)
				
				var pfp_rect = TextureRect.new()
				pfp_rect.custom_minimum_size = Vector2(32, 32)
				pfp_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				pfp_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				pfp_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				hbox.add_child(pfp_rect)
				
				if f.get("profile_icon", "default") != "default":
					_load_pfp_into(f.profile_icon, pfp_rect)
				
				var info_vbox = VBoxContainer.new()
				info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				info_vbox.add_theme_constant_override("separation", 2)
				info_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
				hbox.add_child(info_vbox)
				
				var name_lbl = Label.new()
				name_lbl.text = f.display_name if f.get("display_name", "") != "" else f.username
				name_lbl.add_theme_font_size_override("font_size", 13)
				name_lbl.clip_text = true
				info_vbox.add_child(name_lbl)
				
				var dot = ColorRect.new()
				dot.custom_minimum_size = Vector2(6, 6)
				dot.color = Color(0.2, 1.0, 0.2) if is_online else Color(0.4, 0.4, 0.4)
				dot.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
				info_vbox.add_child(dot)
				
				# Make clickable
				entry.mouse_filter = Control.MOUSE_FILTER_STOP
				entry.gui_input.connect(func(event):
					if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
						_on_friend_sidebar_clicked(f)
				)
				
				friends_list_vbox.add_child(entry)

func _on_friend_sidebar_clicked(f: Dictionary):
	var my_id = int(GameManager.user_data.id)
	var their_id = int(f.user_id)
	var min_id = min(my_id, their_id)
	var max_id = max(my_id, their_id)
	current_dm_room = "dm_%d_%d" % [min_id, max_id]
	
	real_input.text = ""
	_rebuild_chat_view()
	_fetch_messages(current_dm_room)

	_mark_dm_read(current_dm_room)

func _mark_dm_read(dm_room: String):
	if dm_room == "":
		return

	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r, _c, _h, _b):
		http.queue_free()
		# Refresh main menu badges after DM read state changes
		friends_updated.emit()
	)
	var body = JSON.stringify({"room_id": dm_room, "reader_user_id": GameManager.user_data.id})
	http.request(GameManager.SERVER_URL + "/api/chat/mark-read", GameManager.get_auth_headers(), HTTPClient.METHOD_POST, body)

func _load_pfp_into_button(icon_name: String, btn: Button):
	if pfp_cache.has(icon_name):
		btn.icon = pfp_cache[icon_name]
		return
	var url = GameManager.SERVER_URL + "/uploads/" + icon_name
	var loader = HTTPRequest.new()
	add_child(loader)
	loader.request_completed.connect(func(_res, c, _h, b):
		if c == 200:
			var img = Image.new()
			var err = img.load_png_from_buffer(b)
			if err != OK: err = img.load_jpg_from_buffer(b)
			if err == OK:
				img.resize(24, 24)
				var tex = ImageTexture.create_from_image(img)
				pfp_cache[icon_name] = tex
				if is_instance_valid(btn): btn.icon = tex
		loader.queue_free()
	)
	loader.request(url)
