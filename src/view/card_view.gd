class_name CardView
extends Control
## One card face on the painted frames (ui/cards/card_frame_<family>_<rarity>.png, 76x127 art px).
## Drawn at `zoom` screen px per art px: 1 resting on the hand wheel, 2 when hovered, picked or
## offered. Seconds in the top-left badge, picture in the art window, name on the plate, the
## sentence in the text box; trailing keywords ([감전] [반사] ...) become chips under the picture.

signal picked(card_view)
signal hovered(card_view, on)
signal inspected(card_view)

const SIZE := Vector2(88, 136)      # art px
const ART_WIN := Rect2(12, 12, 64, 51)
const NAME_PLATE := Rect2(12, 67, 67, 8)
const TEXT_BOX := Rect2(8, 79, 71, 49)
const MAX_LINES := 6
const BADGE := Vector2(77, 11)   # top-right
const FXMAP := {"sweep": "slash", "flint": "fire", "strike": "slash", "spark": "fire", "crystallize": "crystal", "rain": "water_splash", "mirror": "mirror",
	"frost": "ice_glint", "slow_field": "swamp_bubbles", "gust": "gust_right", "shock": "shock", "hurry": "haste", "haste_field": "haste"}

var card_id := ""
var catalog: Catalog
var font: Font
var desc: RichTextLabel
var chips: Array = []
var lines := 1
var real := 0.0
var zoom := 1
var lit := false     # selected
var time_rate := 1.0:   # world seconds per card second (불릿타임 shows a third)
	set(v):
		if v != time_rate:
			time_rate = v
			queue_redraw()
var ghost := false

func setup(id: String, cat: Catalog, f: Font, z := 1) -> void:
	card_id = id
	catalog = cat
	font = f
	mouse_filter = Control.MOUSE_FILTER_STOP
	desc = RichTextLabel.new()
	desc.bbcode_enabled = true
	desc.scroll_active = false
	desc.fit_content = false
	desc.autowrap_mode = TextServer.AUTOWRAP_OFF
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc.add_theme_font_override("normal_font", Art.font("Galmuri7"))
	desc.add_theme_color_override("default_color", Color("#34281E"))
	desc.add_theme_constant_override("line_separation", 0)
	var wrapped := CardView.wrap_words(def().get("desc", ""), Art.font("Galmuri7"), 8, TEXT_BOX.size.x - 2)
	lines = wrapped.count("\n") + 1
	desc.text = "[center]%s[/center]" % CardView.rich(wrapped, "#964614")
	add_child(desc)
	set_zoom(z)
	mouse_entered.connect(func(): hovered.emit(self, true))
	mouse_exited.connect(func(): hovered.emit(self, false))

func set_zoom(z: int) -> void:
	zoom = z
	size = SIZE * z
	pivot_offset = Vector2(size.x / 2, size.y)
	# the block is centred vertically in the text box (8 px per line)
	# ink centred on x 44.5 and the block on y 103.5 (advance widths carry 1 px of trailing space)
	desc.position = ((TEXT_BOX.position + Vector2(1.5, (MAX_LINES - mini(lines, MAX_LINES)) * 4)) * z).round()
	desc.size = Vector2(TEXT_BOX.size.x, TEXT_BOX.size.y + 4) * z
	desc.add_theme_font_size_override("normal_font_size", 8 * z)
	desc.add_theme_constant_override("line_separation", -z)

func def() -> Dictionary:
	return Effects.card_def(card_id, catalog)

## "sentence. [a] [b]" -> ["sentence.", ["a", "b"]]: keywords tacked on after the sentence.
static func split_chips(text: String) -> Array:
	var t := text.strip_edges()
	var out := []
	while t.ends_with("]"):
		var a := t.rfind("[")
		if a <= 0:
			break
		var before := t.substr(0, a).strip_edges()
		if not (before.ends_with(".") or before.ends_with("]") or before.ends_with("!")):
			break
		out.push_front(t.substr(a + 1, t.length() - a - 2))
		t = before
	return [t, out]
