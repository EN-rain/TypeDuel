extends Node
## GameHUD — handles all HUD display updates for the game scene.
## Extracted from game.gd to reduce orchestrator size.
##
## Usage: game.gd creates this node, calls init() with node references,
## then calls update_bars(), update_stats_hud(), set_countdown() each frame.

# Node references — set via init()
var hp_bar_own: ProgressBar   = null
var hp_bar_opp: ProgressBar   = null
var mana_bar_own: ProgressBar = null
var mana_bar_opp: ProgressBar = null
var stats_label: Label        = null
var opp_stats_label: Label    = null
var countdown_label: Label    = null

# Pause panel
var _pause_panel: Panel  = null
var _pause_visible: bool = false

# Callback — set by game.gd for forfeit action
var on_forfeit: Callable = func(): pass

# Cache to avoid redundant text updates
var _last_countdown_text: String = ""
var _last_stats_text: String = ""
var _last_opp_stats_text: String = ""

func init(hp_own: ProgressBar, hp_opp: ProgressBar,
		  mana_own: ProgressBar, mana_opp: ProgressBar,
		  stats: Label, opp_stats: Label,
		  countdown: Label,
		  hud_parent: CanvasLayer) -> void:
	hp_bar_own   = hp_own
	hp_bar_opp   = hp_opp
	mana_bar_own = mana_own
	mana_bar_opp = mana_opp
	stats_label     = stats
	opp_stats_label = opp_stats
	countdown_label = countdown
	_build_pause_panel(hud_parent)

	# Disable percentage display on all bars — values are raw numbers, not percentages.
	if hp_bar_own:   hp_bar_own.show_percentage   = false
	if hp_bar_opp:   hp_bar_opp.show_percentage   = false
	if mana_bar_own: mana_bar_own.show_percentage = false
	if mana_bar_opp: mana_bar_opp.show_percentage = false

# ─────────────────────────────────────────────
# Bar updates
# ─────────────────────────────────────────────

func update_bars() -> void:
	if hp_bar_own:
		hp_bar_own.max_value = HPManager.player_max_hp
		hp_bar_own.value     = HPManager.player_hp
		var lbl = hp_bar_own.get_node_or_null("OwnHpLabel")
		if lbl: lbl.text = "%d" % int(HPManager.player_hp)
	if hp_bar_opp:
		hp_bar_opp.max_value = HPManager.opponent_max_hp
		hp_bar_opp.value     = HPManager.opponent_hp
		var lbl = hp_bar_opp.get_node_or_null("EnemyHpLabel")
		if lbl: lbl.text = "%d" % int(HPManager.opponent_hp)
	if mana_bar_own:
		mana_bar_own.max_value = 10
		mana_bar_own.value     = SkillsManager.player_mana
		var lbl = mana_bar_own.get_node_or_null("OwnManaLabel")
		if lbl: lbl.text = "%d" % SkillsManager.player_mana
	if mana_bar_opp:
		mana_bar_opp.max_value = 10
		mana_bar_opp.value     = SkillsManager.opponent_mana
		var lbl = mana_bar_opp.get_node_or_null("EnemyManaLabel")
		if lbl: lbl.text = "%d" % SkillsManager.opponent_mana

# ─────────────────────────────────────────────
# Stats HUD
# ─────────────────────────────────────────────

func update_stats_hud(typing: Node, net: Node, server_typing_started_at_ms: float,
					  server_first_finish_at_ms: float, get_synced_ms: Callable) -> void:
	if stats_label:
		var t = "WPM: %d | Typos: %d | Acc: %.1f%%" % [typing.get_wpm(), typing.typos_count, typing.get_accuracy()]
		if t != _last_stats_text:
			_last_stats_text = t
			stats_label.text = t
	if opp_stats_label:
		var opp_prog = net.opp_progress
		var sentence_len = float(typing.target_sentence.length())
		var opp_chars = opp_prog * sentence_len
		var opp_words = opp_chars / 5.0

		var opp_wpm := 0
		if opp_prog >= 0.999:
			if server_first_finish_at_ms > 0.0 and server_typing_started_at_ms > 0.0:
				var finish_elapsed_min = (server_first_finish_at_ms - server_typing_started_at_ms) / 60000.0
				opp_wpm = int(opp_words / finish_elapsed_min) if finish_elapsed_min > 0 else 0
		else:
			var elapsed_min := 0.0
			if not GameManager.is_solo and GameManager.current_room != "" and server_typing_started_at_ms > 0.0:
				var now_ms := get_synced_ms.call() as float
				if now_ms > server_typing_started_at_ms:
					elapsed_min = (now_ms - server_typing_started_at_ms) / 60000.0
			opp_wpm = int(opp_words / elapsed_min) if elapsed_min > 0 else 0

		var opp_total = opp_chars + float(net.opp_typos)
		var opp_acc = clampf((opp_chars / opp_total) * 100.0, 0.0, 100.0) if opp_total > 0 else 100.0
		var t2 = "WPM: %d | Typos: %d | Acc: %.1f%%" % [opp_wpm, net.opp_typos, opp_acc]
		if t2 != _last_opp_stats_text:
			_last_opp_stats_text = t2
			opp_stats_label.text = t2

# ─────────────────────────────────────────────
# Countdown
# ─────────────────────────────────────────────

func set_countdown(text: String) -> void:
	if countdown_label and _last_countdown_text != text:
		_last_countdown_text = text
		countdown_label.text = text

func hide_countdown() -> void:
	if countdown_label:
		countdown_label.hide()
		_last_countdown_text = ""

func show_countdown() -> void:
	if countdown_label:
		countdown_label.show()
		_last_countdown_text = ""  # force re-render

# ─────────────────────────────────────────────
# Pause panel
# ─────────────────────────────────────────────

func _build_pause_panel(hud_parent: CanvasLayer) -> void:
	_pause_panel = Panel.new()
	_pause_panel.set_anchors_preset(Control.PRESET_CENTER)
	_pause_panel.custom_minimum_size = Vector2(320, 180)
	_pause_panel.visible = false
	_pause_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	hud_parent.add_child(_pause_panel)
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 24; vbox.offset_top = 24
	vbox.offset_right = -24; vbox.offset_bottom = -24
	vbox.add_theme_constant_override("separation", 16)
	_pause_panel.add_child(vbox)
	var title = Label.new()
	title.text = "Game Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)
	var btn_resume = Button.new()
	btn_resume.text = "Resume"
	btn_resume.pressed.connect(toggle_pause_panel)
	vbox.add_child(btn_resume)
	var btn_leave = Button.new()
	btn_leave.text = "Forfeit & Leave"
	btn_leave.pressed.connect(_on_forfeit_pressed)
	vbox.add_child(btn_leave)

func toggle_pause_panel() -> void:
	_pause_visible = !_pause_visible
	if is_instance_valid(_pause_panel):
		_pause_panel.visible = _pause_visible

func hide_pause_panel() -> void:
	_pause_visible = false
	if is_instance_valid(_pause_panel): _pause_panel.visible = false

func is_pause_visible() -> bool:
	return _pause_visible

func _on_forfeit_pressed() -> void:
	hide_pause_panel()
	on_forfeit.call()
