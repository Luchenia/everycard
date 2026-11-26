class_name CardStudio
extends Control
## Card studio: the player draws a card picture, names it on the card itself, and sends it.
## Left: tools. Middle: the 64x51 picture window, big. Right: the real card frame at x3 with the
## name typed straight onto its name plate, and the same card at hand size (x1) to check it reads.
## No instructions on screen: tools are pictures, keys are tiny corner letters.
##
## Keys: B pencil, E eraser, G fill, L line, R box (Shift = filled), I picker, M mirror,
## 1-3 brush size, arrows nudge, Ctrl+Z / Ctrl+Y, Ctrl+V paste an image, drop an image file to trace.
## Right mouse button always erases. Alt + click picks a colour.

const Z := 9                                   # screen px per picture px in the editor
const CANVAS := Rect2(150, 86, CardPixels.W * Z, CardPixels.H * Z)
const PAL_POS := Vector2(150, 572)
const SW := 36                                  # palette swatch
const RAIL_X := 64
const BTN := 52
const CARD_Z := 3
const CARD_POS := Vector2(800, 86)
const MINI_POS := Vector2(1100, 86)
const WIN_DARK := Color(22 / 255.0, 23 / 255.0, 28 / 255.0)
const BG := Color("#121118")
const PANEL := Color("#1c1b24")
const EDGE := Color("#34323f")
const LIGHT := Color("#e9e6ee")
const DRAFT_DIR := "user://card_studio"

enum Tool { PENCIL, ERASER, FILL, LINE, BOX, PICKER }

var pix := CardPixels.new()
var tex: ImageTexture
var sub := CardSubmission.new()
var tool: Tool = Tool.PENCIL
var color := Color("#e9e6ee")
var brush := 1
var mirror := false
var name_edit: LineEdit
var t := 0.0

var _drag := false
var _drag_erase := false
var _drag_from := Vector2i(-1, -1)
var _last := Vector2i(-1, -1)
var _hover := Vector2i(-1, -1)
var _mouse := Vector2.ZERO
var _shake := {}             # area -> seconds left
var _flash := 0.0            # success glow
var _toast := ""
var _toast_t := 0.0
var _buttons: Array = []     # [{rect, id, key}]

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	tex = ImageTexture.create_from_image(pix.image)
	_build_buttons()
	_build_name_edit()
	sub.finished.connect(_on_submitted)
	get_window().files_dropped.connect(_on_files_dropped)
	_load_draft()
	_refresh()

# ---------- layout ----------

func _build_buttons() -> void:
	var y := CANVAS.position.y
	for e in [["pencil", "B"], ["eraser", "E"], ["fill", "G"], ["line", "L"], ["box", "R"], ["picker", "I"], [],
			["mirror", "M"], ["size", ""]]:
		if e.is_empty():
			y += 14
			continue
		_buttons.append({"rect": Rect2(RAIL_X, y, BTN, BTN), "id": e[0], "key": e[1]})
		y += BTN + 6
	# history sits above the picture's top-right corner, away from the tools
	var x := CANVAS.end.x + 10
	for id in ["clear", "redo", "undo"]:
		x -= 46
		_buttons.append({"rect": Rect2(x, 26, 40, 40), "id": id, "key": ""})
		if id == "clear":
			x -= 14
	_buttons.append({"rect": submit_rect(), "id": "submit", "key": ""})

func submit_rect() -> Rect2:
	return Rect2(CARD_POS + Vector2(0, CardView.SIZE.y * CARD_Z + 22), Vector2(CardView.SIZE.x * CARD_Z, 60))

func name_rect() -> Rect2:
	var np := CardView.NAME_PLATE
	return Rect2(CARD_POS + np.position * CARD_Z, np.size * CARD_Z)

func _build_name_edit() -> void:
	name_edit = LineEdit.new()
	var r := name_rect()
	name_edit.position = r.position + Vector2(0, -3)
	name_edit.size = r.size + Vector2(0, 6)
	name_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_edit.placeholder_text = "이름"
	name_edit.max_length = 16
	name_edit.add_theme_font_override("font", Art.font("Galmuri7"))
	name_edit.add_theme_font_size_override("font_size", 8 * CARD_Z)
	name_edit.add_theme_color_override("font_color", Color("#F0ECE0"))
	name_edit.add_theme_color_override("font_placeholder_color", Color(0.94, 0.92, 0.88, 0.35))
	name_edit.add_theme_color_override("caret_color", Art.GOLD)
	name_edit.add_theme_color_override("selection_color", Color(Art.GOLD, 0.35))
	name_edit.add_theme_constant_override("minimum_character_width", 0)
	for s in ["normal", "focus", "read_only"]:
		var sb := StyleBoxEmpty.new()
		name_edit.add_theme_stylebox_override(s, sb)
	name_edit.text_changed.connect(_on_name_changed)
	name_edit.text_submitted.connect(func(_s): grab_focus())
	add_child(name_edit)