## Korean is wrapped by whole words (어절), never inside one: break lines at spaces only.
static func wrap_words(text: String, f: Font, px: int, width: float) -> String:
	var lines := []
	var cur := ""
	for w in text.split(" ", false):
		var trial := w if cur == "" else cur + " " + w
		if cur != "" and f.get_string_size(trial.replace("[", "").replace("]", ""), HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > width:
			lines.append(cur)
			cur = w
		else:
			cur = trial
	if cur != "":
		lines.append(cur)
	return "\n".join(lines)

static func rich(text: String, col := "#9a3d12") -> String:
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
		out += text.substr(i, a - i) + "[color=" + col + "]" + text.substr(a + 1, b - a - 1) + "[/color]"
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
	elif ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
		inspected.emit(self)
		accept_event()

func _process(d: float) -> void:
	real += d
	queue_redraw()

func _draw() -> void:
	var c := def()
	var z := float(zoom)
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(Rect2(r.position + Vector2(2, 3) * z, r.size - Vector2(2, 2) * z), Color(0, 0, 0, 0.35))
	if lit:
		var gl := 0.5 + 0.5 * sin(real * 5.0)
		draw_rect(r.grow(2 * z), Color(Art.GOLD, 0.3 + 0.3 * gl))
	var ft := Art.card_frame(c.get("family", "neutral"), c.get("rarity", "common"))
	if ft:
		draw_texture_rect(ft, r, false)
	# picture
	var aw := Rect2(ART_WIN.position * z, ART_WIN.size * z)
	_picture(aw)
	# keyword chips along the bottom of the picture
	var cf := Art.font("Galmuri7")
	var cx := aw.end.x
	for k in range(chips.size() - 1, -1, -1):
		var tw := cf.get_string_size(chips[k], HORIZONTAL_ALIGNMENT_LEFT, -1, int(8 * z)).x
		var cr := Rect2(cx - tw - 4 * z, aw.end.y - 10 * z, tw + 4 * z, 10 * z)
		draw_rect(cr.grow(z * 0.5), Color("#34281E"))
		draw_rect(cr, Color("#f3dca0"))
		draw_string(cf, cr.position + Vector2(2 * z, 8 * z), chips[k], HORIZONTAL_ALIGNMENT_LEFT, -1, int(8 * z), Color("#9a3d12"))
		cx = cr.position.x - 2 * z
	# name
	var nf := Art.font("Galmuri7")
	var nm: String = c.get("name", card_id)
	var np := ((NAME_PLATE.position + Vector2(-0.5, 0)) * z).round()
	var nfs := int(8 * z)
	var base := np.y + (NAME_PLATE.size.y * z + nf.get_ascent(nfs) - nf.get_descent(nfs)) / 2.0
	draw_string(nf, Vector2(np.x, round(base)), nm, HORIZONTAL_ALIGNMENT_CENTER, NAME_PLATE.size.x * z, nfs, Color("#F0ECE0"))
	# seconds
	var bf := Art.font("Galmuri11-Bold")
	var st := "%d" % int(c.get("time", 0)) if time_rate == 1.0 else Battle.fmt_secs(float(c.get("time", 0)) * time_rate)
	var bc := BADGE * z
	var bp := Vector2(bc.x - 9 * z, bc.y + 4.5 * z)
	var fs := int(12 * z) if st.length() < 3 else int(8 * z)   # "0.3" (불릿타임) in a smaller hand to fit the gem
	if st.length() >= 3:
		bp.y -= 1.5 * z
	draw_string_outline(bf, bp, st, HORIZONTAL_ALIGNMENT_CENTER, 18 * z, fs, int(2 * z), Color("#1a120c"))
	draw_string(bf, bp, st, HORIZONTAL_ALIGNMENT_CENTER, 18 * z, fs, Color("#FFF0C8"))
	if int(c.get("weight", 1)) > 1:
		draw_rect(Rect2(Vector2(74, 130) * z, Vector2(2, 4) * z), Art.INK)
		draw_rect(Rect2(Vector2(77, 130) * z, Vector2(2, 4) * z), Art.INK)
	if c.get("rarity", "") in ["legendary", "epic"]:
		var k2 := fmod(real * 0.35, 1.0)
		var sx := (-20 + k2 * 116) * z
		draw_colored_polygon(_shine(aw, sx, z), Color(1, 1, 0.85, 0.16))
	if ghost:
		draw_rect(r, Color(0.05, 0.05, 0.08, 0.35))

func _shine(aw: Rect2, sx: float, z: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for q in [Vector2(sx, aw.position.y), Vector2(sx + 6 * z, aw.position.y), Vector2(sx - 4 * z, aw.end.y), Vector2(sx - 10 * z, aw.end.y)]:
		pts.append(Vector2(clampf(q.x, aw.position.x, aw.end.x), q.y))
	return pts

## The effect's own sprite when there is one, otherwise a drawn emblem (sized for a 128x130 window).
func _picture(aw: Rect2) -> void:
	if FXMAP.has(card_id):
		var st := Art.fx(FXMAP[card_id])
		if not st.is_empty():
			var k := maxi(1, int(minf(aw.size.x * 0.9 / st["w"], aw.size.y * 0.9 / st["h"])))
			var sz := Vector2(st["w"], st["h"]) * k
			var ofs := Vector2(0, 0)
			if card_id == "strike":
				ofs = Vector2(sz.x * 0.15, 0)
			# one-shot sheets (slash) hold a readable frame instead of playing out to an empty tail
			var fi: int = Art.frame_at(st, real) if st["loop"] else int(st["n"] * 0.35)
			draw_texture_rect_region(st["tex"], Rect2(aw.get_center() - sz / 2 + ofs, sz), Art.frame_src(st, fi))
			return
	var zz := zoom / 2.0
	draw_set_transform(aw.get_center(), 0.0, Vector2(zz, zz))
	_art(Rect2(-64, -51, 128, 102))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## Card picture. Uses the matching effect sprite where there is one; otherwise a simple emblem.
func _art(a: Rect2) -> void:
	var c := a.get_center()
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
		"throw_dagger":
			var tip := c + Vector2(26, -10)
			var dd := Vector2(1, -0.4).normalized()
			for i in 3:
				draw_line(c + Vector2(-44 + i * 10, 8 - i * 4), c + Vector2(-30 + i * 10, 2 - i * 4), Color(w, 0.25 + i * 0.15), 2)
			draw_colored_polygon(PackedVector2Array([tip, tip - dd * 26 + Vector2(-dd.y, dd.x) * 5, tip - dd * 26 - Vector2(-dd.y, dd.x) * 5]), Color("#d8dde6"))
			draw_line(tip - dd * 26 + Vector2(-dd.y, dd.x) * 9, tip - dd * 26 - Vector2(-dd.y, dd.x) * 9, Color("#b08840"), 4)
			draw_line(tip - dd * 26, tip - dd * 40, Color("#6a4a2a"), 5)
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
