class_name MatchmakingController
## Handles matchmaking lobby rules: deadline countdown, forfeit detection, and start coordination.
## Pure game logic; UI updates and network calls handled by the scene.

var _deadline_unix_ms: float = 0.0
var _forfeit_handled: bool = false
var _start_sent: bool = false
var _start_retry_at_ms: float = 0.0  # earliest local ms to retry start after 409

func reset() -> void:
	_deadline_unix_ms = 0.0
	_forfeit_handled = false
	_start_sent = false
	_start_retry_at_ms = 0.0

func is_forfeit_handled() -> bool:
	return _forfeit_handled

func is_start_sent() -> bool:
	return _start_sent

func get_deadline_ms() -> float:
	return _deadline_unix_ms

## Process matchmaking rules for one frame.
## Parameters:
##   - is_host: bool
##   - my_ready: bool (local player selections complete)
##   - opp_ready: bool (opponent selections complete)
##   - server_now_ms: authoritative server time if available, else -1
##   - local_now_ms: current local Unix time in ms
## Returns: Dictionary with keys:
##   status_text (String)
##   countdown_sec (int, -1 if not showing countdown)
##   countdown_color (Color)
##   should_start (bool) - host should attempt to start the game
##   forfeit_triggered (bool) - local timeout occurred
##   forfeit_i_was_ready (bool) - for penalty calculation
func update(
	is_host: bool,
	my_ready: bool,
	opp_ready: bool,
	server_now_ms: float,
	local_now_ms: float
) -> Dictionary:
	var result = {
		"status_text": "",
		"countdown_sec": -1,
		"countdown_color": Color.WHITE,
		"should_start": false,
		"forfeit_triggered": false,
		"forfeit_i_was_ready": false
	}

	# Time selection: prefer server if available
	var now_unix_ms: float = server_now_ms if server_now_ms > 0 else local_now_ms

	# Initialize deadline if not set
	if _deadline_unix_ms <= 0.0:
		_deadline_unix_ms = now_unix_ms + 60000.0  # 60s

	# Both ready?
	if my_ready and opp_ready:
		result.status_text = "Both ready! Starting..."
		result.countdown_label_text = "Starting..."
		if is_host and not _start_sent and local_now_ms >= _start_retry_at_ms:
			_start_sent = true
			result.should_start = true
		# No countdown in this state
		return result

	# Not both ready: countdown and forfeit
	var remaining_ms = _deadline_unix_ms - now_unix_ms
	var remaining_sec = max(0, int(ceil(remaining_ms / 1000.0)))
	result.countdown_sec = remaining_sec

	if remaining_sec <= 0:
		result.forfeit_triggered = true
		result.forfeit_i_was_ready = my_ready
	elif remaining_sec <= 5:
		result.countdown_color = Color.RED
	elif remaining_sec <= 10:
		result.countdown_color = Color.ORANGE
	else:
		result.countdown_color = Color.WHITE

	# Status text
	if my_ready and not opp_ready:
		result.status_text = "Waiting for opponent to choose..."
	elif not my_ready:
		result.status_text = "Choose character, 2 skills, and a passive!"
	else:
		result.status_text = ""

	# Countdown label text
	if remaining_sec > 0:
		result.countdown_label_text = "Time: %d seconds" % remaining_sec
	else:
		result.countdown_label_text = ""

	return result

func mark_forfeit_handled() -> void:
	_forfeit_handled = true

func set_deadline(deadline_ms: float) -> void:
	_deadline_unix_ms = deadline_ms

func schedule_start_retry(delay_sec: float = 1.0) -> void:
	_start_sent = false
	_start_retry_at_ms = Time.get_unix_time_from_system() * 1000.0 + delay_sec * 1000.0

func start_matchmaking() -> void:
	reset()
