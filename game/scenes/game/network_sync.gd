extends Node

## NetworkSync
## Owns all HTTP communication with the server during a match:
## polling opponent state, syncing progress, and declaring phase changes.
## Attach to a child node named "NetworkSync" under the Game scene root.

signal room_polled(room: Dictionary)
signal opponent_forfeited
signal you_forfeited
signal match_ended(reason: String)

var SERVER: String:
	get: return GameManager.SERVER_URL

var sync_interval: float = 0.3
var poll_interval: float = 0.5

var last_progress_sync: float = 0.0
var last_poll_time: float     = 0.0

# Server-authoritative state (read by Game)
var server_phase: String              = ""
var server_phase_started_at_ms: float = 0.0
var server_typing_started_at_ms: float = 0.0
var server_first_finish_at_ms: float  = 0.0
var server_first_finish_by: String    = ""
var server_round_id: int              = 0
var server_time_offset_ms: float      = 0.0

var _best_time_sync_rtt_ms: float = INF
var _last_room_seq: int = -1

# Connection health (during gameplay)
const POLL_TIMEOUT_SEC: float = 5.0
const POLL_FAILS_TO_OFFLINE: int = 3
var _poll_in_flight: bool = false
var _poll_fail_streak: int = 0
var _phase_retry_attempts: int = 0
var _hp_retry_attempts: int = 0

func _schedule_phase_retry(phase: String, round_id: int) -> void:
	var delay = 0.5 * float(_phase_retry_attempts)
	get_tree().create_timer(delay).timeout.connect(func(): set_phase(phase, round_id))

func _schedule_hp_retry() -> void:
	var delay = 0.5 * float(_hp_retry_attempts)
	get_tree().create_timer(delay).timeout.connect(func(): sync_hp())

# Opponent data (read by Game / TypingHandler)
var opp_progress: float  = 0.0
var opp_typos: int       = 0
var opp_chosen_skill: String = ""
var opp_skills: Array    = []
var opp_mutations: Array = []
var opp_mana: int        = -1  # -1 = not synced yet, use estimation
var _last_mutation_index: int = 0

func get_synced_server_time_ms() -> float:
	return Time.get_unix_time_from_system() * 1000.0 + server_time_offset_ms

# ─────────────────────────────────────────────
#  Polling
# ─────────────────────────────────────────────

func poll(current_state_is_skill_select: bool) -> void:
	if GameManager.current_room == "": return
	if _poll_in_flight:
		return
	var now = Time.get_ticks_msec() / 1000.0
	var interval = 0.15 if current_state_is_skill_select else poll_interval
	if now - last_poll_time < interval: return
	last_poll_time = now

	var http = HTTPRequest.new()
	add_child(http)
	var sent_ms: float = Time.get_unix_time_from_system() * 1000.0
	http.timeout = POLL_TIMEOUT_SEC
	_poll_in_flight = true
	http.request_completed.connect(_on_poll_done.bind(http, sent_ms))
	var err = http.request(SERVER + "/api/rooms/" + GameManager.current_room, GameManager.get_auth_headers())
	if err != OK:
		_poll_in_flight = false
		if is_instance_valid(http): http.queue_free()
		_poll_fail_streak += 1
		if _poll_fail_streak >= POLL_FAILS_TO_OFFLINE:
			GameManager.set_connection_online(false)

