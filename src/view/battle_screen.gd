extends Control
## Prototype screen: timeline bar, board, fanned hand, cell inspector, battle log, reward and end screens.
## Keys: arrows move (1 s), mouse wheel or Q/E roll the hand, Space wait 1 s, A base ability, right click cancel.

var catalog: Catalog
var flow: RunFlow
var board: BoardView
var font: Font
var hand_box: Control
var timeline: TimelineBar
var info: Label
var log_label: RichTextLabel
var status: Label
var overlay: VBoxContainer
var selected := -1
var ability_mode := false
var shown_log := 0
var log_timer := 0.0
var seed_value := 0

func _ready() -> void:
	font = load("res://assets/fonts/Galmuri11.ttf")
	var th := Theme.new()
	th.default_font = font
	th.default_font_size = 14
	theme = th
	catalog = Catalog.load_dir("res://data")
	var args := OS.get_cmdline_user_args()
	seed_value = int(Time.get_unix_time_from_system()) % 100000
	for a in args:
		if a.begins_with("--seed="):
			seed_value = int(a.substr(7))
	var bg := ColorRect.new()
	bg.color = Color("#14161c")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	board = BoardView.new()
	board.font = font
	board.position = Vector2(24, 96)
	add_child(board)
	timeline = TimelineBar.new()
	timeline.font = font
	timeline.position = Vector2(24, 44)
	timeline.size = Vector2(1232, 40)
	timeline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(timeline)
	board.gui_input.connect(_on_board_input)
	status = Label.new()
	status.position = Vector2(24, 14)
	status.add_theme_font_size_override("font_size", 18)
	add_child(status)
	info = Label.new()
	info.position = Vector2(700, 96)
	info.size = Vector2(556, 230)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD
	add_child(info)
	log_label = RichTextLabel.new()
	log_label.position = Vector2(700, 330)
	log_label.size = Vector2(556, 270)
	log_label.scroll_following = true
	log_label.add_theme_font_size_override("normal_font_size", 13)
	add_child(log_label)
	hand_box = Control.new()
	hand_box.position = Vector2(24, 612)
	hand_box.size = Vector2(1232, 180)
	hand_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hand_box)
	overlay = VBoxContainer.new()
	overlay.position = Vector2(360, 220)
	overlay.add_theme_constant_override("separation", 10)
	add_child(overlay)
	_new_run()

func _new_run() -> void:
	flow = RunFlow.new(catalog, seed_value)
	shown_log = 0
	log_label.clear()
	_refresh()

func _process(delta: float) -> void:
	if flow == null or flow.battle == null:
		return
	log_timer -= delta
	if log_timer <= 0.0 and shown_log < flow.battle.log.size():
		var e: Dictionary = flow.battle.log[shown_log]
		shown_log += 1
		log_timer = 0.15 if e["t"] in ["reaction", "damage", "collision", "moved", "void", "death"] else 0.0
		log_label.append_text(_fmt(e) + "\n")

func _fmt(e: Dictionary) -> String:
	var col: String = {"damage": "#ff8080", "reaction": "#ffd27f", "chain_cap": "#ff4040", "death": "#ff4040", "telegraph": "#ffa040",
		"swap": "#80c0ff", "cardify": "#c090ff", "play": "#ffffff", "land": "#ffffff", "telegraph_hit": "#ff8040",
		"exhaust": "#c0c0c0", "round": "#80b0ff"}.get(e["t"], "#a0a8b8")
	return "[color=%s]%s[/color]" % [col, e["msg"]]

func _card_text(id: String) -> String:
	var c := Effects.card_def(id, catalog)
	var ex := int(c.get("exhaust", 0))
	return "%s\n%d초%s %s\n%s" % [c.get("name", id), int(c.get("time", 0)), (" +탈진 %d초" % ex) if ex > 0 else "",
		"●●" if int(c.get("weight", 1)) > 1 else "●", c.get("desc", "")]

