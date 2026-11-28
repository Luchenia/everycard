class_name CardPixels
extends RefCounted
## The picture a player draws for a card: exactly the card's picture window (CardView.ART_WIN, 64x51).
## Pure data + drawing operations + undo, no UI, so it can be tested headless.

const W := 64
const H := 51
const UNDO_LIMIT := 64

## Our own 32-colour palette, in ramps (dark -> light) that sit well on the dark picture window.
const PALETTE := [
	"#0d0c12", "#2a2836", "#4a4858", "#757384", "#a8a6b4", "#e9e6ee",
	"#3a2418", "#6a3f24", "#a0663a", "#d6a46a",
	"#4a1420", "#8c2430", "#d0443a", "#ff8a6a",
	"#a8521c", "#e88a2a", "#f1c35a", "#fff0a0",
	"#1c3a24", "#2f6a3a", "#5ea84a", "#b4e070",
	"#183048", "#2a5a8c", "#4a9ad6", "#9ad8f0",
	"#3a2058", "#7656c4", "#c0a0ff",
	"#e8b896", "#f3dca0", "#ffffff",
]

var image: Image
var _undo: Array[PackedByteArray] = []
var _redo: Array[PackedByteArray] = []

func _init() -> void:
	image = Image.create_empty(W, H, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

static func palette_colors() -> Array[Color]:
	var out: Array[Color] = []
	for h in PALETTE:
		out.append(Color(h))
	return out

func inside(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < W and p.y < H

func get_px(p: Vector2i) -> Color:
	return image.get_pixelv(p) if inside(p) else Color(0, 0, 0, 0)

func is_blank() -> bool:
	return image.is_invisible()

## Call once before every stroke / fill / clear so one undo reverts the whole action.
func begin_action() -> void:
	_undo.append(image.get_data())
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()
	_redo.clear()

func can_undo() -> bool:
	return not _undo.is_empty()

func can_redo() -> bool:
	return not _redo.is_empty()

func undo() -> bool:
	if _undo.is_empty():
		return false
	_redo.append(image.get_data())
	_restore(_undo.pop_back())
	return true

func redo() -> bool:
	if _redo.is_empty():
		return false
	_undo.append(image.get_data())
	_restore(_redo.pop_back())
	return true

func _restore(data: PackedByteArray) -> void:
	image.set_data(W, H, false, Image.FORMAT_RGBA8, data)

## Square brush of `size` px (1..4), optionally mirrored across the vertical centre line.
func dab(p: Vector2i, c: Color, size := 1, mirror := false) -> void:
	var o := -(size - 1) / 2
	for dy in size:
		for dx in size:
			var q := p + Vector2i(o + dx, o + dy)
			if inside(q):
				image.set_pixelv(q, c)
			if mirror:
				var m := Vector2i(W - 1 - q.x, q.y)
				if inside(m):
					image.set_pixelv(m, c)

static func line_points(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var d := (b - a).abs()
	var s := Vector2i(1 if a.x < b.x else -1, 1 if a.y < b.y else -1)
	var err := d.x - d.y
	var p := a
	while true:
		out.append(p)
		if p == b:
			break
		var e2 := err * 2
		if e2 > -d.y:
			err -= d.y
			p.x += s.x
		if e2 < d.x:
			err += d.x
			p.y += s.y
	return out

func line(a: Vector2i, b: Vector2i, c: Color, size := 1, mirror := false) -> void:
	for p in line_points(a, b):
		dab(p, c, size, mirror)

static func rect_points(a: Vector2i, b: Vector2i, filled: bool) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var lo := Vector2i(mini(a.x, b.x), mini(a.y, b.y))
	var hi := Vector2i(maxi(a.x, b.x), maxi(a.y, b.y))
	for y in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			if filled or x == lo.x or x == hi.x or y == lo.y or y == hi.y:
				out.append(Vector2i(x, y))
	return out

func rect(a: Vector2i, b: Vector2i, c: Color, filled := false, mirror := false) -> void:
	for p in rect_points(a, b, filled):
		dab(p, c, 1, mirror)

## 4-way flood fill of the region that has exactly the colour under `p`.
func fill(p: Vector2i, c: Color, mirror := false) -> void:
	if not inside(p):
		return
	var target := image.get_pixelv(p)
	if target.is_equal_approx(c):
		return
	var stack: Array[Vector2i] = [p]
	var seen := {}
	while not stack.is_empty():
		var q: Vector2i = stack.pop_back()
		if seen.has(q) or not inside(q) or not image.get_pixelv(q).is_equal_approx(target):
			continue
		seen[q] = true
		image.set_pixelv(q, c)
		stack.append_array([q + Vector2i.RIGHT, q + Vector2i.LEFT, q + Vector2i.DOWN, q + Vector2i.UP])
	if mirror:
		var m := Vector2i(W - 1 - p.x, p.y)
		if not seen.has(m):
			fill(m, c, false)

func clear() -> void:
	image.fill(Color(0, 0, 0, 0))

## Shift the whole picture by d pixels (wraps), for nudging a drawing into place.
func shift(d: Vector2i) -> void:
	var src := image.duplicate()
	for y in H:
		for x in W:
			image.set_pixel(posmod(x + d.x, W), posmod(y + d.y, H), src.get_pixel(x, y))

func flip_h() -> void:
	image.flip_x()

## Fit any image (a rough, a photo) into the window, keep its aspect, snap to the palette.
func import_image(src: Image) -> void:
	var im := src.duplicate()
	im.convert(Image.FORMAT_RGBA8)
	var k := minf(float(W) / im.get_width(), float(H) / im.get_height())
	var sz := Vector2i(maxi(1, roundi(im.get_width() * k)), maxi(1, roundi(im.get_height() * k)))
	im.resize(sz.x, sz.y, Image.INTERPOLATE_BILINEAR)
	var cols := palette_colors()
	var off := (Vector2i(W, H) - sz) / 2
	clear()
	for y in sz.y:
		for x in sz.x:
			var c: Color = im.get_pixel(x, y)
			if c.a < 0.5:
				continue
			image.set_pixel(off.x + x, off.y + y, nearest(c, cols))

static func nearest(c: Color, cols: Array[Color]) -> Color:
	var best := cols[0]
	var bd := INF
	for p in cols:
		var d := Vector3(c.r - p.r, c.g - p.g, c.b - p.b)
		var dd: float = d.x * d.x * 0.3 + d.y * d.y * 0.59 + d.z * d.z * 0.11
		if dd < bd:
			bd = dd
			best = p
	return best
