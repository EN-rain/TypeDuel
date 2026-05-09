extends Node

signal voice_state_changed(state: Dictionary)
signal opponent_voice_joined(role: String)
signal opponent_voice_left(role: String)
signal opponent_mute_changed(role: String, muted: bool)
signal voice_error(message: String)

const DEFAULT_ICE_SERVERS: Array = [
	{ "urls": ["stun:stun.l.google.com:19302"] },
]

var room_code: String = ""
var is_joined: bool = false
var is_muted: bool = false
var is_deafened: bool = false
var opponent_joined: bool = false
var opponent_muted: bool = false
var my_role: String = ""
var connection_state: String = "idle"

var _ws: WebSocketPeer = null
var _peer = null
var _ws_connected: bool = false
var _ws_join_sent: bool = false
var _pending_offer: bool = false
var _data_channel = null
var _audio_player: AudioStreamPlayer = null
var _microphone_capture: AudioEffectCapture = null
var _microphone_bus_idx: int = -1

func _ready() -> void:
	# Create audio player for opponent's voice
	_audio_player = AudioStreamPlayer.new()
	_audio_player.name = "OpponentVoicePlayer"
	_audio_player.bus = "Voice"
	add_child(_audio_player)
	
	# Setup microphone capture bus
	_microphone_bus_idx = AudioServer.get_bus_index("Record")
	if _microphone_bus_idx == -1:
		# Fallback if bus doesn't exist, though usually we should have it in project settings
		pass
	else:
		# Ensure the Record bus is actually recording from the microphone
		AudioServer.set_bus_mute(_microphone_bus_idx, false)
		for i in range(AudioServer.get_bus_effect_count(_microphone_bus_idx)):
			if AudioServer.get_bus_effect(_microphone_bus_idx, i) is AudioEffectCapture:
				_microphone_capture = AudioServer.get_bus_effect(_microphone_bus_idx, i)
				break

func _process(_delta: float) -> void:
	_poll_ws()
	if _peer != null:
		_peer.poll()

func join_room(code: String) -> void:
	if code == "" or GameManager.user_data.token == "":
		return
	var normalized = code.to_upper()
	if is_joined and room_code == normalized and _ws_connected:
		return
	if room_code != "" and room_code != normalized:
		leave_room()
	room_code = normalized
	_reset_peer()
	_connect_ws()

func leave_room() -> void:
	if room_code != "" and _ws_connected:
		_ws_send("voice:leave", { "room_code": room_code })
	_reset_peer()
	if _ws != null:
		_ws.close()
	_ws = null
	_ws_connected = false
	_ws_join_sent = false
	room_code = ""
	is_joined = false
	opponent_joined = false
	opponent_muted = false
	connection_state = "idle"
	_emit_state()

func set_muted(muted: bool) -> void:
	is_muted = muted
	if room_code != "" and _ws_connected:
		_ws_send("voice:mute", { "room_code": room_code, "muted": muted })
	_emit_state()

func toggle_mute() -> void:
	set_muted(not is_muted)

func set_deafened(deafened: bool) -> void:
	is_deafened = deafened
	_emit_state()

func toggle_deafen() -> void:
	set_deafened(not is_deafened)

func _connect_ws() -> void:
	_ws = WebSocketPeer.new()
	var ws_base = GameManager.SERVER_URL.replace("https://", "wss://").replace("http://", "ws://")
	var token = GameManager.get_auth_token().uri_encode()
	var err = _ws.connect_to_url(ws_base + "/ws?token=" + token)
	if err != OK:
		_ws = null
		connection_state = "socket_failed"
		voice_error.emit("Voice signaling connection failed.")
		_emit_state()

func _poll_ws() -> void:
	if _ws == null:
		return
	_ws.poll()
	var state = _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _ws_connected:
			_ws_connected = true
			connection_state = "signaling"
			_join_signaling()
		while _ws.get_available_packet_count() > 0:
			_on_ws_message(_ws.get_packet().get_string_from_utf8())
	elif state == WebSocketPeer.STATE_CLOSED:
		if _ws_connected:
			connection_state = "closed"
			_emit_state()
		_ws_connected = false
		_ws_join_sent = false
		is_joined = false
		opponent_joined = false
		_reset_peer()