func _refresh() -> void:
	for ch in overlay.get_children():
		ch.queue_free()
	for ch in hand_box.get_children():
		ch.queue_free()
	var b := flow.battle
	board.battle = b
	board.fit()
	board.preview = {}
	board.queue_redraw()
	timeline.battle = b
	_update_span()
	if flow.phase == "reward":
		_overlay_title("승리! 카드 한 장을 고르세요")
		for i in flow.rewards.size():
			var btn := Button.new()
			btn.text = _card_text(flow.rewards[i]).replace("\n", "  ")
			btn.pressed.connect(func(): _pick_reward(i))
			overlay.add_child(btn)
	elif flow.phase in ["game_over", "victory"]:
		_overlay_title("패배" if flow.phase == "game_over" else "3연전 클리어!")
		var again := Button.new()
		again.text = "새 판 시작"
		again.pressed.connect(func():
			seed_value += 1
			_new_run())
		overlay.add_child(again)
	var h := b.human()
	status.text = "전투 %d/3   %d초 (다음 카드 %d초 뒤)   %s%s" % [flow.index + 1, b.now, b.next_draw_at() - b.now,
		("몸: " + h.name + " 체력 " + str(h.hp) + "/" + str(h.max_hp)) if h else "", "   [능력 조준 중]" if ability_mode else ""]
	if b.belt:
		var n: int = b.belt.slots.size()
		for i in n:
			var s = b.belt.slots[i]
			var btn := Button.new()
			btn.size = Vector2(124, 150)
			btn.pivot_offset = Vector2(62, 300)
			var k := float(i) - float(n - 1) / 2.0
			btn.position = Vector2(300 + i * 120, 12 + absf(k) * absf(k) * 6)
			btn.rotation = k * 0.035
			btn.toggle_mode = true
			btn.button_pressed = i == selected
			if s != null and s.get("tail", false):
				btn.text = "(무거운 카드)"
			elif s == null:
				btn.text = "(빈 칸)"
			elif b.belt.mode == "lifespan":
				btn.text = _card_text(s["card_id"]) + "\n수명 %.1f%s" % [s["life"], " [곧 사라짐]" if i == b.belt.next_to_burn() else ""]
			else:
				btn.text = _card_text(s["card_id"])
			btn.autowrap_mode = TextServer.AUTOWRAP_WORD
			btn.disabled = s == null or s.get("tail", false) or flow.phase != "battle"
			btn.pressed.connect(func(): _select(i))
			hand_box.add_child(btn)
		var lw := Label.new()
		lw.position = Vector2(220, 70)
		lw.text = "◀ 휠\n" + _roll_cost(-1)
		lw.modulate = Color(1, 1, 1, 0.6)
		hand_box.add_child(lw)
		var rw := Label.new()
		rw.position = Vector2(950, 70)
		rw.text = "휠 ▶\n" + _roll_cost(1)
		rw.modulate = Color(1, 1, 1, 0.6)
		hand_box.add_child(rw)
	var tips := Label.new()
	tips.position = Vector2(1010, 20)
	tips.text = "방향키 이동 (1초)\n휠 / Q·E 손패 굴리기\nSpace 1초 기다리기\nA 기본 능력 · 우클릭 취소"
	tips.modulate = Color(1, 1, 1, 0.5)
	hand_box.add_child(tips)
	_update_info()

func _roll_cost(dir: int) -> String:
	var b := flow.battle
	var id := b.belt.end_card(dir)
	var w := maxi(1, int(Effects.card_def(id, catalog).get("weight", 1))) if id != "" else 1
	return "%d초" % (w * int(b.cfg["wheel_time"]))

func _update_span() -> void:
	var b := flow.battle
	timeline.span_secs = 0
	timeline.span_exhaust = 0
	if selected >= 0 and b.belt != null and selected < b.belt.slots.size() and b.belt.slots[selected] != null:
		var c := Effects.card_def(b.belt.slots[selected]["card_id"], catalog)
		timeline.span_secs = maxi(0, b.action_secs(int(c.get("time", 0)), b.human())) if b.human() else 0
		timeline.span_exhaust = int(c.get("exhaust", 0))
	timeline.queue_redraw()

func _overlay_title(t: String) -> void:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 26)
	overlay.add_child(l)

