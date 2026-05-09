extends Node

signal room_polled(room: Dictionary)
signal opponent_forfeited
signal you_forfeited
signal match_ended(reason: String)

var SERVER: String:
	get: return GameManager.SERVER_URL

var sync_interval: float = 0.1
var poll_interval: float = 2.0
var last_progress_sync: float = 0.0
var last_poll_time: float = 0.0

var server_phase: String = ""
var server_phase_started_at_ms: float = 0.0
var server_typing_started_at_ms: float = 0.0
var server_first_finish_at_ms: float = 0.0
var server_first_finish_by: String = ""
var server_round_id: int = 0
var server_time_offset_ms: float = 0.0

var opp_progress: float = 0.0
var opp_typos: int = 0
var opp_chosen_skill: String = ""
var opp_skill_picked: bool = false
var opp_skills: Array = []
var opp_mutations: Array = []
var opp_mana: int = -1

const POLL_TIMEOUT_SEC: float = 5.0
const POLL_FAILS_TO_OFFLINE: int = 3
var _poll_in_flight: bool = false
var _poll_fail_streak: int = 0
var _phase_retry_attempts: int = 0
var _hp_retry_attempts: int = 0
var _hp_sync_sent_at_ms: float = 0.0
var _best_time_sync_rtt_ms: float = INF
var _last_room_seq: int = -1
var _last_mutation_index: int = 0
var _mutation_seq: int = 0
var _pending_mutations: Dictionary = {}

var _ws: WebSocketPeer = null
var _ws_connected: bool = false
var _ws_room_joined: bool = false

func _ready() -> void:
	_connect_ws()

func _process(_delta: float) -> void:
	_poll_ws()

func get_synced_server_time_ms() -> float:
	return Time.get_unix_time_from_system() * 1000.0 + server_time_offset_ms

func _connect_ws() -> void:
	if GameManager.current_room == "" or GameManager.user_data.token == "":
		return
	_ws = WebSocketPeer.new()
	var ws_base = SERVER.replace("https://", "wss://").replace("http://", "ws://")
	var err = _ws.connect_to_url(ws_base + "/ws?token=" + GameManager.get_auth_token())
	if err != OK:
		push_warning("[NetworkSync] WebSocket connect failed, HTTP polling fallback active.")
		_ws = null

func _poll_ws() -> void:
	if _ws == null:
		return

	_ws.poll()
	var state = _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _ws_connected:
			_ws_connected = true
			_ws_join_room()
		while _ws.get_available_packet_count() > 0:
			_on_ws_message(_ws.get_packet().get_string_from_utf8())
	elif state == WebSocketPeer.STATE_CLOSED:
		if _ws_connected:
			push_warning("[NetworkSync] WebSocket closed, HTTP polling fallback active.")
		_ws_connected = false
		_ws_room_joined = false

func _ws_join_room() -> void:
	if _ws_room_joined or GameManager.current_room == "":
		return
	_ws_send("match:join", { "room_code": GameManager.current_room })
	_ws_room_joined = true

func _ws_send(event: String, data: Dictionary) -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	data["event"] = event
	_ws.send_text(JSON.stringify(data))

func _on_ws_message(raw: String) -> void:
	var json = JSON.parse_string(raw)
	if not (json is Dictionary):
		return
	var event = str(json.get("event", ""))

	match event:
		"room:state", "phase:typing", "phase:skill_select":
			var room = json.get("room", null)
			if room is Dictionary:
				_apply_room_snapshot(room, -1.0, -1.0)
		"skill:picked":
			if _is_opponent_role(str(json.get("role", ""))):
				opp_chosen_skill = str(json.get("chosen_skill", ""))
				opp_skill_picked = bool(json.get("picked", true))
		"typing:progress":
			if _is_opponent_role(str(json.get("role", ""))):
				opp_progress = float(json.get("progress", opp_progress))
				opp_typos = int(json.get("typos", opp_typos))
				if json.has("mana"):
					opp_mana = int(json.get("mana"))
		"typing:mutation":
			var mutation = json.get("mutation", null)
			if mutation is Dictionary:
				opp_mutations.append(mutation)
		"typing:finished":
			if _is_opponent_role(str(json.get("role", ""))):
				opp_progress = float(json.get("progress", opp_progress))
				opp_typos = int(json.get("typos", opp_typos))
				if json.has("mana"):
					opp_mana = int(json.get("mana"))
			if json.has("first_finish_at"):
				server_first_finish_at_ms = float(json.get("first_finish_at"))
			if json.has("first_finish_by"):
				server_first_finish_by = str(json.get("first_finish_by"))
			room_polled.emit({})
		"hp:sync":
			apply_hp_from_room(json)
		"forfeit":
			_handle_forfeit(json)
		"error":
			push_warning("[NetworkSync] WebSocket server error: %s" % str(json.get("message", "")))

