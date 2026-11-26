class_name HandCursor
extends Control
## The player's hand over the cards (the choice is the player's judgement): it trails the mouse
## while it is over the hand, darts to a card picked by hotkey and taps it, and sweeps sideways
## when the wheel flips through the hand. Each character can have its own glove.
## Uses the glove sprite (ui/hand_rogue.png); the tiny bitmap below is only a fallback.

const S := 4
const ART := [
	".....kk.......",
	"....kghk......",
	"....kghk......",
	"....kghk......",
	"....kghkkk....",
	"....kghkghkk..",
	"..kkkghkghkghk",
	".kghkghkghkghk",
	".kghhgggggghgk",
	".kgggggggggggk",
	"..kggggggggggk",
	"..kgggggggggk.",
	"...kgggggggk..",
	"...kcccccccck.",
	"...kcdcdcdcdk.",
	"...kkkkkkkkkk.",
]
const TIP := Vector2(5.5, 0.5)   # fingertip in bitmap cells
const GLOVES := {
	"walker": {"g": Color("#3b3346"), "h": Color("#5d5170"), "c": Color("#2b4a7a"), "d": Color("#1d3155")},
}

var glove: Dictionary = GLOVES["walker"]
var pos := Vector2(640, 900)      # fingertip on screen
var target := Vector2(640, 900)
var shown := false
var tap_t := -9.0
var sweep_t := -9.0
var sweep_dir := 0
var real := 0.0
var region_top := 600.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	z_index = 30

func set_actor(def_id: String) -> void:
	glove = GLOVES.get(def_id, GLOVES["walker"])

## Hotkey pick: the hand darts to the card and taps it.
func pick(cv: Control) -> void:
	target = cv.global_position + cv.size * cv.scale * Vector2(0.5, 0.25)
	tap_t = real + 0.08
	shown = true

## Wheel flip: a quick sideways sweep across the hand.
func sweep(dir: int) -> void:
	sweep_t = real
	sweep_dir = dir
	shown = true

func _process(delta: float) -> void:
	real += delta
	var mp := get_viewport().get_mouse_position()
	var over := mp.y >= region_top
	if over:
		target = mp
		shown = true
	elif real - tap_t > 0.5 and real - sweep_t > 0.5:
		shown = false
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN if over else Input.MOUSE_MODE_VISIBLE
	var follow := 30.0 if real - tap_t < 0.3 else 18.0
	pos = pos.lerp(target, 1.0 - exp(-follow * delta))
	queue_redraw()

func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _draw() -> void:
	if not shown:
		return
	var at := pos
	var rot := -0.18
	# tap: a short press down; sweep: slides across and tilts
	var tk := real - tap_t
	if tk >= 0.0 and tk < 0.22:
		at.y += sin(tk / 0.22 * PI) * 7 * S
	var sk := real - sweep_t
	if sk >= 0.0 and sk < 0.35:
		var e := sk / 0.35
		at.x += sweep_dir * (e - 0.5) * 2.0 * 70.0
		at.y += 10.0
		rot += sweep_dir * 0.6 * sin(e * PI)
	var tex := Art.tex("ui/hand_rogue.png")
	if tex != null:
		# the sprite: 0 point, 1 press, 2 swipe (mirrored for a rightward swipe); fingertip is the hotspot
		var fr := 0
		if tk >= 0.0 and tk < 0.22:
			fr = 1
		var flip := false
		if sk >= 0.0 and sk < 0.35:
			fr = 2
			flip = sweep_dir > 0
		var hot := Vector2(6, 4 if fr == 1 else 3)
		var k := 3.0
		draw_set_transform(at, 0.0, Vector2(-k if flip else k, k))
		draw_texture_rect_region(tex, Rect2(-hot + Vector2(1.5, 2), Vector2(24, 28)), Rect2(fr * 24, 0, 24, 28), Color(0, 0, 0, 0.3))
		draw_texture_rect_region(tex, Rect2(-hot, Vector2(24, 28)), Rect2(fr * 24, 0, 24, 28))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	draw_set_transform(at, rot, Vector2.ONE)
	# shadow, then the glove
	for y in ART.size():
		var row: String = ART[y]
		for x in row.length():
			var ch := row[x]
			if ch == ".":
				continue
			var col: Color = Color("#0d0c12") if ch == "k" else glove.get(ch, Color.MAGENTA)
			draw_rect(Rect2((Vector2(x, y) - TIP) * S + Vector2(4, 6), Vector2(S, S)), Color(0, 0, 0, 0.25))
			draw_rect(Rect2((Vector2(x, y) - TIP) * S, Vector2(S, S)), col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