func _pick_reward(i: int) -> void:
	flow.choose_reward(i)
	shown_log = 0
	log_label.clear()
	selected = -1
	_refresh()

func _select(i: int) -> void:
	selected = -1 if selected == i else i
	ability_mode = false
	_refresh()

func _update_info() -> void:
	var b := flow.battle
	var p := board.hover
	var lines := []
	if selected >= 0 and b.belt.slots[selected] != null:
		var c := Effects.card_def(b.belt.slots[selected]["card_id"], catalog)
		lines.append("선택: %s (사거리 %d)" % [c.get("name", ""), int(c.get("target", {}).get("range", 0))])
	if p.x >= 0:
		var g := b.grid
		lines.append("칸 %s  물질 %s" % [str(p), catalog.materials[g.get_material(p)].get("name", g.get_material(p))])
		var vs := []
		for id in catalog.variables:
			var v = g.get_var(p, id)
			var d = g.default_of(id)
			if (v is Vector2 and v.length() > 0.05) or (not (v is Vector2) and absf(float(v) - float(d)) > 0.05):
				vs.append("%s %s" % [catalog.variables[id].get("name", id), ("(%.1f,%.1f)" % [v.x, v.y]) if v is Vector2 else ("%.1f" % v)])
		lines.append(", ".join(vs) if not vs.is_empty() else "기본 상태")
		var u = g.unit_at(p)
		if u:
			lines.append("%s 체력 %d/%d 질량 %.0f 상태 %s 덱 %d장" % [u.name, u.hp, u.max_hp, u.mass, str(u.statuses.keys()), u.deck.size()])
	info.text = "\n".join(lines)

func _on_board_input(ev: InputEvent) -> void:
	if flow.phase != "battle":
		return
	var b := flow.battle
	if ev is InputEventMouseMotion:
		var c := board.cell_at(ev.position)
		if c != board.hover:
			board.hover = c
			board.preview = b.preview(selected, c) if selected >= 0 and c.x >= 0 else {}
			board.queue_redraw()
			_update_info()
	elif ev is InputEventMouseButton and ev.pressed:
		var cell := board.cell_at(ev.position)
		if ev.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			return
		if ev.button_index == MOUSE_BUTTON_RIGHT:
			selected = -1
			ability_mode = false
			_refresh()
		elif ev.button_index == MOUSE_BUTTON_LEFT and cell.x >= 0:
			if ability_mode:
				b.cmd_ability(cell)
				ability_mode = false
				_after()
			elif selected >= 0 and b.cmd_play(selected, cell):
				selected = -1
				_after()

func _input(ev: InputEvent) -> void:
	# the wheel rolls the hand wherever the mouse is
	if flow == null or flow.phase != "battle" or not (ev is InputEventMouseButton) or not ev.pressed:
		return
	if ev.button_index == MOUSE_BUTTON_WHEEL_UP or ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		selected = -1
		flow.battle.cmd_wheel(-1 if ev.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
		get_viewport().set_input_as_handled()
		_after()

func _unhandled_input(ev: InputEvent) -> void:
	if flow == null or flow.phase != "battle" or not (ev is InputEventKey) or not ev.pressed or ev.echo:
		return
	var b := flow.battle
	match ev.keycode:
		KEY_UP: b.cmd_move(Vector2i.UP)
		KEY_DOWN: b.cmd_move(Vector2i.DOWN)
		KEY_LEFT: b.cmd_move(Vector2i.LEFT)
		KEY_RIGHT: b.cmd_move(Vector2i.RIGHT)
		KEY_SPACE:
			selected = -1
			b.cmd_wait(1)
		KEY_Q:
			selected = -1
			b.cmd_wheel(-1)
		KEY_E:
			selected = -1
			b.cmd_wheel(1)
		KEY_A:
			if b.human() and b.human().base_ability == "step1":
				return
			if b.human() and b.human().base_ability in ["heat_self", "belt1"]:
				b.cmd_ability(b.human().pos)
			else:
				ability_mode = true
		_: return
	_after()

func _after() -> void:
	ability_mode = false
	flow.update()
	_refresh()
