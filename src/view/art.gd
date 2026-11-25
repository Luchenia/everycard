class_name Art
extends RefCounted
## Pixel art used by the battle screen. Everything is drawn at 16 px per cell and scaled by S.
## Sprites from res://assets/art/ win; anything missing gets a small generated stand-in so the
## screen never shows an empty spot.

const T := 16          # art pixels per cell
const S := 3           # screen pixels per art pixel
const CELL := T * S

static var _cache: Dictionary = {}

static func tex(path: String) -> Texture2D:
	if _cache.has(path):
		return _cache[path]
	var t: Texture2D = null
	if ResourceLoader.exists(path):
		t = load(path)
	_cache[path] = t
	return t

## One frame of a horizontal strip of `w`-wide frames.
static func frame_rect(t: Texture2D, w: int, i: int) -> Rect2:
	var n := maxi(1, int(t.get_width() / w))
	return Rect2((i % n) * w, 0, w, t.get_height())

static func frames(t: Texture2D, w: int) -> int:
	return maxi(1, int(t.get_width() / w))

# ---- effect strips: {path, frame width, anchor x/y inside the frame (cell bottom-centre goes there), fps}
const FX := {
	"fire": {"path": "res://assets/art/fx/fire.png", "w": 16, "ax": 8, "ay": 32, "fps": 24},
	"crystal": {"path": "res://assets/art/fx/crystal.png", "w": 16, "ax": 8, "ay": 26, "fps": 20},
	"splash": {"path": "res://assets/art/fx/splash.png", "w": 16, "ax": 8, "ay": 12, "fps": 20},
}

# ---- units: def_id -> sprite. Stand-ins are generated for any def without art.
const UNIT_ART := {
	"walker": "res://assets/art/units/hero.png",
	"hero": "res://assets/art/units/hero.png",
}

static func unit_tex(def_id: String) -> Texture2D:
	var key := "unit:" + def_id
	if _cache.has(key):
		return _cache[key]
	var path: String = UNIT_ART.get(def_id, "res://assets/art/units/%s.png" % def_id)
	var t := tex(path)
	if t == null:
		t = _standin(def_id)
	_cache[key] = t
	return t

## Small generated stand-ins (until real sprites arrive): a shape per enemy kind with a 1px ink edge.
static func _standin(def_id: String) -> Texture2D:
	var w := 24
	var h := 24
	var body := Color("#6cc16a")
	var dark := Color("#2f6b3a")
	var kind := "blob"
	match def_id:
		"slime":
			body = Color("#79d06f"); dark = Color("#2f7a3f"); kind = "blob"
		"ember_imp":
			body = Color("#e0663a"); dark = Color("#7a2a1a"); kind = "imp"
		"iron_golem":
			w = 28; h = 32; body = Color("#8a92a0"); dark = Color("#3c4250"); kind = "golem"
		"boss_tide_warden":
			w = 36; h = 42; body = Color("#4f8fd0"); dark = Color("#1f3c66"); kind = "golem"
		_:
			body = Color("#b0a0d0"); dark = Color("#4a3f66"); kind = "imp"
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := w / 2.0
	for y in h:
		for x in w:
			var inside := false
			var fx := (x + 0.5 - cx)
			var fy := float(y) + 0.5
			match kind:
				"blob":
					var top := h * 0.42
					inside = fy > top and pow(fx / (w * 0.44), 2) + pow((fy - h) / (h - top), 2) < 1.0
				"imp":
					var head := pow(fx / 6.0, 2) + pow((fy - 9.0) / 6.0, 2) < 1.0
					var torso := absf(fx) < 5.0 - (fy - 14.0) * 0.1 and fy > 13.0 and fy < h - 1
					var horn := (absf(absf(fx) - 5.0) < 1.0 and fy > 2.0 and fy < 6.0)
					inside = head or torso or horn
				"golem":
					var head2 := absf(fx) < w * 0.22 and fy > 1 and fy < h * 0.3
					var torso2 := absf(fx) < w * 0.42 and fy >= h * 0.3 and fy < h * 0.75
					var legs := absf(absf(fx) - w * 0.22) < w * 0.12 and fy >= h * 0.75 and fy < h - 0.5
					inside = head2 or torso2 or legs
			if inside:
				var shade := body.darkened(0.25) if fy > h * 0.7 or fx > w * 0.25 else body
				if fx < -w * 0.15 and fy < h * 0.6:
					shade = body.lightened(0.18)
				img.set_pixel(x, y, shade)
	# eyes
	var ey := int(h * 0.62) if kind == "blob" else (9 if kind == "imp" else int(h * 0.17))
	for ex in [int(cx) - 3, int(cx) + 2]:
		if ex >= 0 and ex < w and ey < h and img.get_pixel(ex, ey).a > 0.0:
			img.set_pixel(ex, ey, Color("#14121a"))
			if ey - 1 >= 0:
				img.set_pixel(ex, ey - 1, Color("#14121a"))
	# ink edge
	var out := img.duplicate()
	for y in h:
		for x in w:
			if img.get_pixel(x, y).a > 0.0:
				continue
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var q: Vector2i = Vector2i(x, y) + d
				if q.x >= 0 and q.y >= 0 and q.x < w and q.y < h and img.get_pixel(q.x, q.y).a > 0.0:
					out.set_pixel(x, y, dark.darkened(0.4))
					break
	return ImageTexture.create_from_image(out)

# ---- palette shared by UI drawing
const INK := Color("#0d0c12")
const PAPER := Color("#e9dfc8")
const GOLD := Color("#f1c35a")
const DANGER := Color("#ff4a3a")
const RARITY := {"basic": Color("#8b909c"), "common": Color("#b5814e"), "rare": Color("#5b8fe0"),
	"epic": Color("#e0b040"), "legendary": Color("#e0b040")}
const FAMILY := {"sword": Color("#b0453d"), "magic": Color("#7656c4"), "neutral": Color("#4f7a62")}
