class_name CardView
extends Control
## One card face. Frame colour = rarity, header band = family (sword / magic / neutral), seconds in
## the top-left badge, art window, description with [keywords] picked out.

signal picked(card_view)
signal hovered(card_view, on)

const SIZE := Vector2(132, 184)
var card_id := ""
var catalog: Catalog
var font: Font
var desc: RichTextLabel
var real := 0.0
var lit := false     # selected
var ghost := false   # a card of the ring outside the hand window

func setup(id: String, cat: Catalog, f: Font) -> void:
	card_id = id
	catalog = cat
	font = f
	size = SIZE
	pivot_offset = Vector2(SIZE.x / 2, SIZE.y)
	mouse_filter = Control.MOUSE_FILTER_STOP
	desc = RichTextLabel.new()
	desc.bbcode_enabled = true
	desc.scroll_active = false
	desc.fit_content = false
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc.position = Vector2(10, 100)
	desc.size = Vector2(SIZE.x - 20, 76)
	desc.add_theme_font_override("normal_font", f)
	desc.add_theme_font_size_override("normal_font_size", 11)
	desc.add_theme_color_override("default_color", Color("#2b2530"))
	desc.add_theme_constant_override("line_separation", -1)
	desc.text = "[center]%s[/center]" % CardView.rich(def().get("desc", ""))
	add_child(desc)
	mouse_entered.connect(func(): hovered.emit(self, true))
	mouse_exited.connect(func(): hovered.emit(self, false))

func def() -> Dictionary:
	return Effects.card_def(card_id, catalog)

static func rich(text: String) -> String:
	var out := ""
	var i := 0
	while i < text.length():
		var a := text.find("[", i)
		if a < 0:
			out += text.substr(i)
			break
		var b := text.find("]", a)
		if b < 0:
			out += text.substr(i)
			break
		out += text.substr(i, a - i) + "[color=#9a3d12]" + text.substr(a + 1, b - a - 1) + "[/color]"
		i = b + 1
	return out

static func keywords_in(text: String) -> Array:
	var out := []
	var i := 0
	while true:
		var a := text.find("[", i)
		if a < 0:
			break
		var b := text.find("]", a)
		if b < 0:
			break
		var k := text.substr(a + 1, b - a - 1)
		if not k in out:
			out.append(k)
		i = b + 1
	return out

func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		picked.emit(self)
		accept_event()

func _process(d: float) -> void:
	real += d
	queue_redraw()

