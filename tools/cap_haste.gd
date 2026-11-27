extends SceneTree
## Capture: a 3x3 and a single [가속] cell drawn as fields.
var screen
var frame := 0
var n := 0
var out := ""

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="): out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out)
	screen = load("res://scenes/battle.tscn").instantiate()
	root.add_child(screen)

func _process(_d: float) -> bool:
	frame += 1
	if frame == 2:
		screen.debug_enter("fight")
	if frame == 30:
		var b = screen.flow.battle
		var h = b.human()
		for dx in 3:
			for dy in 3:
				b.grid.add_state(h.pos + Vector2i(1 + dx, -1 + dy), "haste")
		b.grid.add_state(h.pos + Vector2i(0, 3), "haste")
		screen._refresh()
	if frame > 34 and frame % 6 == 0:
		root.get_viewport().get_texture().get_image().save_png(out + "h%02d.png" % n)
		n += 1
	return n >= 3
