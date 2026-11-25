extends Control
## Prototype screen: board, flowing hand, time bar, cell inspector, battle log, reward and end screens.
## Keys: arrows move, Space end turn, H hold hand, F flush hand, A base ability, right click cancel.

var catalog: Catalog
var flow: RunFlow
var board: BoardView
var font: Font
var hand_box: HBoxContainer
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
	board.position = Vector2(24, 56)
	add_child(board)
	board.gui_input.connect(_on_board_input)
	status = Label.new()
	status.position = Vector2(24, 14)
	status.add_theme_font_size_override("font_size", 18)
	add_child(status)
	info = Label.new()
	info.position = Vector2(700, 56)
	info.size = Vector2(556, 230)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD
	add_child(info)
	log_label = RichTextLabel.new()
	log_label.position = Vector2(700, 300)
	log_label.size = Vector2(556, 260)
	log_label.scroll_following = true
	log_label.add_theme_font_size_override("normal_font_size", 13)
	add_child(log_label)
	hand_box = HBoxContainer.new()
	hand_box.position = Vector2(24, 580)
	hand_box.add_theme_constant_override("separation", 8)
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
		"swap": "#80c0ff", "cardify": "#c090ff", "play": "#ffffff"}.get(e["t"], "#a0a8b8")
	return "[color=%s]%s[/color]" % [col, e["msg"]]

func _card_text(id: String) -> String:
	var c := Effects.card_def(id, catalog)
	return "%s\n시간 %d %s\n%s" % [c.get("name", id), int(c.get("time", 0)), "●●" if int(c.get("weight", 1)) > 1 else "●", c.get("desc", "")]

func _refresh() -> void:
	for ch in overlay.get_children():
		ch.queue_free()
	for ch in hand_box.get_children():
		ch.queue_free()
	var b := flow.battle
	board.battle = b
	board.preview = {}
	board.queue_redraw()
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
	status.text = "전투 %d/3  턴 %d  남은 시간 %d/%d  %s%s" % [flow.index + 1, b.turn, b.time_left, Battle.TURN_TIME,
		("몸: " + h.name + " 체력 " + str(h.hp) + "/" + str(h.max_hp)) if h else "", "   [능력 조준 중]" if ability_mode else ""]
	if b.belt:
		for i in b.belt.slots.size():
			var s = b.belt.slots[i]
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(118, 170)
			btn.toggle_mode = true
			btn.button_pressed = i == selected
			btn.text = "(빈 칸)" if s == null else _card_text(s["card_id"]) + "\n수명 %.1f%s" % [s["life"], " [곧 사라짐]" if i == b.belt.next_to_burn() else ""]
			btn.autowrap_mode = TextServer.AUTOWRAP_WORD
			btn.disabled = s == null or flow.phase != "battle"
			btn.pressed.connect(func(): _select(i))
			hand_box.add_child(btn)
		var pv := Label.new()
		pv.custom_minimum_size = Vector2(110, 170)
		pv.text = "다음 카드\n" + (Effects.card_def(b.belt.preview(), catalog).get("name", "-") if b.belt.preview() != "" else "-")
		pv.modulate = Color(1, 1, 1, 0.6)
		hand_box.add_child(pv)
	var tips := Label.new()
	tips.text = "방향키 이동 · Space 턴 종료\nH 붙잡기(시간 2, 카드 선택 시 그 카드 수명 +2)\nF 가장 짧은 카드 버리기\nA 기본 능력 · 우클릭 취소"
	tips.modulate = Color(1, 1, 1, 0.5)
	hand_box.add_child(tips)
	_update_info()

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
			b.cmd_end_turn()
		KEY_H: b.cmd_hold(selected)
		KEY_F: b.cmd_flush()
		KEY_A:
			if b.human() and b.human().base_ability == "step1":
				return
			ability_mode = true
		_: return
	_after()

func _after() -> void:
	flow.update()
	_refresh()