func _draw() -> void:
	var c := def()
	var rar: String = c.get("rarity", "common")
	var fam: String = c.get("family", "neutral")
	var rc: Color = Art.RARITY.get(rar, Art.RARITY["common"])
	var fc: Color = Art.FAMILY.get(fam, Art.FAMILY["neutral"])
	var r := Rect2(Vector2.ZERO, SIZE)
	draw_rect(Rect2(r.position + Vector2(4, 6), r.size), Color(0, 0, 0, 0.4))
	if lit:
		var gl := 0.5 + 0.5 * sin(real * 5.0)
		draw_rect(r.grow(5), Color(Art.GOLD, 0.35 + 0.3 * gl))
	# frame
	draw_rect(r, Art.INK)
	draw_rect(r.grow(-2), rc.darkened(0.35))
	draw_rect(r.grow(-4), rc)
	draw_rect(Rect2(r.position + Vector2(4, 4), Vector2(r.size.x - 8, 2)), rc.lightened(0.35))
	# notches by rarity: more notches, finer card
	var notches: int = {"basic": 0, "common": 1, "rare": 2, "epic": 3, "legendary": 3}.get(rar, 1)
	for i in notches:
		var x := SIZE.x / 2 - (notches - 1) * 7 + i * 14
		draw_rect(Rect2(x - 3, SIZE.y - 7, 6, 4), rc.lightened(0.5))
	if rar in ["legendary", "epic"]:
		var k := fmod(real * 0.35, 1.0)
		var sx := -40 + k * (SIZE.x + 80)
		draw_colored_polygon(PackedVector2Array([Vector2(sx, 0), Vector2(sx + 14, 0), Vector2(sx - 20, SIZE.y), Vector2(sx - 34, SIZE.y)]), Color(1, 1, 0.85, 0.18))
	# paper
	var paper := Rect2(8, 8, SIZE.x - 16, SIZE.y - 16)
	draw_rect(paper, Art.PAPER)
	# family band and name
	var band := Rect2(8, 8, SIZE.x - 16, 24)
	draw_rect(band, fc)
	draw_rect(Rect2(band.position + Vector2(0, band.size.y), Vector2(band.size.x, 2)), fc.darkened(0.4))
	_family_mark(fam, Vector2(SIZE.x - 20, 20))
	var nm: String = c.get("name", card_id)
	var nw := font.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	var np := Vector2((SIZE.x - nw) / 2 + 4, 26)
	draw_string_outline(font, np, nm, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, 4, fc.darkened(0.6))
	draw_string(font, np, nm, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
	# art window
	var art := Rect2(14, 38, SIZE.x - 28, 56)
	draw_rect(art.grow(2), Art.INK)
	draw_rect(art, Color("#26222e"))
	_art(art)
	# seconds badge (top-left): the cost everything else is measured in
	var secs := int(c.get("time", 0))
	var bc := Vector2(14, 14)
	draw_circle(bc, 15, Art.INK)
	draw_circle(bc, 13, Color("#f4e6c2") if secs > 0 else Color("#bfe8ff"))
	draw_arc(bc, 13, -PI / 2, -PI / 2 + TAU * minf(secs / 6.0, 1.0), 20, Color("#c9853a") if secs > 0 else Color("#5aa8ff"), 3)
	var st := "%d" % secs
	var sw := font.get_string_size(st, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
	draw_string(font, bc + Vector2(-sw / 2, 7), st, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Art.INK)
	if int(c.get("weight", 1)) > 1:
		draw_rect(Rect2(SIZE.x - 22, SIZE.y - 18, 5, 8), Art.INK)
		draw_rect(Rect2(SIZE.x - 15, SIZE.y - 18, 5, 8), Art.INK)
	if ghost:
		draw_rect(r, Color(0.05, 0.05, 0.08, 0.35))

func _family_mark(fam: String, c: Vector2) -> void:
	match fam:
		"sword":
			draw_line(c + Vector2(-5, 5), c + Vector2(5, -5), Color.WHITE, 2)
			draw_line(c + Vector2(-5, 1), c + Vector2(-1, 5), Color.WHITE, 2)
		"magic":
			var pts := PackedVector2Array()
			for i in 8:
				var rr := 6.0 if i % 2 == 0 else 2.5
				pts.append(c + Vector2(sin(i * PI / 4), -cos(i * PI / 4)) * rr)
			draw_colored_polygon(pts, Color.WHITE)
		_:
			draw_circle(c, 4, Color.WHITE)
			draw_circle(c, 2, Art.FAMILY["neutral"])

## Card picture. Uses the matching effect sprite where there is one; otherwise a simple emblem.
func _art(a: Rect2) -> void:
	var c := a.get_center()
	var fxmap := {"spark": "fire", "crystallize": "crystal", "rain": "splash"}
	if fxmap.has(card_id):
		var spec: Dictionary = Art.FX[fxmap[card_id]]
		var t := Art.tex(spec["path"])
		if t:
			var src := Art.frame_rect(t, spec["w"], int(real * 12.0) % Art.frames(t, spec["w"]))
			var sc := minf(a.size.y / src.size.y, 3.0)
			var sz := src.size * sc
			draw_texture_rect_region(t, Rect2(c - sz / 2, sz), src)
			return
	var w := Color("#e9dfc8")
	var k := real
	match card_id:
		"strike":
			draw_arc(c + Vector2(-6, 10), 30, -PI * 0.9, -PI * 0.25, 16, w, 4)
			draw_arc(c + Vector2(-6, 10), 26, -PI * 0.85, -PI * 0.3, 16, Color("#ff8a6a"), 2)
		"guard":
			var p := PackedVector2Array([c + Vector2(-18, -22), c + Vector2(18, -22), c + Vector2(16, 4), c + Vector2(0, 24), c + Vector2(-16, 4)])
			draw_colored_polygon(p, Color("#7fb6e8"))
			draw_polyline(p + PackedVector2Array([p[0]]), Art.INK, 2)
		"step":
			for i in 3:
				var y := -12 + i * 12
				var x0 := fmod(k * 60.0 + i * 20, 40.0) - 30
				draw_line(c + Vector2(x0, y), c + Vector2(x0 + 22, y), Color(w, 0.8), 3)
			draw_circle(c + Vector2(22, 0), 7, w)
		"frost":
			for i in 3:
				var d := Vector2(cos(i * PI / 3), sin(i * PI / 3)) * 24
				draw_line(c - d, c + d, Color("#d8f2ff"), 3)
		"oil_spill":
			draw_circle(c + Vector2(0, 6), 16, Color("#3a2c1c"))
			draw_colored_polygon(PackedVector2Array([c + Vector2(-16, 4), c + Vector2(16, 4), c + Vector2(0, -24)]), Color("#3a2c1c"))
			draw_arc(c + Vector2(-4, 6), 8, PI, PI * 1.5, 8, Color(0.6, 0.9, 0.6, 0.6), 2)
		"shock":
			draw_polyline(PackedVector2Array([c + Vector2(4, -28), c + Vector2(-8, 0), c + Vector2(6, 0), c + Vector2(-6, 28)]), Color("#ffe14a"), 5)
		"gust":
			for i in 3:
				draw_arc(c + Vector2(-6 + i * 8, 0), 10 + i * 6, -PI * 0.2 + k, PI * 1.1 + k, 16, Color(w, 0.8 - i * 0.2), 2)
		"gravity_well":
			for i in 4:
				var rr := fmod(28 - k * 14 - i * 7, 28.0)
				draw_arc(c, rr, 0, TAU, 24, Color(0.7, 0.55, 1.0, rr / 28.0), 2)
			draw_circle(c, 4, Color("#1a1024"))
		"compress":
			for i in 3:
				var x := -18 + i * 18
				var y := fmod(k * 20.0, 10.0) - 22
				draw_line(c + Vector2(x, y), c + Vector2(x, y + 22), w, 3)
				draw_colored_polygon(PackedVector2Array([c + Vector2(x - 6, y + 18), c + Vector2(x + 6, y + 18), c + Vector2(x, y + 26)]), w)
			draw_rect(Rect2(c + Vector2(-30, 22), Vector2(60, 4)), Color("#8c7a6a"))
		"laser":
			draw_line(c + Vector2(-50, 0), c + Vector2(50, 0), Color(1, 1, 0.8, 0.5), 9)
			draw_line(c + Vector2(-50, 0), c + Vector2(50, 0), Color(1, 1, 1), 3)
			draw_circle(c + Vector2(-50 + fmod(k * 80.0, 100.0), 0), 4, Color.WHITE)
		"mirror":
			var fr := Rect2(c - Vector2(14, 24), Vector2(28, 48))
			draw_rect(fr, Color("#c8d0dc"))
			draw_rect(fr.grow(-3), Color("#6e8fae"))
			draw_line(fr.position + Vector2(8, 6), fr.position + Vector2(2, 30), Color(1, 1, 1, 0.8), 2)
		"slow_field":
			draw_rect(Rect2(c - Vector2(40, 6), Vector2(80, 26)), Color("#3d4a20"))
			for i in 4:
				var bb := fmod(k * 0.6 + i * 0.27, 1.0)
				draw_arc(c + Vector2(-24 + i * 16, 10 - bb * 10), 3 + bb * 2, 0, TAU, 8, Color(0.7, 0.8, 0.4, 1.0 - bb), 2)
		"haste_field", "hurry":
			draw_colored_polygon(PackedVector2Array([c + Vector2(-10, -20), c + Vector2(10, -20), c + Vector2(0, 0)]), Color("#e8c070"))
			draw_colored_polygon(PackedVector2Array([c + Vector2(-10, 20), c + Vector2(10, 20), c + Vector2(0, 0)]), Color("#e8c070"))
			var wing := 1 if card_id == "haste_field" else 2
			for i in wing:
				draw_arc(c + Vector2(-16 - i * 6, -6), 10, PI * 0.6, PI * 1.3, 8, w, 2)
				draw_arc(c + Vector2(16 + i * 6, -6), 10, -PI * 0.3, PI * 0.4, 8, w, 2)
		"bullet_time":
			for i in 5:
				draw_rect(Rect2(c + Vector2(-44 + i * 10, -2), Vector2(6, 4)), Color(0.7, 0.6, 1.0, 0.15 + i * 0.12))
			draw_colored_polygon(PackedVector2Array([c + Vector2(6, -6), c + Vector2(24, -6), c + Vector2(32, 0), c + Vector2(24, 6), c + Vector2(6, 6)]), Color("#d8c080"))
			draw_arc(c, 30, 0, TAU, 32, Color(0.7, 0.6, 1.0, 0.5), 2)
		"body_swap":
			draw_arc(c, 20, PI * 0.1, PI * 0.9, 12, w, 3)
			draw_arc(c, 20, PI * 1.1, PI * 1.9, 12, Color("#ff8a6a"), 3)
			draw_circle(c + Vector2(-20, 0), 6, w)
			draw_circle(c + Vector2(20, 0), 6, Color("#ff8a6a"))
		"pickpocket":
			draw_rect(Rect2(c - Vector2(10, 18), Vector2(22, 30)), Art.PAPER)
			draw_rect(Rect2(c - Vector2(10, 18), Vector2(22, 30)), Art.INK, false, 2)
			draw_circle(c + Vector2(-14, 16), 10, Color("#5a4a3a"))
		"bind_soul":
			draw_rect(Rect2(c - Vector2(14, 22), Vector2(28, 40)), Color("#3a3050"))
			draw_rect(Rect2(c - Vector2(14, 22), Vector2(28, 40)), Color("#c0a0ff"), false, 2)
			for i in 4:
				var q := fmod(k * 0.5 + i * 0.25, 1.0)
				draw_circle(c + Vector2(sin(q * TAU) * 20 * (1 - q), -30 + q * 30), 3, Color(0.8, 0.7, 1.0, 1.0 - q))
		_:
			draw_circle(c, 14, Color(w, 0.6))
