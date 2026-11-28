extends SceneTree
## Screenshot of the temporary damage log beside the board.
## xvfb-run -a -s "-screen 0 1280x800x24" tools/run.sh --rendering-driver opengl3 --script res://tools/capture_log.gd

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
		for a in b.actors:
			if a.team == 1:
				b.grid.move_unit(a, me.pos + Vector2i(2, 0)) if b.grid.unit_at(me.pos + Vector2i(2, 0)) == null else null
				break
		b.grid.set_material(me.pos + Vector2i(0, 1), "fire")
		b.grid.move_unit(me, me.pos + Vector2i(0, 1))
		for k in 8:
			b.cmd_wait(1)
		screen.shown_frame = b.frames.size() - 1
		screen.flow.update()
		screen._refresh()
	if frame == 400:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://evidence/screen"))
		root.get_viewport().get_texture().get_image().save_png("res://evidence/screen/35_log.png")
		print("saved")
		return true
	return false
