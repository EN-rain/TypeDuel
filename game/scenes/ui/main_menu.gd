extends Control




# ── Constants ────────────────────────────────────────────────────────────────
const SCENE_CUSTOM_ROOM = "res://scenes/ui/custom_room.tscn"
const SCENE_LEADERBOARD = "res://scenes/ui/leaderboard.tscn"
const SCENE_SETTINGS    = "res://scenes/ui/settings.tscn"
const SCENE_LOGIN       = "res://scenes/ui/login_scene.tscn"

const TEXT_PLAY_ONLINE       = "Play Online"
const TEXT_CANCEL_MATCHMAKE  = "Cancel Matchmaking"
const TEXT_JOINING           = "Joining..."
const TEXT_WAITING_OPPONENT  = "Waiting for opponent..."
const TEXT_MATCHMAKE_FAILED  = "Matchmaking failed."
const TEXT_SENDING_REQUEST   = "Sending request..."
const TEXT_GREETING          = "Hi, %s!"
const TEXT_PLAYER_ONLINE     = "● 1 player online"
const TEXT_PLAYERS_ONLINE    = "● %d players online"

# ── Nodes ────────────────────────────────────────────────────────────────────
@onready var greeting_label         = %Greeting
@onready var online_count_label      = %OnlineCount
@onready var join_panel              = %JoinPanel
@onready var join_input              = %CodeInput
@onready var join_error              = %ErrorLabel
@onready var matchmaking_label       = %MatchmakingLabel
@onready var matchmaking_time_label  = %MatchmakingTime
@onready var play_online_btn         = %PlayOnlineButton
@onready var friends_button          = %FriendsButton
@onready var friends_dimmer          = %FriendsDimmer
@onready var friends_panel           = %FriendsPanel
@onready var friends_list            = friends_panel.get_node("%FriendsList")
@onready var friend_search_input     = friends_panel.get_node("%SearchInput")
@onready var friend_status_label     = friends_panel.get_node("%StatusLabel")

var is_matchmaking = false
var matchmaking_start_time = 0.0
var matchmaking_code = ""
var poll_timer = 0.0
var _heartbeat_timer: float = 0.0
var current_friends_data = []
var showing_requests = false

func _ready():
	var name_to_show = GameManager.user_data.display_name
	if name_to_show == "":
		name_to_show = GameManager.user_data.username
	greeting_label.text = TEXT_GREETING % name_to_show
	
	_fetch_online_count()
	_send_heartbeat()
	
	matchmaking_label.hide()
	matchmaking_time_label.hide()
	
	friends_panel.z_index = 100
	friends_panel.top_level = true
	friends_dimmer.z_index = 99
	friends_dimmer.top_level = true
	
	# friends_button.pressed connection is now in the .tscn
	friends_panel.get_node("%AddBtn").pressed.connect(_on_add_friend_pressed)
	friends_panel.get_node("%ReqBtn").pressed.connect(_on_req_btn_pressed)
	friends_dimmer.pressed.connect(_collapse_friends)
	
	$HistoryButton.pressed.connect(_on_history_pressed)
	
	_setup_chat()

func _setup_chat():
	if has_node("%ChatBox"):
		%ChatBox.room_id = "global"



func _process(delta):
	_heartbeat_timer += delta
	if _heartbeat_timer >= 15.0:
		_heartbeat_timer = 0.0
		_send_heartbeat()
		_fetch_online_count()
	
	if is_matchmaking:
		var elapsed = Time.get_ticks_msec() / 1000.0 - matchmaking_start_time
		var minutes = int(elapsed / 60.0)
		var seconds = int(elapsed) % 60
		matchmaking_time_label.text = "Time: %d:%02d" % [minutes, seconds]
		
		if matchmaking_code != "":
			poll_timer += delta
			if poll_timer >= 2.0:
				poll_timer = 0.0
				_check_matchmaking_status()

# ── Heartbeat & Online Count ──────────────────────────────────────────────

func _fetch_online_count():
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_online_count_received.bind(http))
	http.request(GameManager.SERVER_URL + "/api/game/online-count")

func _on_online_count_received(_result, code, _headers, body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()
	if code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json and json.has("online"):
			var c = json["online"]
			if c == 1:
				online_count_label.text = TEXT_PLAYER_ONLINE
			else:
				online_count_label.text = TEXT_PLAYERS_ONLINE % c

func _send_heartbeat():
	if GameManager.user_data.id == 0:
		return
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_heartbeat_done.bind(http))
	var body = JSON.stringify({ "user_id": GameManager.user_data.id, "session_id": GameManager.session_id })
	http.request(GameManager.SERVER_URL + "/api/game/heartbeat", ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)