## The name must fit the plate at hand size (8 px Galmuri7 inside 67 px); extra letters are refused.
static func name_fits(s: String) -> bool:
	return Art.font("Galmuri7").get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x <= CardView.NAME_PLATE.size.x - 3

func _on_name_changed(s: String) -> void:
	if not name_fits(s):
		var col := name_edit.caret_column
		while s.length() > 0 and not name_fits(s):
			s = s.substr(0, s.length() - 1)
		name_edit.text = s
		name_edit.caret_column = mini(col, s.length())
		_shake["name"] = 0.25
	_save_draft()

# ---------- input ----------

func cell_at(p: Vector2) -> Vector2i:
	var q := ((p - CANVAS.position) / Z).floor()
	return Vector2i(int(q.x), int(q.y))

func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		_mouse = ev.position
		_hover = cell_at(ev.position) if CANVAS.has_point(ev.position) else Vector2i(-1, -1)
		if _drag:
			_drag_to(cell_at(ev.position))
		queue_redraw()
	elif ev is InputEventMouseButton and ev.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		if ev.pressed:
			grab_focus()
			if CANVAS.has_point(ev.position):
				_press(cell_at(ev.position), ev.button_index == MOUSE_BUTTON_RIGHT, ev.alt_pressed)
			elif ev.button_index == MOUSE_BUTTON_LEFT:
				_click_ui(ev.position)
		elif _drag:
			_release(cell_at(ev.position), ev.shift_pressed)
		accept_event()

func _unhandled_key_input(ev: InputEvent) -> void:
	if not ev is InputEventKey or not ev.pressed or name_edit.has_focus():
		return
	var k: Key = ev.keycode
	if ev.ctrl_pressed or ev.meta_pressed:
		match k:
			KEY_Z:
				_do("redo" if ev.shift_pressed else "undo")
			KEY_Y:
				_do("redo")
			KEY_V:
				_paste()
			KEY_S:
				_do("submit")
		get_viewport().set_input_as_handled()
		return
	var map := {KEY_B: "pencil", KEY_E: "eraser", KEY_G: "fill", KEY_L: "line", KEY_R: "box", KEY_I: "picker", KEY_M: "mirror"}
	if map.has(k):
		_do(map[k])
	elif k in [KEY_1, KEY_2, KEY_3]:
		brush = k - KEY_0
	elif k in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]:
		var d := {KEY_LEFT: Vector2i.LEFT, KEY_RIGHT: Vector2i.RIGHT, KEY_UP: Vector2i.UP, KEY_DOWN: Vector2i.DOWN}[k] as Vector2i
		pix.begin_action()
		pix.shift(d)
		_commit()
	elif k == KEY_N:
		name_edit.grab_focus()
	else:
		return
	get_viewport().set_input_as_handled()
	queue_redraw()

func _press(c: Vector2i, right: bool, alt: bool) -> void:
	if alt or tool == Tool.PICKER:
		var got := pix.get_px(c)
		if got.a > 0:
			color = got
		if tool == Tool.PICKER:
			tool = Tool.PENCIL
		queue_redraw()
		return
	var erase := right or tool == Tool.ERASER
	if tool == Tool.FILL:
		pix.begin_action()
		pix.fill(c, Color(0, 0, 0, 0) if erase else color, mirror)
		_commit()
		return
	pix.begin_action()
	_drag = true
	_drag_erase = erase
	_drag_from = c
	_last = c
	if tool in [Tool.PENCIL, Tool.ERASER]:
		pix.dab(c, _ink(), brush, mirror)
		_refresh()

func _ink() -> Color:
	return Color(0, 0, 0, 0) if _drag_erase else color

func _drag_to(c: Vector2i) -> void:
	if tool in [Tool.PENCIL, Tool.ERASER] and c != _last:
		pix.line(_last, c, _ink(), brush, mirror)
		_last = c
		_refresh()
	else:
		_last = c

func _release(c: Vector2i, shift: bool) -> void:
	_drag = false
	match tool:
		Tool.LINE:
			pix.line(_drag_from, c, _ink(), brush, mirror)
		Tool.BOX:
			pix.rect(_drag_from, c, _ink(), shift, mirror)
	_commit()

func _commit() -> void:
	_refresh()
	_save_draft()

