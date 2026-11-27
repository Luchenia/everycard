extends SceneTree
## Study capture: an enemy walking several cells, a step, a strike, recording every other frame.
var screen
var frame := 0
var step := 0
var t0 := 0
var n := 0
var out := ""

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="): out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out)
	screen = load("res://scenes/battle.tscn").instantiate()
	root.add_child(screen)

func _grab() -> void:
	root.get_viewport().get_texture().get_image().save_png(out + "f%04d.png" % n)
	n += 1

func _ready_for_next() -> bool:
	return not screen._replaying() and frame - t0 > 45

func _play(b, id: String, aim: Vector2i) -> void:
	b.belt.slots[0] = {"card_id": id, "life": 3.0}
	if not b.cmd_play(0, aim):
		print("could not play ", id, " at ", aim)
		b.cmd_wait(1)
	screen._after()

func _process(_d: float) -> bool:
	frame += 1
	if frame == 2:
		screen.debug_enter("fight")
	if frame < 30: return false
	var b = screen.flow.battle
	if step > 0 and frame % 2 == 0: _grab()
	var h = b.human()
	match step:
		0:
			var foe = b.actors[1]
			b.grid.move_unit(foe, h.pos + Vector2i(6, 0))
			screen.shown_frame = b.frames.size() - 1
			screen._refresh()
			var bv = screen.board
			print("HERO_PX ", bv.get_global_transform() * bv.feet(Vector2(h.pos)))
			step = 1; t0 = frame
		1:
			if frame - t0 > 20:
				b.cmd_wait(4); screen._after(); step = 2; t0 = frame
		2:
			if _ready_for_next():
				b.cmd_move(Vector2i(1, 0)); screen._after(); step = 3; t0 = frame
		3:
			if _ready_for_next():
				var aim: Vector2i = h.pos + Vector2i(1, 0)
				b.belt.slots[0] = {"card_id": "strike", "life": 3.0}
				for a in b.actors:
					if a.controller == "ai" and b.grid.units.has(a) and b.can_play(0, a.pos):
						aim = a.pos
				_play(b, "strike", aim); step = 4; t0 = frame
		4:
			if frame - t0 > 90: quit()
	return false