func _on_heartbeat_done(_result, _code, _headers, _body, http: HTTPRequest):
	if is_instance_valid(http):
		http.queue_free()

# ── Actions ──────────────────────────────────────────────────────────────────

func _on_solo_play_pressed():
	print("Solo Play pressed")
	GameManager.is_host = true
	GameManager.is_solo = true
	GameManager.current_room = ""
	get_tree().change_scene_to_file(SCENE_CUSTOM_ROOM)

func _on_custom_room_pressed():
	print("Custom Room pressed")
	GameManager.is_host = true
	GameManager.is_solo = false
	GameManager.current_room = ""
	get_tree().change_scene_to_file(SCENE_CUSTOM_ROOM)

func _on_join_pressed():
	join_panel.visible = true
	join_input.text = ""
	join_error.text = ""

func _on_cancel_join_pressed():
	join_panel.visible = false

func _on_submit_join_pressed():
	var code = join_input.text.strip_edges().to_upper()
	if code.length() != 6:
		join_error.text = "Code must be 6 characters."
		return
	
	join_error.text = TEXT_JOINING
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_join_done.bind(http))
	var my_name = GameManager.user_data.display_name
	if my_name == "":
		my_name = GameManager.user_data.username
	var body = JSON.stringify({
		"user_id": GameManager.user_data.id,
		"display_name": my_name,
		"code": code
	})
	http.request(GameManager.SERVER_URL + "/api/rooms/join", ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)

func _on_join_done(_result, req_code, _headers, body, http):
	if is_instance_valid(http):
		http.queue_free()
	var json = {}
	if body.size() > 0:
		json = JSON.parse_string(body.get_string_from_utf8())
		
	if req_code == 200:
		GameManager.current_room = join_input.text.strip_edges().to_upper()
		GameManager.is_host = false
		GameManager.is_solo = false
		get_tree().change_scene_to_file(SCENE_CUSTOM_ROOM)
	else:
		if json and json.has("message"):
			join_error.text = json["message"]
		elif req_code == 403:
			join_error.text = "That's your own room!"
		elif req_code == 404:
			join_error.text = "Room not found."
		elif req_code == 409:
			join_error.text = "Room is full."
		else:
			join_error.text = "Failed to join room."

func _on_play_online_pressed():
	if is_matchmaking:
		# Cancel matchmaking
		is_matchmaking = false
		matchmaking_label.hide()
		matchmaking_time_label.hide()
		play_online_btn.text = "Play Online"
		matchmaking_code = ""
		return

	print("Starting Matchmaking...")
	is_matchmaking = true
	matchmaking_start_time = Time.get_ticks_msec() / 1000.0
	matchmaking_label.show()
	matchmaking_time_label.show()
	play_online_btn.text = TEXT_CANCEL_MATCHMAKE
	
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_matchmake_done.bind(http))
	var my_name = GameManager.user_data.display_name
	if my_name == "":
		my_name = GameManager.user_data.username
	var body = JSON.stringify({
		"user_id": GameManager.user_data.id,
		"display_name": my_name
	})
	http.request(GameManager.SERVER_URL + "/api/rooms/matchmake", ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)

func _on_matchmake_done(_result, code, _headers, body, http):
	if is_instance_valid(http):
		http.queue_free()
	if not is_matchmaking: return # already cancelled
	
	if code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json.role == "guest":
			# Found a match instantly
			GameManager.current_room = json.room.code
			GameManager.is_host = false
			GameManager.is_solo = false
			get_tree().change_scene_to_file(SCENE_CUSTOM_ROOM)
		else:
			# Waiting for guest
			matchmaking_code = json.code
			matchmaking_label.text = TEXT_WAITING_OPPONENT
	else:
		is_matchmaking = false
		matchmaking_label.text = TEXT_MATCHMAKE_FAILED
		play_online_btn.text = TEXT_PLAY_ONLINE

func _check_matchmaking_status():
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_poll_match_done.bind(http))
	http.request(GameManager.SERVER_URL + "/api/rooms/" + matchmaking_code)

func _on_poll_match_done(_result, code, _headers, body, http):
	if is_instance_valid(http):
		http.queue_free()
	if not is_matchmaking: return
	
	if code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json.guest_id:
			# Guest joined!
			GameManager.current_room = matchmaking_code
			GameManager.is_host = true
			GameManager.is_solo = false
			get_tree().change_scene_to_file(SCENE_CUSTOM_ROOM)