func _on_poll_done(result, code, _headers, body, http, sent_ms: float):
	_poll_in_flight = false
	if is_instance_valid(http): http.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS:
		_poll_fail_streak += 1
		if _poll_fail_streak >= POLL_FAILS_TO_OFFLINE:
			GameManager.set_connection_online(false)
		return

	# A response (even 404) means the server is reachable.
	_poll_fail_streak = 0
	GameManager.set_connection_online(true)

	if code == 404:
		# Legacy behavior: room deleted. Treat as forfeit/termination.
		if not GameManager.is_solo:
			opponent_forfeited.emit()
		return
	if code != 200:
		return

	var recv_ms: float = Time.get_unix_time_from_system() * 1000.0
	var raw = body.get_string_from_utf8()
	var json = JSON.parse_string(raw)
	if not json:
		if raw.length() > 0:
			push_warning("[NetworkSync] JSON parse failed: %s" % raw.left(120))
		return

	var seq = int(json.get("seq", -1))
	if seq >= 0 and _last_room_seq >= 0 and seq < _last_room_seq:
		return
	if seq >= 0: _last_room_seq = seq

	# Server-authoritative forfeit (room stays alive briefly so both clients converge)
	var forfeit = json.get("forfeit", null)
	if forfeit != null:
		var reason = str(forfeit.get("reason", "forfeit"))
		var winner = forfeit.get("winner", null)
		var loser = forfeit.get("loser", null)

		# If server can't determine a winner (e.g., both disconnected), end match without declaring forfeit.
		if winner == null or loser == null:
			match_ended.emit(reason)
			return

		var i_am_role = "host" if GameManager.is_host else "guest"
		if String(loser) == i_am_role:
			you_forfeited.emit()
		else:
			opponent_forfeited.emit()
		return

	_apply_time_sync(json, sent_ms, recv_ms)
	_apply_phase(json)
	_apply_opponent_data(json)

	room_polled.emit(json)

func _apply_time_sync(room: Dictionary, sent_ms: float, recv_ms: float) -> void:
	if not room.has("server_now"): return
	var server_now: float = float(room.get("server_now"))
	var local_now:  float = Time.get_unix_time_from_system() * 1000.0
	var new_offset: float
	if sent_ms >= 0.0 and recv_ms >= sent_ms:
		var rtt: float = recv_ms - sent_ms
		new_offset = (server_now + rtt * 0.5) - recv_ms
		if rtt < _best_time_sync_rtt_ms:
			_best_time_sync_rtt_ms = rtt
	else:
		new_offset = server_now - local_now
	if server_time_offset_ms == 0.0:
		server_time_offset_ms = new_offset
	else:
		server_time_offset_ms = lerp(server_time_offset_ms, new_offset, 0.25)

func _apply_phase(room: Dictionary) -> void:
	server_phase               = str(room.get("phase", server_phase))
	server_phase_started_at_ms = float(room.get("phase_started_at", server_phase_started_at_ms))
	server_typing_started_at_ms = float(room.get("typing_started_at", server_typing_started_at_ms))
	server_first_finish_at_ms  = float(room.get("first_finish_at", server_first_finish_at_ms))
	server_first_finish_by     = "" if room.get("first_finish_by", null) == null else str(room.get("first_finish_by"))
	server_round_id            = int(room.get("round_id", server_round_id))

func _apply_opponent_data(room: Dictionary) -> void:
	if GameManager.is_host:
		opp_progress     = room.get("guest_progress", 0.0)
		opp_typos        = room.get("guest_typos", 0)
		var gs = room.get("guest_skill", null)
		opp_chosen_skill = str(gs) if gs != null and gs != "" else ""
		opp_mutations    = room.get("host_mutations", [])
		var g_skills = room.get("guest_skills", null)
		if g_skills != null and g_skills is Array: opp_skills = g_skills
		# Sync opponent mana if available (fixes desync after mana-stealing skills)
		var g_mana = room.get("guest_mana", null)
		var prev_opp_mana = opp_mana
		if g_mana != null: 
			opp_mana = int(g_mana)
			# Log mana changes (not every poll, only when it changes)
			if prev_opp_mana >= 0 and prev_opp_mana != opp_mana:
				print("[ManaSync] Opponent mana: %d → %d" % [prev_opp_mana, opp_mana])
	else:
		opp_progress     = room.get("host_progress", 0.0)
		opp_typos        = room.get("host_typos", 0)
		var hs = room.get("host_skill", null)
		opp_chosen_skill = str(hs) if hs != null and hs != "" else ""
		opp_mutations    = room.get("guest_mutations", [])
		var h_skills = room.get("host_skills", null)
		if h_skills != null and h_skills is Array: opp_skills = h_skills
		# Sync opponent mana if available (fixes desync after mana-stealing skills)
		var h_mana = room.get("host_mana", null)
		var prev_opp_mana = opp_mana
		if h_mana != null: 
			opp_mana = int(h_mana)
			# Log mana changes (not every poll, only when it changes)
			if prev_opp_mana >= 0 and prev_opp_mana != opp_mana:
				print("[ManaSync] Opponent mana: %d → %d" % [prev_opp_mana, opp_mana])

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

