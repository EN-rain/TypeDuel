class_name LobbyNetworkService
## Network service for lobby operations (polling, sync, heartbeat, room CRUD)
## All methods are static utility functions that take a parent_node to attach HTTPRequest.
extends Object

const REQUEST_TIMEOUT_SEC = 5.0

## Generic HTTP request helper
static func _request(
	parent_node: Node,
	method: HTTPClient.Method,
	url: String,
	headers: PackedStringArray,
	body: String = "",
	callback: Callable = Callable()
) -> void:
	var http = HTTPRequest.new()
	parent_node.add_child(http)
	http.timeout = REQUEST_TIMEOUT_SEC
	if callback.is_valid():
		http.request_completed.connect(callback.bind(http))
	else:
		# Default: free http node on completion
		http.request_completed.connect(func(_r, _c, _h, _b): http.queue_free())
	var err = http.request(url, headers, method, body)
	if err != OK:
		push_error("[LobbyNetwork] HTTP request failed: %s" % url)
		if callback.is_valid():
			# Call callback with error? We'll just let it fail silently; caller should handle
			pass

## GET /api/rooms/:code
static func poll_room(parent_node: Node, room_code: String, callback: Callable) -> void:
	var url = GameManager.SERVER_URL + "/api/rooms/" + room_code
	_request(parent_node, HTTPClient.METHOD_GET, url, GameManager.get_auth_headers(), "", callback)

## PATCH /api/rooms/:code/select
static func sync_selections(
	parent_node: Node,
	room_code: String,
	user_id: int,
	character: String,
	skills: Array,
	passive: String,
	callback: Callable
) -> void:
	var url = GameManager.SERVER_URL + "/api/rooms/" + room_code + "/select"
	var body = JSON.stringify({
		"user_id": user_id,
		"character": character,
		"skills": skills,
		"passive": passive
	})
	_request(parent_node, HTTPClient.METHOD_PATCH, url, GameManager.get_auth_headers(), body, callback)

## POST /api/game/heartbeat
static func send_heartbeat(parent_node: Node, user_id: int, callback: Callable = Callable()) -> void:
	if user_id == 0:
		return
	var url = GameManager.SERVER_URL + "/api/game/heartbeat"
	var body = JSON.stringify({ "user_id": user_id })
	if callback.is_valid():
		_request(parent_node, HTTPClient.METHOD_POST, url, GameManager.get_auth_headers(), body, callback)
	else:
		# Fire-and-forget: free automatically
		_request(parent_node, HTTPClient.METHOD_POST, url, GameManager.get_auth_headers(), body)

## POST /api/rooms/create
static func create_room(
	parent_node: Node,
	user_id: int,
	display_name: String,
	code: String,
	callback: Callable
) -> void:
	var url = GameManager.SERVER_URL + "/api/rooms/create"
	var body = JSON.stringify({ "user_id": user_id, "display_name": display_name, "code": code })
	_request(parent_node, HTTPClient.METHOD_POST, url, GameManager.get_auth_headers(), body, callback)

## POST /api/rooms/:code/start
static func start_room(parent_node: Node, room_code: String, callback: Callable) -> void:
	var url = GameManager.SERVER_URL + "/api/rooms/" + room_code + "/start"
	_request(parent_node, HTTPClient.METHOD_POST, url, GameManager.get_auth_headers(), "", callback)

## POST /api/rooms/:code/leave
static func leave_room(parent_node: Node, room_code: String, callback: Callable = Callable()) -> void:
	var url = GameManager.SERVER_URL + "/api/rooms/" + room_code + "/leave"
	if callback.is_valid():
		_request(parent_node, HTTPClient.METHOD_POST, url, GameManager.get_auth_headers(), "", callback)
	else:
		_request(parent_node, HTTPClient.METHOD_POST, url, GameManager.get_auth_headers(), "")

## DELETE /api/rooms/:code
static func delete_room(parent_node: Node, room_code: String, callback: Callable = Callable()) -> void:
	var url = GameManager.SERVER_URL + "/api/rooms/" + room_code
	if callback.is_valid():
		_request(parent_node, HTTPClient.METHOD_DELETE, url, GameManager.get_auth_headers(), "", callback)
	else:
		_request(parent_node, HTTPClient.METHOD_DELETE, url, GameManager.get_auth_headers(), "")

## POST /api/game/matchmaking-penalty
static func apply_matchmaking_penalty(parent_node: Node, user_id: int, duration_ms: int, callback: Callable = Callable()) -> void:
	var url = GameManager.SERVER_URL + "/api/game/matchmaking-penalty"
	var body = JSON.stringify({ "user_id": user_id, "duration_ms": duration_ms })
	if callback.is_valid():
		_request(parent_node, HTTPClient.METHOD_POST, url, GameManager.get_auth_headers(), body, callback)
	else:
		_request(parent_node, HTTPClient.METHOD_POST, url, GameManager.get_auth_headers(), body)