func _on_leaderboard_pressed():
	get_tree().change_scene_to_file(SCENE_LEADERBOARD)

func _on_settings_pressed():
	get_tree().change_scene_to_file(SCENE_SETTINGS)

func _on_logout_pressed():
	# Clear session
	GameManager.user_data = {
		"id": 0,
		"username": "",
		"display_name": "",
		"token": ""
	}
	get_tree().change_scene_to_file(SCENE_LOGIN)

# ── Friends System ───────────────────────────────────────────────────────────

var friend_entry_scene = preload("res://scenes/ui/friend_entry.tscn")
var is_friends_expanded = false

func _on_friends_pressed():
	if is_friends_expanded:
		_collapse_friends()
	else:
		_expand_friends()

func _on_history_pressed():
	get_tree().change_scene_to_file("res://scenes/ui/history.tscn")

func _expand_friends():
	is_friends_expanded = true
	friends_dimmer.show()
	friends_panel.show()
	friends_panel.position.x = get_viewport_rect().size.x
	var tween = create_tween()
	tween.tween_property(friends_panel, "position:x", get_viewport_rect().size.x - friends_panel.size.x, 0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_refresh_friends_list()

func _collapse_friends():
	is_friends_expanded = false
	friends_dimmer.hide()
	var tween = create_tween()
	tween.tween_property(friends_panel, "position:x", get_viewport_rect().size.x, 0.6).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.finished.connect(func(): friends_panel.hide())

func _on_add_friend_pressed():
	var username = friend_search_input.text.strip_edges()
	if username == "": return
	
	friend_status_label.text = TEXT_SENDING_REQUEST
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_friend_request_done.bind(http))
	var body = JSON.stringify({
		"user_id": GameManager.user_data.id,
		"friend_username": username
	})
	http.request(GameManager.SERVER_URL + "/api/friends/request", ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)

func _on_friend_request_done(_result, code, _headers, body, http):
	http.queue_free()
	var json = JSON.parse_string(body.get_string_from_utf8())
	if code == 200:
		friend_status_label.text = "Request sent to " + friend_search_input.text
		friend_search_input.text = ""
		_refresh_friends_list()
	else:
		friend_status_label.text = json.get("message", "Error adding friend")

func _refresh_friends_list():
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_friends_list_received.bind(http))
	http.request(GameManager.SERVER_URL + "/api/friends/" + str(GameManager.user_data.id))

func _on_friends_list_received(_result, code, _headers, body, http):
	http.queue_free()
	if code != 200: return
	
	var json = JSON.parse_string(body.get_string_from_utf8())
	if json is Array:
		current_friends_data = json
		
		var pending_incoming_count = 0
		for f in current_friends_data:
			if f.status == "pending" and f.get("is_incoming_request", 0) == 1:
				pending_incoming_count += 1
				
		var label = friends_button.get_node_or_null("Label")
		if label:
			if pending_incoming_count > 0:
				label.text = str(pending_incoming_count)
				label.show()
			else:
				label.hide()
				
		_render_friends_list()

func _on_req_btn_pressed():
	showing_requests = !showing_requests
	var btn = friends_panel.get_node("%ReqBtn")
	if showing_requests:
		btn.modulate = Color(0, 1, 0)
	else:
		btn.modulate = Color(1, 1, 1)
	_render_friends_list()

func _render_friends_list():
	var to_show = []
	for f in current_friends_data:
		if showing_requests:
			if f.status == "pending" and f.get("is_incoming_request", 0) == 1:
				to_show.append(f)
		else:
			if f.status == "accepted":
				to_show.append(f)
				
	# Sort: Online > Pending > Offline
	to_show.sort_custom(func(a, b):
		var a_score = 0
		if a.is_online: a_score = 2
		elif a.status == "pending": a_score = 1
		
		var b_score = 0
		if b.is_online: b_score = 2
		elif b.status == "pending": b_score = 1
		
		return a_score > b_score
	)
	
	for child in friends_list.get_children():
		child.queue_free()
		
	for f in to_show:
		_create_friend_entry(f)