func _is_opponent_role(role: String) -> bool:
	return (role == "guest" and GameManager.is_host) or (role == "host" and not GameManager.is_host)

func _handle_forfeit(data: Dictionary) -> void:
	var winner = data.get("winner", null)
	var loser = data.get("loser", null)
	var reason = str(data.get("reason", "forfeit"))
	if winner == null or loser == null:
		match_ended.emit(reason)
		return
	var my_role = "host" if GameManager.is_host else "guest"
	if str(loser) == my_role:
		you_forfeited.emit()
	else:
		opponent_forfeited.emit()

func poll(current_state_is_skill_select: bool) -> void:
	if GameManager.current_room == "":
		return
	if _poll_in_flight:
		return

	var now = Time.get_ticks_msec() / 1000.0
	# Skill select always polls fast — the host fast-forward path goes through HTTP
	# even when WebSocket is connected, so the guest needs frequent polls to catch it.
	# During typing, WS handles real-time relay so 2s is fine as a safety net.
	var interval: float = 0.15 if current_state_is_skill_select else poll_interval
	if now - last_poll_time < interval:
		return
	last_poll_time = now

	var http = HTTPRequest.new()
	add_child(http)
	var sent_ms = Time.get_unix_time_from_system() * 1000.0
	http.timeout = POLL_TIMEOUT_SEC
	_poll_in_flight = true
	http.request_completed.connect(_on_poll_done.bind(http, sent_ms))
	var err = http.request(SERVER + "/api/rooms/" + GameManager.current_room, GameManager.get_auth_headers())
	if err != OK:
		_poll_in_flight = false
		if is_instance_valid(http):
			http.queue_free()
		_poll_fail_streak += 1
		if _poll_fail_streak >= POLL_FAILS_TO_OFFLINE:
			GameManager.set_connection_online(false)

func _on_poll_done(result, code, _headers, body, http: HTTPRequest, sent_ms: float) -> void:
	_poll_in_flight = false
	if is_instance_valid(http):
		http.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS:
		_poll_fail_streak += 1
		if _poll_fail_streak >= POLL_FAILS_TO_OFFLINE:
			GameManager.set_connection_online(false)
		return

	_poll_fail_streak = 0
	GameManager.set_connection_online(true)

	if code == 404:
		if not GameManager.is_solo:
			opponent_forfeited.emit()
		return
	if code != 200:
		return

	var json = JSON.parse_string(body.get_string_from_utf8())
	if json is Dictionary:
		_apply_room_snapshot(json, sent_ms, Time.get_unix_time_from_system() * 1000.0)

func _apply_room_snapshot(room: Dictionary, sent_ms: float, recv_ms: float) -> void:
	var seq = int(room.get("seq", -1))
	if seq >= 0 and _last_room_seq >= 0 and seq < _last_room_seq:
		return
	if seq >= 0:
		_last_room_seq = seq

	var forfeit = room.get("forfeit", null)
	if forfeit is Dictionary:
		_handle_forfeit(forfeit)
		return

	_apply_time_sync(room, sent_ms, recv_ms)
	_apply_phase(room)
	_apply_opponent_data(room)
	room_polled.emit(room)

func _apply_time_sync(room: Dictionary, sent_ms: float, recv_ms: float) -> void:
	if not room.has("server_now"):
		return
	var server_now = float(room.get("server_now"))
	var new_offset: float
	if sent_ms >= 0.0 and recv_ms >= sent_ms:
		var rtt = recv_ms - sent_ms
		new_offset = (server_now + rtt * 0.5) - recv_ms
		if rtt < _best_time_sync_rtt_ms:
			_best_time_sync_rtt_ms = rtt
	else:
		new_offset = server_now - (Time.get_unix_time_from_system() * 1000.0)
	if server_time_offset_ms == 0.0:
		server_time_offset_ms = new_offset
	else:
		server_time_offset_ms = lerp(server_time_offset_ms, new_offset, 0.25)

func _apply_phase(room: Dictionary) -> void:
	server_phase = str(room.get("phase", server_phase))
	server_phase_started_at_ms = float(room.get("phase_started_at", server_phase_started_at_ms))
	server_typing_started_at_ms = float(room.get("typing_started_at", server_typing_started_at_ms))
	server_first_finish_at_ms = float(room.get("first_finish_at", server_first_finish_at_ms))
	server_first_finish_by = "" if room.get("first_finish_by", null) == null else str(room.get("first_finish_by"))
	server_round_id = int(room.get("round_id", server_round_id))
	if server_phase == "skill_select":
		opp_skill_picked = false
		opp_chosen_skill = ""