# ─────────────────────────────────────────────
#  Progress sync
# ─────────────────────────────────────────────

func sync_progress(current_index: int, sentence_length: int, typos: int,
		chosen_skill: String, queued_mutation, accuracy_warning_visible: bool) -> void:
	if GameManager.current_room == "" or GameManager.user_data.id == 0: return
	var now = Time.get_ticks_msec() / 1000.0
	if now - last_progress_sync < sync_interval: return
	last_progress_sync = now

	var prog = float(current_index) / float(sentence_length) if sentence_length > 0 else 0.0
	if accuracy_warning_visible:
		prog = minf(prog, 0.98)

	var payload: Dictionary = {
		"user_id":      GameManager.user_data.id,
		"progress":     prog,
		"typos":        typos,
		"mana":         SkillsManager.player_mana,  # Sync mana in real-time for opponent display
		"chosen_skill": chosen_skill
	}
	if queued_mutation != null:
		payload["send_mutation"] = queued_mutation

	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = POLL_TIMEOUT_SEC
	http.request_completed.connect(func(_r,_c,_h,_b): http.queue_free())
	http.request(SERVER + "/api/rooms/" + GameManager.current_room + "/progress",
		GameManager.get_auth_headers(), HTTPClient.METHOD_PATCH, JSON.stringify(payload))

# ─────────────────────────────────────────────
#  Phase control (host only)
# ─────────────────────────────────────────────

func set_phase(phase: String, round_id: int) -> void:
	if GameManager.current_room == "" or GameManager.user_data.id == 0: return
	var payload: Dictionary = { "user_id": GameManager.user_data.id, "phase": phase }
	if round_id > 0: payload["round_id"] = round_id
	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = POLL_TIMEOUT_SEC
	http.request_completed.connect(func(result,_c,_h,_b):
		if is_instance_valid(http): http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS:
			if _phase_retry_attempts < 3:
				_phase_retry_attempts += 1
				_schedule_phase_retry(phase, round_id)
			return
		_phase_retry_attempts = 0
	)
	http.request(SERVER + "/api/rooms/" + GameManager.current_room + "/phase",
		GameManager.get_auth_headers(), HTTPClient.METHOD_PATCH, JSON.stringify(payload))

func sync_hp() -> void:
	if GameManager.current_room == "" or GameManager.user_data.id == 0: return
	if GameManager.is_solo or not GameManager.is_host: return
	var payload: Dictionary = {
		"user_id":  GameManager.user_data.id,
		"host_hp":  HPManager.player_hp,
		"guest_hp": HPManager.opponent_hp
	}
	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = POLL_TIMEOUT_SEC
	http.request_completed.connect(func(result,_c,_h,_b):
		if is_instance_valid(http): http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS:
			if _hp_retry_attempts < 3:
				_hp_retry_attempts += 1
				_schedule_hp_retry()
			return
		_hp_retry_attempts = 0
	)
	http.request(SERVER + "/api/rooms/" + GameManager.current_room + "/hp",
		GameManager.get_auth_headers(), HTTPClient.METHOD_PATCH, JSON.stringify(payload))

func delete_room() -> void:
	if GameManager.current_room == "": return
	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = POLL_TIMEOUT_SEC
	http.request_completed.connect(func(_r,_c,_h,_b): http.queue_free())
	if GameManager.is_host:
		http.request(SERVER + "/api/rooms/" + GameManager.current_room,
			GameManager.get_auth_headers(), HTTPClient.METHOD_DELETE)
	else:
		http.request(SERVER + "/api/rooms/" + GameManager.current_room + "/leave",
			GameManager.get_auth_headers(), HTTPClient.METHOD_POST)

# ─────────────────────────────────────────────
#  HP sync from poll (applied by Game)
# ─────────────────────────────────────────────

