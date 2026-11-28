extends SceneTree
## Screenshot of monster quirks: a slime split in two, an imp hurt by water.
## xvfb-run -a -s "-screen 0 1280x800x24" tools/run.sh --rendering-driver opengl3 --script res://tools/capture_split.gd

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
		b.grid.move_unit(me, Vector2i(4, 4))
		var spots := [Vector2i(me.pos.x + 3, me.pos.y), Vector2i(me.pos.x + 3, me.pos.y + 2)]
		var i := 0
		for a in b.actors:
			if a.team == 1 and i < spots.size():
				b.grid.move_unit(a, spots[i])
				i += 1
		b.grid.set_material(spots[1], "water")
		var slime = Actor.from_def(b.catalog.actors["slime"], 900)
		slime.team = 1
		b.grid.place_unit(slime, Vector2i(me.pos.x + 5, me.pos.y - 2))
		b.actors.append(slime)
		slime.hp = 9
		b._after_action()
		b.cmd_wait(1)
		screen.shown_frame = b.frames.size() - 1
		screen.flow.update()
		screen._refresh()
	if frame == 60:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://evidence/screen"))
		root.get_viewport().get_texture().get_image().save_png("res://evidence/screen/30_split.png")
		print("saved")
		return true
	return false