func _apply_opponent_data(room: Dictionary) -> void:
	if GameManager.is_host:
		opp_progress = float(room.get("guest_progress", 0.0))
		opp_typos = int(room.get("guest_typos", 0))
		opp_chosen_skill = str(room.get("guest_skill", ""))
		opp_skill_picked = bool(room.get("guest_skill_picked", false))
		opp_mutations = room.get("host_mutations", [])
		opp_skills = room.get("guest_skills", [])
		if room.has("guest_mana"):
			opp_mana = int(room.get("guest_mana"))
	else:
		opp_progress = float(room.get("host_progress", 0.0))
		opp_typos = int(room.get("host_typos", 0))
		opp_chosen_skill = str(room.get("host_skill", ""))
		opp_skill_picked = bool(room.get("host_skill_picked", false))
		opp_mutations = room.get("guest_mutations", [])
		opp_skills = room.get("host_skills", [])
		if room.has("host_mana"):
			opp_mana = int(room.get("host_mana"))

func consume_new_mutations() -> Array:
	var result: Array = []
	while _last_mutation_index < opp_mutations.size():
		result.append(opp_mutations[_last_mutation_index])
		_last_mutation_index += 1
	return result

func reset_mutation_index() -> void:
	_last_mutation_index = 0
	_mutation_seq = 0
	_pending_mutations.clear()

func emit_skill_pick(chosen_skill: String) -> void:
	if _ws_connected:
		_ws_send("skill:pick", {
			"room_code": GameManager.current_room,
			"chosen_skill": chosen_skill,
		})

func set_phase(phase: String, round_id: int) -> void:
	if GameManager.current_room == "" or GameManager.user_data.id == 0:
		return

	# WebSocket fast path — broadcast phase change to the room immediately.
	# This covers both skill_select (new round) and typing (host fast-forward),
	# so the guest doesn't have to wait for the next HTTP poll to learn about it.
	if _ws_connected:
		if phase == "skill_select":
			_ws_send("phase:skill_select", {
				"room_code": GameManager.current_room,
				"round_id":  round_id,
			})
		elif phase == "typing":
			_ws_send("phase:typing", {
				"room_code": GameManager.current_room,
				"round_id": round_id,
			})

	var payload: Dictionary = { "user_id": GameManager.user_data.id, "phase": phase }
	if round_id > 0:
		payload["round_id"] = round_id
	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = POLL_TIMEOUT_SEC
	http.request_completed.connect(func(result, _code, _h, body):
		if is_instance_valid(http):
			http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS:
			if _phase_retry_attempts < 3:
				_phase_retry_attempts += 1
				get_tree().create_timer(0.5 * float(_phase_retry_attempts)).timeout.connect(func(): set_phase(phase, round_id))
			return
		_phase_retry_attempts = 0
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json is Dictionary and json.get("room", null) is Dictionary:
			_apply_room_snapshot(json.get("room"), -1.0, -1.0)
	)
	http.request(SERVER + "/api/rooms/" + GameManager.current_room + "/phase",
		GameManager.get_auth_headers(), HTTPClient.METHOD_PATCH, JSON.stringify(payload))

func sync_progress_with_queue(current_index: int, sentence_length: int, typos: int,
	chosen_skill: String, mutation_queue: Array, accuracy_warning_visible: bool) -> void:
	if GameManager.current_room == "" or GameManager.user_data.id == 0:
		return
	var now = Time.get_ticks_msec() / 1000.0
	if now - last_progress_sync < sync_interval:
		return
	last_progress_sync = now

	var progress = float(current_index) / float(sentence_length) if sentence_length > 0 else 0.0
	if accuracy_warning_visible:
		progress = minf(progress, 0.98)

	var mutation: Dictionary = {}
	if mutation_queue.size() > 0:
		mutation = mutation_queue.front()
		_mutation_seq += 1
		mutation["seq"] = _mutation_seq
		_pending_mutations[_mutation_seq] = mutation
		if _ws_connected:
			mutation_queue.pop_front()
			_ws_send("typing:mutation", { "room_code": GameManager.current_room, "mutation": mutation })

	if _ws_connected:
		_ws_send("typing:progress", {
			"room_code": GameManager.current_room,
			"progress": progress,
			"typos": typos,
			"mana": SkillsManager.player_mana,
			"chosen_skill": chosen_skill,
		})
		return

	_http_progress(progress, typos, chosen_skill, mutation, mutation_queue)

