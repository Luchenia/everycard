extends SceneTree
## Screenshot of 불릿타임: the world three times slower, warnings counting down in tenths and
## card costs shown as a third.
## xvfb-run -a -s "-screen 0 1280x800x24" tools/run.sh --rendering-driver opengl3 --script res://tools/capture_slow.gd

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
		for k in 6:
			if not b.telegraphs.is_empty():
				break
			b.cmd_wait(1)
		b._on_meta({"op": "slow", "factor": 3, "secs": 4}, me)
		b.cmd_wait(1)
		print("tick=", b.tick, " slowed=", b.slowed(), " rate=", b.world_rate(), " tg=", b.telegraphs.map(func(t): return Battle.fmt_secs(b.secs_until(int(t["fire_at"])))))
		screen.shown_frame = b.frames.size() - 1
		screen.flow.update()
		screen._refresh()
	if frame == 300:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://evidence/screen"))
		root.get_viewport().get_texture().get_image().save_png("res://evidence/screen/40_slow.png")
		print("saved")
		return true
	return false
