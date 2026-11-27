extends SceneTree
## Screenshot of monster moves: a golem's charge lane, a slime's hop, an imp coming in off your line.
## xvfb-run -a -s "-screen 0 1280x800x24" tools/run.sh --rendering-driver opengl3 --script res://tools/capture_moves.gd

var screen
var frame := 0

func _initialize() -> void:
	screen = load("res://scenes/battle.tscn").instantiate()
	root.add_child(screen)

func _process(_d: float) -> bool:
	frame += 1
	if frame == 2:
		screen.debug_enter("fight")
	if frame == 6:
		var b = screen.flow.battle
		var me = b.human()
		for a in b.actors.duplicate():
			if a.team == 1:
				b.grid.remove_unit(a)
				b.actors.erase(a)
		b.grid.move_unit(me, Vector2i(3, 4))
		var spots := {"iron_golem": Vector2i(9, 4), "slime": Vector2i(9, 1), "ember_imp": Vector2i(11, 7)}
		var uid := 900
		for id in spots:
			var a := Actor.from_def(b.catalog.actors[id], uid)
			uid += 1
			a.team = 1
			a.next_at = b.now + 1
			b.grid.set_material(spots[id], "none")
			b.grid.place_unit(a, spots[id])
			b.actors.append(a)
		b.cmd_wait(1)
		screen.shown_frame = b.frames.size() - 1
		screen.flow.update()
		screen._refresh()
	if frame == 90:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://evidence/screen"))
		root.get_viewport().get_texture().get_image().save_png("res://evidence/screen/36_moves.png")
		print("saved")
		return true
	return false