func _refresh() -> void:
	tex.update(pix.image)
	queue_redraw()

func _click_ui(p: Vector2) -> void:
	var pal := CardPixels.palette_colors()
	for i in pal.size():
		if _swatch_rect(i).has_point(p):
			color = pal[i]
			if tool in [Tool.ERASER, Tool.PICKER]:
				tool = Tool.PENCIL
			queue_redraw()
			return
	for b in _buttons:
		if b["rect"].has_point(p):
			_do(b["id"])
			return

func _do(id: String) -> void:
	match id:
		"pencil": tool = Tool.PENCIL
		"eraser": tool = Tool.ERASER
		"fill": tool = Tool.FILL
		"line": tool = Tool.LINE
		"box": tool = Tool.BOX
		"picker": tool = Tool.PICKER
		"mirror": mirror = not mirror
		"size": brush = brush % 3 + 1
		"undo":
			if pix.undo():
				_commit()
		"redo":
			if pix.redo():
				_commit()
		"clear":
			if not pix.is_blank():
				pix.begin_action()
				pix.clear()
				_commit()
		"submit":
			sub.submit(name_edit.text, pix.image)
	queue_redraw()

func _paste() -> void:
	if DisplayServer.clipboard_has_image():
		_import(DisplayServer.clipboard_get_image())

func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		var im := Image.load_from_file(f)
		if im:
			_import(im)
			return

func _import(im: Image) -> void:
	if im == null or im.is_empty():
		return
	pix.begin_action()
	pix.import_image(im)
	_commit()

func _on_submitted(r: Dictionary) -> void:
	if not r.get("ok", false):
		for p in r.get("problems", []):
			_shake[p] = 0.45
		if "name" in r.get("problems", []):
			name_edit.grab_focus()
		return
	_flash = 1.0
	_toast = "서버 연결 전이라 이 PC에 저장했어요" if r.get("local", false) else "보냈어요"
	_toast_t = 3.0

# ---------- draft ----------

func _save_draft() -> void:
	DirAccess.make_dir_recursive_absolute(DRAFT_DIR)
	pix.image.save_png(DRAFT_DIR + "/draft.png")
	var f := FileAccess.open(DRAFT_DIR + "/draft_name.txt", FileAccess.WRITE)
	if f:
		f.store_string(name_edit.text)

func _load_draft() -> void:
	var im := Image.load_from_file(ProjectSettings.globalize_path(DRAFT_DIR + "/draft.png")) if FileAccess.file_exists(DRAFT_DIR + "/draft.png") else null
	if im and im.get_width() == CardPixels.W and im.get_height() == CardPixels.H:
		im.convert(Image.FORMAT_RGBA8)
		pix.image.copy_from(im)
	if FileAccess.file_exists(DRAFT_DIR + "/draft_name.txt"):
		name_edit.text = FileAccess.get_file_as_string(DRAFT_DIR + "/draft_name.txt")

# ---------- drawing ----------

func _process(d: float) -> void:
	t += d
	for k in _shake.keys():
		_shake[k] -= d
		if _shake[k] <= 0:
			_shake.erase(k)
	_flash = maxf(0.0, _flash - d * 0.8)
	_toast_t = maxf(0.0, _toast_t - d)
	var nr := name_rect()
	name_edit.position = nr.position + Vector2(_jolt("name"), -3 - _flash * 8.0)
	queue_redraw()

func _jolt(area: String) -> float:
	return sin(t * 70.0) * 5.0 * (_shake[area] / 0.45) if _shake.has(area) else 0.0

