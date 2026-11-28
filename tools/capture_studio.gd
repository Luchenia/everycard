extends SceneTree
## Boots the card studio, paints a sample picture through the same tool calls, saves screenshots.
## xvfb-run -a -s "-screen 0 1280x800x24" tools/run.sh --rendering-driver opengl3 --script res://tools/capture_studio.gd

var s
var frame := 0

func _initialize() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://card_studio/draft.png"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://card_studio/draft_name.txt"))
	s = load("res://scenes/card_studio.tscn").instantiate()
	root.add_child(s)

func _shot(n: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://evidence/studio"))
	root.get_viewport().get_texture().get_image().save_png("res://evidence/studio/%s.png" % n)
	print("saved ", n)

func _paint() -> void:
	var p: CardPixels = s.pix
	var c := func(h): return Color(h)
	p.begin_action()
	# a flame over a brazier
	p.rect(Vector2i(22, 38), Vector2i(41, 43), c.call("#4a4858"), true)
	p.rect(Vector2i(20, 36), Vector2i(43, 37), c.call("#757384"), true)
	p.rect(Vector2i(26, 44), Vector2i(37, 46), c.call("#2a2836"), true)
	for y in range(8, 36):
		var w := int(12.0 * sin(PI * float(y - 8) / 30.0) * (0.55 + 0.45 * float(y - 8) / 28.0))
		var sway := int(2.0 * sin(y * 0.45))
		for x in range(32 - w + sway, 32 + w + sway):
			var dist := absf(x - 32 - sway) / maxf(1.0, w)
			var col := "#a8521c"
			if dist < 0.75: col = "#e88a2a"
			if dist < 0.5 and y > 14: col = "#f1c35a"
			if dist < 0.25 and y > 22: col = "#fff0a0"
			p.dab(Vector2i(x, y), c.call(col))
	for q in [Vector2i(18, 14), Vector2i(45, 10), Vector2i(14, 24), Vector2i(50, 20)]:
		p.dab(q, c.call("#f1c35a"))
	s.name_edit.text = "화톳불"
	s._refresh()

func _process(_d: float) -> bool:
	frame += 1
	match frame:
		10:
			_shot("01_empty")
		12:
			_paint()
			s._hover = Vector2i(40, 20)
			s._mouse = s.CANVAS.position + Vector2(40, 20) * s.Z
		30:
			_shot("02_drawn")
		32:
			s.mirror = true
			s.tool = CardStudio.Tool.LINE
			s._drag = true
			s._drag_from = Vector2i(4, 4)
			s._hover = Vector2i(14, 12)
		40:
			_shot("03_line_mirror")
			s._drag = false
			s._do("submit")
		55:
			_shot("04_submitted")
			return true
	return false
