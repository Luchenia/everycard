extends SceneTree
## Screenshots of reach shapes: a thrown dagger (8 straight ways) and an oil flask (round).
## xvfb-run -a -s "-screen 0 1280x800x24" tools/run.sh --rendering-driver opengl3 --script res://tools/capture_reach.gd

var screen
var frame := 0

func _initialize() -> void:
	screen = load("res://scenes/battle.tscn").instantiate()
	root.add_child(screen)

func _pick(id: String) -> void:
	var b = screen.flow.battle
	b.belt.slots[2]["card_id"] = id
	screen.selected = 2
	screen._update_span()

func _shot(n: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://evidence/screen"))
	root.get_viewport().get_texture().get_image().save_png("res://evidence/screen/%s.png" % n)
	print("saved ", n)

func _process(_d: float) -> bool:
	frame += 1
	if frame == 2:
		var b = screen.flow.battle
		b.grid.move_unit(b.human(), Vector2i(6, 4))
		screen._refresh()
		_pick("throw_dagger")
	if frame == 30:
		_shot("31_reach_line")
		_pick("oil_spill")
	if frame == 60:
		_shot("32_reach_circle")
		_pick("strike")
	if frame == 90:
		_shot("33_reach_square")
		return true
	return false