func apply_hp_from_room(room: Dictionary) -> void:
	if not (room.has("host_hp") and room.has("guest_hp")): return
	var host_hp: float = float(room.get("host_hp", 0))
	var guest_hp: float = float(room.get("guest_hp", 0))
	# Skip only if the server has never written HP (both 0 = before first sync_hp call).
	if host_hp == 0 and guest_hp == 0: return
	if GameManager.is_host:
		if abs(HPManager.player_hp   - host_hp)  > 0.01:
			print("[HPSync] HOST player_hp: %.0f → %.0f" % [HPManager.player_hp, host_hp])
			HPManager.set_hp("player",   host_hp)
		if abs(HPManager.opponent_hp - guest_hp) > 0.01:
			print("[HPSync] HOST opponent_hp: %.0f → %.0f" % [HPManager.opponent_hp, guest_hp])
			HPManager.set_hp("opponent", guest_hp)
	else:
		if abs(HPManager.player_hp   - guest_hp) > 0.01:
			print("[HPSync] GUEST player_hp: %.0f → %.0f" % [HPManager.player_hp, guest_hp])
			HPManager.set_hp("player",   guest_hp)
		if abs(HPManager.opponent_hp - host_hp)  > 0.01:
			print("[HPSync] GUEST opponent_hp: %.0f → %.0f" % [HPManager.opponent_hp, host_hp])
			HPManager.set_hp("opponent", host_hp)

# Sends progress and pops one mutation from the queue only if the interval has elapsed
# Mutations are sent with sequence numbers to prevent loss/reordering
var _mutation_seq: int = 0
var _pending_mutations: Dictionary = {}  # seq -> mutation

func sync_progress_with_queue(current_index: int, sentence_length: int, typos: int,
	chosen_skill: String, mutation_queue: Array, accuracy_warning_visible: bool) -> void:
	if GameManager.current_room == "" or GameManager.user_data.id == 0: return
	var now = Time.get_ticks_msec() / 1000.0
	if now - last_progress_sync < sync_interval: return
	last_progress_sync = now
	var prog = float(current_index) / float(sentence_length) if sentence_length > 0 else 0.0
	if accuracy_warning_visible: prog = minf(prog, 0.98)
	var payload: Dictionary = { 
		"user_id": GameManager.user_data.id, 
		"progress": prog, 
		"typos": typos, 
		"mana": SkillsManager.player_mana,  # Sync mana in real-time for opponent display
		"chosen_skill": chosen_skill 
	}
	
	# Send mutation with sequence number to prevent loss
	if mutation_queue.size() > 0:
		var mut = mutation_queue.pop_front()
		_mutation_seq += 1
		mut["seq"] = _mutation_seq
		_pending_mutations[_mutation_seq] = mut
		payload["send_mutation"] = mut
	
	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = POLL_TIMEOUT_SEC
	http.request_completed.connect(func(result,_c,_h,_b):
		if is_instance_valid(http): http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS:
			# Success - remove from pending
			if payload.has("send_mutation") and payload.send_mutation.has("seq"):
				_pending_mutations.erase(payload.send_mutation.seq)
		else:
			# Failure - re-queue at front if not already sent successfully
			if payload.has("send_mutation") and payload.send_mutation.has("seq"):
				var seq = payload.send_mutation.seq
				if _pending_mutations.has(seq):
					# Still pending, re-queue
					var mut_copy = _pending_mutations[seq].duplicate()
					mutation_queue.push_front(mut_copy)
	)
	http.request(SERVER + "/api/rooms/" + GameManager.current_room + "/progress", GameManager.get_auth_headers(), HTTPClient.METHOD_PATCH, JSON.stringify(payload))

# Sends progress immediately bypassing the interval throttle (used on finish)
func sync_progress_immediate(current_index: int, sentence_length: int, typos: int, chosen_skill: String) -> void:
	if GameManager.current_room == "" or GameManager.user_data.id == 0: return
	last_progress_sync = Time.get_ticks_msec() / 1000.0
	var prog = float(current_index) / float(sentence_length) if sentence_length > 0 else 0.0
	var payload: Dictionary = { 
		"user_id": GameManager.user_data.id, 
		"progress": prog, 
		"typos": typos, 
		"mana": SkillsManager.player_mana,  # Sync final mana on finish
		"chosen_skill": chosen_skill 
	}
	print("[ManaSync] Syncing mana to server: %d (progress: %.2f)" % [SkillsManager.player_mana, prog])
	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = POLL_TIMEOUT_SEC
	http.request_completed.connect(func(_r,_c,_h,_b): http.queue_free())
	http.request(SERVER + "/api/rooms/" + GameManager.current_room + "/progress", GameManager.get_auth_headers(), HTTPClient.METHOD_PATCH, JSON.stringify(payload))