func sync_progress_immediate(current_index: int, sentence_length: int, typos: int, chosen_skill: String) -> void:
	if GameManager.current_room == "" or GameManager.user_data.id == 0:
		return
	last_progress_sync = Time.get_ticks_msec() / 1000.0
	var progress = float(current_index) / float(sentence_length) if sentence_length > 0 else 0.0
	var event = "typing:finished" if progress >= 0.999 else "typing:progress"
	if _ws_connected:
		_ws_send(event, {
			"room_code": GameManager.current_room,
			"progress": progress,
			"typos": typos,
			"mana": SkillsManager.player_mana,
			"chosen_skill": chosen_skill,
		})
	_http_progress(progress, typos, chosen_skill)

func _http_progress(progress: float, typos: int, chosen_skill: String, mutation: Dictionary = {}, mutation_queue: Array = []) -> void:
	var payload: Dictionary = {
		"user_id": GameManager.user_data.id,
		"progress": progress,
		"typos": typos,
		"mana": SkillsManager.player_mana,
		"chosen_skill": chosen_skill,
	}
	if not mutation.is_empty():
		payload["send_mutation"] = mutation
	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = POLL_TIMEOUT_SEC
	http.request_completed.connect(func(_r, _c, _h, body):
		if is_instance_valid(http):
			http.queue_free()
		if _c >= 200 and _c < 300 and not mutation.is_empty() and mutation_queue.size() > 0:
			var queued = mutation_queue.front()
			if queued is Dictionary and int(queued.get("seq", -1)) == int(mutation.get("seq", -2)):
				mutation_queue.pop_front()
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json is Dictionary and json.get("room", null) is Dictionary:
			_apply_room_snapshot(json.get("room"), -1.0, -1.0)
	)
	http.request(SERVER + "/api/rooms/" + GameManager.current_room + "/progress",
		GameManager.get_auth_headers(), HTTPClient.METHOD_PATCH, JSON.stringify(payload))

func sync_hp() -> void:
	if GameManager.current_room == "" or GameManager.user_data.id == 0:
		return
	if GameManager.is_solo or not GameManager.is_host:
		return
	_hp_sync_sent_at_ms = Time.get_ticks_msec()
	var data = {
		"room_code": GameManager.current_room,
		"host_hp": HPManager.player_hp,
		"guest_hp": HPManager.opponent_hp,
		"host_streak": SkillsManager.player_win_streak,
		"guest_streak": SkillsManager.opponent_win_streak,
	}
	if _ws_connected:
		_ws_send("hp:sync", data.duplicate())
	data["user_id"] = GameManager.user_data.id
	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = POLL_TIMEOUT_SEC
	http.request_completed.connect(func(result, _c, _h, _b):
		if is_instance_valid(http):
			http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS and _hp_retry_attempts < 3:
			_hp_retry_attempts += 1
			get_tree().create_timer(0.5 * float(_hp_retry_attempts)).timeout.connect(func(): sync_hp())
		else:
			_hp_retry_attempts = 0
	)
	http.request(SERVER + "/api/rooms/" + GameManager.current_room + "/hp",
		GameManager.get_auth_headers(), HTTPClient.METHOD_PATCH, JSON.stringify(data))

func apply_hp_from_room(room: Dictionary) -> void:
	if not (room.has("host_hp") and room.has("guest_hp")):
		return
	var host_hp = float(room.get("host_hp", 0))
	var guest_hp = float(room.get("guest_hp", 0))
	if host_hp == 0 and guest_hp == 0:
		return
	if GameManager.is_host and _hp_sync_sent_at_ms > 0 and Time.get_ticks_msec() - _hp_sync_sent_at_ms < 1500:
		return
	if GameManager.is_host:
		HPManager.set_hp("player", host_hp)
		HPManager.set_hp("opponent", guest_hp)
	else:
		HPManager.set_hp("player", guest_hp)
		HPManager.set_hp("opponent", host_hp)
		if room.has("host_streak") and room.has("guest_streak"):
			SkillsManager.opponent_win_streak = int(room.get("host_streak"))
			SkillsManager.player_win_streak = int(room.get("guest_streak"))

func delete_room() -> void:
	if GameManager.current_room == "":
		return
	if _ws_connected:
		_ws_send("forfeit", { "room_code": GameManager.current_room })
	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = POLL_TIMEOUT_SEC
	http.request_completed.connect(func(_r, _c, _h, _b):
		if is_instance_valid(http):
			http.queue_free()
	)
	if GameManager.is_host:
		http.request(SERVER + "/api/rooms/" + GameManager.current_room,
			GameManager.get_auth_headers(), HTTPClient.METHOD_DELETE)
	else:
		http.request(SERVER + "/api/rooms/" + GameManager.current_room + "/leave",
			GameManager.get_auth_headers(), HTTPClient.METHOD_POST)