func _swatch_rect(i: int) -> Rect2:
	return Rect2(PAL_POS + Vector2(i % 16, i / 16) * SW, Vector2(SW, SW))

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	_draw_canvas()
	_draw_palette()
	_draw_rail()
	_draw_card(CARD_POS, CARD_Z, true)
	_draw_card(MINI_POS, 1, false)
	_draw_submit()
	if _toast_t > 0:
		var f := Art.font("Galmuri11-Bold")
		var a := clampf(_toast_t, 0, 1)
		var w := f.get_string_size(_toast, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x + 40
		var r := Rect2(Vector2((size.x - w) / 2, 22), Vector2(w, 40))
		draw_rect(r, Color(PANEL, 0.95 * a))
		draw_rect(r, Color(Art.GOLD, a), false, 2)
		draw_string(f, r.position + Vector2(20, 28), _toast, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(LIGHT, a))

func _draw_canvas() -> void:
	var off := Vector2(_jolt("picture"), 0)
	var cv := Rect2(CANVAS.position + off, CANVAS.size)
	draw_rect(cv.grow(10), PANEL)
	var edge := EDGE
	if _shake.has("picture"):
		edge = Art.DANGER
	draw_rect(cv.grow(4), edge, false, 2)
	# empty pixels show the card's own dark picture window, with a faint check so emptiness reads
	draw_rect(cv, WIN_DARK)
	var chk := Color(1, 1, 1, 0.025)
	for y in CardPixels.H / 2 + 1:
		for x in CardPixels.W / 2:
			if (x + y) % 2 == 0:
				draw_rect(Rect2(cv.position + Vector2(x, y) * Z * 2, Vector2(Z * 2, Z * 2)).intersection(cv), chk)
	draw_texture_rect(tex, cv, false)
	var g := Color(1, 1, 1, 0.05)
	for x in range(1, CardPixels.W):
		draw_line(cv.position + Vector2(x * Z, 0), cv.position + Vector2(x * Z, cv.size.y), g, 1)
	for y in range(1, CardPixels.H):
		draw_line(cv.position + Vector2(0, y * Z), cv.position + Vector2(cv.size.x, y * Z), g, 1)
	if mirror:
		var mx := cv.position.x + cv.size.x / 2
		for y in range(0, int(cv.size.y), 12):
			draw_line(Vector2(mx, cv.position.y + y), Vector2(mx, cv.position.y + y + 6), Color(Art.GOLD, 0.7), 2)
	# what the next click will paint
	if _hover.x >= 0:
		var pts: Array[Vector2i] = []
		var ink := Color(0, 0, 0, 0) if (_drag and _drag_erase) or tool == Tool.ERASER else color
		if _drag and tool == Tool.LINE:
			for p in CardPixels.line_points(_drag_from, _hover):
				pts.append_array(_brush_pts(p))
		elif _drag and tool == Tool.BOX:
			pts = CardPixels.rect_points(_drag_from, _hover, Input.is_key_pressed(KEY_SHIFT))
		elif tool in [Tool.PENCIL, Tool.ERASER, Tool.LINE]:
			pts = _brush_pts(_hover)
		else:
			pts = [_hover]
		var all := pts.duplicate()
		if mirror and tool != Tool.PICKER:
			for p in pts:
				all.append(Vector2i(CardPixels.W - 1 - p.x, p.y))
		for p in all:
			if not pix.inside(p):
				continue
			var r := Rect2(cv.position + Vector2(p) * Z, Vector2(Z, Z))
			if ink.a > 0 and tool != Tool.PICKER and tool != Tool.FILL:
				draw_rect(r, Color(ink, 0.75))
			draw_rect(r, Color(1, 1, 1, 0.6), false, 1)

func _brush_pts(c: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var o := -(brush - 1) / 2
	for dy in brush:
		for dx in brush:
			out.append(c + Vector2i(o + dx, o + dy))
	return out

func _draw_palette() -> void:
	var pal := CardPixels.palette_colors()
	draw_rect(Rect2(PAL_POS, Vector2(16 * SW, 2 * SW)).grow(10), PANEL)
	for i in pal.size():
		var r := _swatch_rect(i).grow(-2)
		draw_rect(r, pal[i])
		if pal[i].is_equal_approx(color):
			draw_rect(r.grow(2), Art.INK, false, 3)
			draw_rect(r.grow(3), LIGHT, false, 2)

func _draw_rail() -> void:
	var f := Art.font("Galmuri7")
	for b in _buttons:
		if b["id"] == "submit":
			continue
		var r: Rect2 = b["rect"]
		var on := _is_on(b["id"])
		var hov := r.has_point(_mouse)
		var dim: bool = (b["id"] == "undo" and not pix.can_undo()) or (b["id"] == "redo" and not pix.can_redo())
		draw_rect(r, Color("#2a2836") if on else (Color("#22212c") if hov else PANEL))
		draw_rect(r, Art.GOLD if on else EDGE, false, 2)
		var ic := Color(LIGHT, 0.3 if dim else 1.0)
		if b["id"] == "size":
			var s := 3 + brush * 5
			draw_rect(Rect2(r.get_center() - Vector2(s, s) / 2, Vector2(s, s)), ic)
		else:
			_icon(StudioIcons.get_icon(b["id"]), r.get_center(), 3 if r.size.x > 44 else 2, ic, color if b["id"] in ["pencil", "fill", "box", "line"] else Art.GOLD)
		if b["key"] != "":
			draw_string(f, r.position + Vector2(r.size.x - 9, r.size.y - 3), b["key"], HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(LIGHT, 0.4))
	# current colour under the rail
	var cr := Rect2(Vector2(RAIL_X, PAL_POS.y + 10), Vector2(BTN, BTN))
	draw_rect(cr, WIN_DARK)
	draw_rect(cr.grow(-6), color)
	draw_rect(cr, LIGHT, false, 2)

func _is_on(id: String) -> bool:
	match id:
		"pencil": return tool == Tool.PENCIL
		"eraser": return tool == Tool.ERASER
		"fill": return tool == Tool.FILL
		"line": return tool == Tool.LINE
		"box": return tool == Tool.BOX
		"picker": return tool == Tool.PICKER
		"mirror": return mirror
	return false

func _icon(rows: PackedStringArray, center: Vector2, s: int, main: Color, accent: Color) -> void:
	if rows.is_empty():
		return
	var o := center - Vector2(rows[0].length(), rows.size()) * s / 2.0
	for y in rows.size():
		for x in rows[y].length():
			var ch := rows[y][x]
			if ch == "#":
				draw_rect(Rect2(o + Vector2(x, y) * s, Vector2(s, s)), main)
			elif ch == "o":
				draw_rect(Rect2(o + Vector2(x, y) * s, Vector2(s, s)), Color(accent, main.a))

## The real card frame with the picture in its window. The description is the LLM's job, so the
## text box shows a shimmer instead of words, and the seconds badge shows "?".
func _draw_card(pos: Vector2, z: int, big: bool) -> void:
	var sz := CardView.SIZE * z
	var lift := _flash * 8.0 * z / 3.0
	var r := Rect2(pos - Vector2(0, lift), sz)
	draw_rect(Rect2(r.position + Vector2(2, 3) * z, r.size - Vector2(2, 2) * z), Color(0, 0, 0, 0.35))
	if _flash > 0:
		draw_rect(r.grow(3 * z), Color(Art.GOLD, 0.5 * _flash))
	var ft := Art.card_frame("neutral", "common")
	if ft:
		draw_texture_rect(ft, r, false)
	var aw := Rect2(r.position + CardView.ART_WIN.position * z, CardView.ART_WIN.size * z)
	draw_texture_rect(tex, aw, false)
	# description: three soft bars breathing left to right (the server writes this part)
	var tb := Rect2(r.position + CardView.TEXT_BOX.position * z, CardView.TEXT_BOX.size * z)
	for i in 3:
		var w: float = [0.78, 0.9, 0.55][i] * (tb.size.x - 12 * z)
		var y := tb.position.y + tb.size.y / 2 - 9 * z + i * 8 * z
		var a := 0.10 + 0.08 * sin(t * 2.4 - i * 0.7)
		draw_rect(Rect2(Vector2(tb.get_center().x - w / 2, y), Vector2(w, 4 * z)), Color(0.2, 0.15, 0.1, a))
	var bf := Art.font("Galmuri11-Bold")
	var bc := CardView.BADGE * z + r.position
	var bp := Vector2(bc.x - 9 * z, bc.y + 4.5 * z)
	draw_string_outline(bf, bp, "?", HORIZONTAL_ALIGNMENT_CENTER, 18 * z, int(12 * z), int(2 * z), Color("#1a120c"))
	draw_string(bf, bp, "?", HORIZONTAL_ALIGNMENT_CENTER, 18 * z, int(12 * z), Color("#FFF0C8"))
	var np := r.position + CardView.NAME_PLATE.position * z
	if big:
		if _shake.has("name"):
			draw_rect(Rect2(np, CardView.NAME_PLATE.size * z).grow(z), Color(Art.DANGER, 0.5))
	else:
		var nf := Art.font("Galmuri7")
		var base := np.y + (CardView.NAME_PLATE.size.y + nf.get_ascent(8) - nf.get_descent(8)) / 2.0
		draw_string(nf, Vector2(np.x - 0.5, round(base)), name_edit.text, HORIZONTAL_ALIGNMENT_CENTER, CardView.NAME_PLATE.size.x, 8, Color("#F0ECE0"))

func _draw_submit() -> void:
	var r := submit_rect()
	var ready := not name_edit.text.strip_edges().is_empty() and not pix.is_blank()
	var hov := r.has_point(_mouse)
	var base := Color("#7a5a1e") if ready else Color("#2a2836")
	if hov and ready:
		base = base.lightened(0.15)
	draw_rect(r, base)
	draw_rect(r, Art.GOLD if ready else EDGE, false, 2)
	var f := Art.font("Galmuri11-Bold")
	draw_string(f, r.position + Vector2(0, 40), "카드 만들기", HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 24, Color(LIGHT, 1.0 if ready else 0.35))
