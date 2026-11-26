class_name Art
extends RefCounted
## Pixel art used by the battle screen, described by res://assets/art/manifest.json (frame size,
## count, fps, anchor). The board draws 16 px cells scaled by S; card UI is scaled by UI_S.

const T := 16          # art pixels per cell
const S := 3           # board: screen pixels per art pixel
const UI_S := 2        # cards and wheel: screen pixels per art pixel
const CELL := T * S
const ROOT := "res://assets/art/"

static var _cache: Dictionary = {}
static var _manifest: Dictionary = {}

static func manifest() -> Dictionary:
	if _manifest.is_empty():
		var f := FileAccess.open(ROOT + "manifest.json", FileAccess.READ)
		if f:
			var d = JSON.parse_string(f.get_as_text())
			_manifest = d if d is Dictionary else {"_": 1}
		else:
			_manifest = {"_": 1}
	return _manifest

static func tex(path: String) -> Texture2D:
	if not path.begins_with("res://"):
		path = ROOT + path
	if _cache.has(path):
		return _cache[path]
	var t: Texture2D = null
	if ResourceLoader.exists(path):
		t = load(path)
	_cache[path] = t
	return t

## A strip from the manifest: {tex, w, h, n, fps, loop, ax, ay}. Empty when missing.
static func strip(group: String, file: String) -> Dictionary:
	var key := group + "/" + file
	if _cache.has("strip:" + key):
		return _cache["strip:" + key]
	var spec: Dictionary = manifest().get(group, {}).get(file, {})
	var t := tex(key)
	var out := {}
	if t != null:
		var fr: Array = spec.get("frame", [t.get_height(), t.get_height()])
		var an: Array = spec.get("anchor", [fr[0] / 2, fr[1] - 2])
		out = {"tex": t, "w": int(fr[0]), "h": int(fr[1]), "n": int(spec.get("count", maxi(1, t.get_width() / int(fr[0])))),
			"fps": float(spec.get("fps", 12)), "loop": bool(spec.get("loop", true)), "ax": float(an[0]), "ay": float(an[1])}
	_cache["strip:" + key] = out
	return out

static func frame_src(st: Dictionary, i: int) -> Rect2:
	var n: int = st["n"]
	return Rect2((i % n) * st["w"], 0, st["w"], st["h"])

## Frame index for a strip at time `t` seconds (one-shots hold their last frame).
static func frame_at(st: Dictionary, t: float, offset := 0) -> int:
	var i := int(t * float(st["fps"])) + offset
	if not st["loop"]:
		return clampi(i, 0, int(st["n"]) - 1)
	return i % int(st["n"])

static func fx(name: String) -> Dictionary:
	return strip("fx", name + ".png")

## Unit sprite strip; faces_right tells which way the art looks.
static func unit(def_id: String) -> Dictionary:
	var st := strip("units", def_id + ".png")
	if st.is_empty():
		st = strip("units", "walker.png")
	if st.is_empty():
		return {}
	var d := st.duplicate()
	d["faces_right"] = def_id == "hero"
	return d

## Sprite id for an actor: the player's body uses the hero art.
static func unit_id(a: Actor) -> String:
	if (a.controller == "human" and a.def_id == "walker") or a.controller == "echo":
		return "hero"
	return a.def_id

# ---- palette shared by UI drawing
const INK := Color("#0d0c12")
const PAPER := Color("#e9dfc8")
const GOLD := Color("#f1c35a")
const DANGER := Color("#ff4a3a")
const FAMILY := {"sword": Color("#b0453d"), "magic": Color("#7656c4"), "neutral": Color("#4f7a62")}

static func card_frame(family: String, rarity: String) -> Texture2D:
	if rarity == "epic":
		rarity = "legendary"
	if not family in ["sword", "magic", "neutral"]:
		family = "neutral"
	if not rarity in ["basic", "common", "rare", "legendary"]:
		rarity = "common"
	return tex("ui/cards/card_frame_%s_%s.png" % [family, rarity])

static var _fonts: Dictionary = {}
static func font(name: String) -> Font:
	if not _fonts.has(name):
		_fonts[name] = load("res://assets/fonts/%s.ttf" % name)
	return _fonts[name]