func _create_friend_entry(data: Dictionary):
	var entry = friend_entry_scene.instantiate()
	friends_list.add_child(entry)
	
	var name_label = entry.get_node("%NameLabel")
	var status_label = entry.get_node("%StatusLabel")
	var status_dot = entry.get_node("%StatusDot")
	var avatar_icon = entry.get_node("%AvatarIcon")
	var action_btn = entry.get_node("%ActionBtn")
	var remove_btn = entry.get_node("%RemoveBtn")
	
	name_label.text = data.display_name if data.display_name else data.username
	
	# Set Profile Icon
	if data.get("profile_icon") and data.profile_icon != "default":
		var icon_name = data.profile_icon
		var url = GameManager.SERVER_URL + "/uploads/" + icon_name
		var loader = HTTPRequest.new()
		add_child(loader)
		loader.request_completed.connect(func(_result, response_code, _headers, body):
			if response_code == 200:
				var image = Image.new()
				var error = image.load_png_from_buffer(body)
				if error != OK:
					error = image.load_jpg_from_buffer(body)
				
				if error == OK:
					avatar_icon.texture = ImageTexture.create_from_image(image)
			loader.queue_free()
		)
		loader.request(url)
	else:
		# Use a placeholder or nothing
		avatar_icon.texture = null
	
	if data.status == "pending":
		status_label.text = "Pending"
		status_label.modulate = Color(1, 1, 0)
		status_dot.color = Color(1, 1, 0)
		action_btn.text = "✔️"
		action_btn.pressed.connect(_on_accept_friend.bind(data.user_id))
	else:
		if data.is_online:
			status_label.text = "Online"
			status_label.modulate = Color(0, 1, 0)
			status_dot.color = Color(0, 1, 0)
		else:
			status_label.text = "Offline"
			status_label.modulate = Color(0.6, 0.6, 0.6)
			status_dot.color = Color(0.4, 0.4, 0.4)
		action_btn.hide()
	remove_btn.pressed.connect(_on_remove_friend.bind(data.user_id))
	
	entry.mouse_filter = Control.MOUSE_FILTER_PASS
	entry.gui_input.connect(_on_friend_entry_gui_input.bind(data))
	
	avatar_icon.mouse_filter = Control.MOUSE_FILTER_PASS
	avatar_icon.gui_input.connect(_on_friend_entry_gui_input.bind(data))
	
	name_label.mouse_filter = Control.MOUSE_FILTER_PASS
	name_label.gui_input.connect(_on_friend_entry_gui_input.bind(data))

var _friend_context_menu: PopupMenu

func _on_friend_entry_gui_input(event: InputEvent, data: Dictionary):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if _friend_context_menu == null:
			_friend_context_menu = PopupMenu.new()
			add_child(_friend_context_menu)
			_friend_context_menu.id_pressed.connect(_on_friend_context_menu_id_pressed)
		
		_friend_context_menu.clear()
		# Only allow history and message if they are accepted friends
		if data.status == "accepted":
			_friend_context_menu.add_item("History", 0)
			_friend_context_menu.add_item("Message", 1)
		_friend_context_menu.add_item("Remove", 2)
		
		_friend_context_menu.set_meta("target_user_id", data.user_id)
		_friend_context_menu.set_meta("target_username", data.username)
		_friend_context_menu.position = get_viewport().get_mouse_position()
		_friend_context_menu.popup()

func _on_friend_context_menu_id_pressed(id: int):
	var target_user_id = _friend_context_menu.get_meta("target_user_id")
	var target_username = _friend_context_menu.get_meta("target_username")
	
	if id == 0: # History
		GameManager.viewing_history_id = target_user_id
		get_tree().change_scene_to_file("res://scenes/ui/history.tscn")
	elif id == 1: # Message
		if has_node("%ChatBox"):
			var chat = get_node("%ChatBox")
			chat._switch_tab("friends")
			chat._expand_panel()
			chat.real_input.text = "@" + target_username + " "
			chat.real_input.caret_column = chat.real_input.text.length()
	elif id == 2: # Remove
		_on_remove_friend(target_user_id)



func _on_accept_friend(friend_id: int):
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r, _c, _h, _b, _ht): _ht.queue_free(); _refresh_friends_list()).bind(http)
	var body = JSON.stringify({
		"user_id": GameManager.user_data.id,
		"friend_id": friend_id
	})
	http.request(GameManager.SERVER_URL + "/api/friends/accept", ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)

func _on_remove_friend(friend_id: int):
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r, _c, _h, _b, _ht): _ht.queue_free(); _refresh_friends_list()).bind(http)
	var body = JSON.stringify({
		"user_id": GameManager.user_data.id,
		"friend_id": friend_id
	})
	http.request(GameManager.SERVER_URL + "/api/friends/remove", ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
