class_name HandCursor
extends Node
## The mouse cursor is the playing character's own hand (ui/hand_<who>.png: frame 0 open,
## frame 1 pressing). Nothing else moves on its own: no darting or sweeping.

const SCALE := 2
const HOT := {"open": Vector2(6, 3), "press": Vector2(6, 4)}
const FILES := {"walker": "ui/hand_rogue.png"}

var _imgs: Dictionary = {}   # "open" / "press" -> Image
var _who := ""
var _down := false

func set_actor(def_id: String) -> void:
	var file: String = FILES.get(def_id, FILES["walker"])
	if file == _who:
		return
	_who = file
	_imgs = {}
	var tex := Art.tex(file)
	if tex == null:
		Input.set_custom_mouse_cursor(null)
		return
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	var fw := 24
	var fh := mini(28, img.get_height())
	for k in ["open", "press"]:
		var i := 0 if k == "open" else mini(1, img.get_width() / fw - 1)
		var fr := img.get_region(Rect2i(i * fw, 0, fw, fh))
		fr.resize(fw * SCALE, fh * SCALE, Image.INTERPOLATE_NEAREST)
		_imgs[k] = fr
	_apply()

func _apply() -> void:
	var k := "press" if _down else "open"
	if _imgs.has(k):
		Input.set_custom_mouse_cursor(_imgs[k], Input.CURSOR_ARROW, HOT[k] * SCALE)
		Input.set_custom_mouse_cursor(_imgs[k], Input.CURSOR_POINTING_HAND, HOT[k] * SCALE)

func _input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT and ev.pressed != _down:
		_down = ev.pressed
		_apply()

func _exit_tree() -> void:
	Input.set_custom_mouse_cursor(null)
