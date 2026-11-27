extends SceneTree
## Study capture: walk at a foe, then strike it, recording every other frame.
var screen
var frame := 0
var step := 0
var t0 := 0
var n := 0
var out := ""

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--old": BoardView.BT2 = false
		if a.begins_with("--out="): out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out)
	screen = load("res://scenes/battle.tscn").instantiate()
	root.add_child(screen)

func _grab() -> void:
	root.get_viewport().get_texture().get_image().save_png(out + "f%04d.png" % n)
	n += 1

func _process(_d: float) -> bool:
	frame += 1
	if frame == 2:
		screen.debug_enter("fight")
	if frame < 30: return false
	var b = screen.flow.battle
	if step > 0 and frame % 2 == 0: _grab()
	match step:
		0:
			var h = b.human()
			var foe = b.actors[1]
			b.grid.move_unit(foe, h.pos + Vector2i(3, 0))
			screen.shown_frame = b.frames.size() - 1
			screen._refresh()
			step = 1; t0 = frame
		1:
			if frame - t0 > 30:
				b.cmd_move(Vector2i(1, 0)); screen._after(); step = 2; t0 = frame
		2:
			if not screen._replaying() and frame - t0 > 50:
				b.cmd_move(Vector2i(1, 0)); screen._after(); step = 3; t0 = frame
		3:
			if not screen._replaying() and frame - t0 > 50:
				var foe = b.actors[1]
				var done := false
				for i in b.belt.slots.size():
					if b.belt.slots[i] != null and b.can_play(i, foe.pos):
						b.cmd_play(i, foe.pos); done = true; break
				if not done:
					b.cmd_wait(1)
				screen._after(); step = 4; t0 = frame
		4:
			if frame - t0 > 110: quit()
	return false