func _join_signaling() -> void:
	if _ws_join_sent or room_code == "":
		return
	_ws_send("voice:join", { "room_code": room_code })
	_ws_join_sent = true

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
		"voice:state":
			is_joined = true
			my_role = str(json.get("role", ""))
			_apply_voice_state(json.get("voice", {}))
			_maybe_start_offer()
		"voice:joined":
			_apply_voice_state(json.get("voice", {}))
			var role = str(json.get("role", ""))
			if _is_opponent_role(role):
				opponent_voice_joined.emit(role)
				_maybe_start_offer()
		"voice:left":
			_apply_voice_state(json.get("voice", {}))
			var role = str(json.get("role", ""))
			if _is_opponent_role(role):
				opponent_voice_left.emit(role)
				_reset_peer()
		"voice:mute":
			_apply_voice_state(json.get("voice", {}))
			var role = str(json.get("role", ""))
			if _is_opponent_role(role):
				opponent_mute_changed.emit(role, bool(json.get("muted", false)))
		"voice:offer":
			if _is_opponent_role(str(json.get("from", ""))):
				_accept_offer(str(json.get("sdp", "")))
		"voice:answer":
			if _peer != null and _is_opponent_role(str(json.get("from", ""))):
				_peer.set_remote_description("answer", str(json.get("sdp", "")))
		"voice:ice":
			if _peer != null and _is_opponent_role(str(json.get("from", ""))):
				_peer.add_ice_candidate(str(json.get("media", "")), int(json.get("index", 0)), str(json.get("candidate", "")))
		"voice:error":
			voice_error.emit(str(json.get("message", "Voice signaling error.")))

func _apply_voice_state(voice: Variant) -> void:
	if not (voice is Dictionary):
		_emit_state()
		return
	if my_role == "host":
		opponent_joined = bool(voice.get("guest_joined", false))
		opponent_muted = bool(voice.get("guest_muted", false))
	elif my_role == "guest":
		opponent_joined = bool(voice.get("host_joined", false))
		opponent_muted = bool(voice.get("host_muted", false))
	_emit_state()

func _maybe_start_offer() -> void:
	if my_role != "host" or not opponent_joined:
		return
	if _pending_offer:
		return
	_pending_offer = true
	_ensure_peer()
	if _peer == null:
		_pending_offer = false
		return
	if _data_channel == null:
		_data_channel = _peer.create_data_channel("voice-control", { "negotiated": true, "id": 1 })
	var err = _peer.create_offer()
	if err != OK:
		_pending_offer = false
		voice_error.emit("Voice offer creation failed.")

func _accept_offer(sdp: String) -> void:
	if sdp == "":
		return
	_ensure_peer()
	if _peer == null:
		return
	_peer.set_remote_description("offer", sdp)
	var err = _peer.create_answer()
	if err != OK:
		voice_error.emit("Voice answer creation failed.")

func _ensure_peer() -> void:
	if _peer != null:
		return
	if not ClassDB.class_exists("WebRTCPeerConnection"):
		voice_error.emit("WebRTC is not available in this Godot build.")
		return
	_peer = ClassDB.instantiate("WebRTCPeerConnection")
	if _peer == null:
		voice_error.emit("Voice peer allocation failed.")
		return
	_peer.session_description_created.connect(_on_session_description_created)
	_peer.ice_candidate_created.connect(_on_ice_candidate_created)
	
	var err = _peer.initialize({ "iceServers": DEFAULT_ICE_SERVERS })
	if err != OK:
		voice_error.emit("Voice peer initialization failed.")
		_reset_peer()
		connection_state = "peer_failed"
		_emit_state()
		return
	connection_state = "negotiating"
	_emit_state()

func _reset_peer() -> void:
	_pending_offer = false
	if _peer != null:
		_peer.close()
	_peer = null
	_data_channel = null

func _on_session_description_created(type: String, sdp: String) -> void:
	if _peer == null:
		return
	_peer.set_local_description(type, sdp)
	if type == "offer":
		_ws_send("voice:offer", { "room_code": room_code, "type": type, "sdp": sdp })
	elif type == "answer":
		_ws_send("voice:answer", { "room_code": room_code, "type": type, "sdp": sdp })

func _on_ice_candidate_created(media: String, index: int, candidate: String) -> void:
	_ws_send("voice:ice", {
		"room_code": room_code,
		"media": media,
		"index": index,
		"candidate": candidate,
	})

func _is_opponent_role(role: String) -> bool:
	return (role == "guest" and my_role == "host") or (role == "host" and my_role == "guest")

func _emit_state() -> void:
	voice_state_changed.emit({
		"room_code": room_code,
		"joined": is_joined,
		"muted": is_muted,
		"deafened": is_deafened,
		"opponent_joined": opponent_joined,
		"opponent_muted": opponent_muted,
		"role": my_role,
		"connection_state": connection_state,
	})
