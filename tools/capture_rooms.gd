extends SceneTree
## Screenshots of the room run: start room with the map, a sealed fight, a chest, the shop, a slide.
## xvfb-run -a -s "-screen 0 1280x800x24" tools/run.sh --rendering-driver opengl3 --script res://tools/capture_rooms.gd -- --seed=5

var screen
var frame := 0
var step := 0
var t0 := 0

func _initialize() -> void:
	screen = load("res://scenes/battle.tscn").instantiate()
	root.add_child(screen)

func _shot(name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://evidence/screen"))
	root.get_viewport().get_texture().get_image().save_png("res://evidence/screen/%s.png" % name)
	print("saved ", name)

func _wait(n: int) -> bool:
	return frame - t0 > n

func _next() -> void:
	step += 1
	t0 = frame

func _process(_d: float) -> bool:
	frame += 1
	var flow = screen.flow
	match step:
		0:
			if _wait(20):
				_shot("20_start_room"); _next()
		1:
			screen.debug_enter("fight"); _next()
		2:
			if _wait(20):
				_shot("21_fight_sealed"); _next()
		3:
			for a in flow.battle.actors:
				if a.team == 1:
					a.hp = 0
			flow.battle.cmd_wait(1)
			screen.shown_frame = flow.battle.frames.size() - 1
			flow.update()
			screen._refresh(); _next()
		4:
			if _wait(15):
				_shot("22_room_reward"); screen._pick_reward(-1); _next()
		5:
			if _wait(10):
				_shot("23_doors_open"); _next()
		6:
			screen.debug_enter("chest"); _next()
		7:
			if _wait(15):
				_shot("24_chest_room"); _next()
		8:
			flow.gold = 120
			screen.debug_enter("shop")
			var me = flow.battle.human()
			flow.battle.grid.move_unit(me, Vector2i(Grid.W / 2, Grid.H / 2))
			flow.update()
			screen._refresh(); _next()
		9:
			if _wait(15):
				_shot("25_shop"); flow.leave_shop(); screen._refresh(); _next()
		10:
			screen.debug_enter("spring"); _next()
		11:
			if _wait(15):
				_shot("26_spring"); _next()
		12:
			# walk onto the way back and catch the slide halfway
			flow.exit_dir = -flow.came_from; _next()
		13:
			if screen.slide_t > 1.3:
				_shot("27_slide"); _next()
			elif _wait(120):
				_next()
		14:
			if _wait(40):
				_shot("28_next_room"); return true
	return false
