extends SceneTree
var screen
var frame := 0
var step := 0
var t0 := 0
var n := 0
var out := "/tmp/claude-0/-home-user/4488597b-de51-588b-8146-d00f7e2991fb/scratchpad/cap/"

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
	match step:
		0:
			var h = b.human()
			var foe = b.actors[1]
			b.grid.move_unit(foe, h.pos + Vector2i(3, 0))
			for k in 6:
				if not b.telegraphs.is_empty(): break
				b.cmd_wait(1)
			screen.shown_frame = b.frames.size() - 1
			screen._refresh()
			step = 1; t0 = frame
		1:
			if frame - t0 > 15 and (frame - t0) % 2 == 0: _grab()
			if frame - t0 > 75:
				# play a 2+ second card
				var slot := 0
				for i in b.belt.slots.size():
					var s = b.belt.slots[i]
					if s != null and int(Effects.card_def(s["card_id"], b.catalog).get("time", 0)) >= 2:
						slot = i
				var aim = b.human().pos + Vector2i(1, 0)
				for p in b.grid.all_cells():
					if b.can_play(slot, p):
						aim = p
						break
				b.cmd_play(slot, aim)
				screen._after()
				step = 2; t0 = frame
		2:
			if (frame - t0) % 2 == 0: _grab()
			if frame - t0 > 150:
				quit()
	return false
