extends SceneTree
## Boots the battle screen and saves screenshots of its main states to evidence/screen/.
## xvfb-run -a -s "-screen 0 1280x800x24" tools/run.sh --rendering-driver opengl3 --script res://tools/capture_screen.gd -- --seed=5

var screen
var frame := 0
var step := 0

func _initialize() -> void:
	screen = load("res://scenes/battle.tscn").instantiate()
	root.add_child(screen)

func _shot(name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://evidence/screen"))
	root.get_viewport().get_texture().get_image().save_png("res://evidence/screen/%s.png" % name)
	print("saved ", name)

func _put(b, x, y, m) -> void:
	b.grid.set_material(Vector2i(x, y), m)

func _slot_of(b, id: String) -> int:
	for i in b.belt.slots.size():
		if b.belt.slots[i] != null and b.belt.slots[i]["card_id"] == id:
			return i
	b.belt.slots[0] = {"card_id": id, "life": 3.0}
	return 0

func _process(_d: float) -> bool:
	frame += 1
	if frame == 2:
		screen.debug_enter("fight")
	if frame % 20 != 0:
		return false
	var flow = screen.flow
	var b = flow.battle
	match step:
		0:
			# stage a lively room: puddle, oil, swamp, ice, fire, crystal, a mirror and a wall
			for p in [[3, 6], [4, 6], [3, 7], [4, 7], [5, 7], [2, 7]]:
				_put(b, p[0], p[1], "water")
			for p in [[9, 1], [10, 1], [10, 2]]:
				_put(b, p[0], p[1], "oil")
			for p in [[6, 2], [7, 2]]:
				_put(b, p[0], p[1], "fire")
			for p in [[12, 7], [13, 7], [12, 8], [13, 8]]:
				_put(b, p[0], p[1], "swamp")
			for p in [[1, 1], [2, 1], [1, 2]]:
				_put(b, p[0], p[1], "ice")
			_put(b, 8, 5, "crystal")
			_put(b, 11, 4, "metal")
			_put(b, 5, 3, "wall")
			b.grid.add_state(Vector2i(9, 6), "haste")
			b.grid.add_state(Vector2i(10, 6), "slow")
			# one cell of each kind of state, so the shot shows how they read
			var demo := [["heat", 3, 6], ["cold", 4, 6], ["damp", 5, 6], ["charged", 6, 6], ["miasma", 7, 6], ["curse", 3, 7], ["mana", 4, 7], ["echo", 5, 7], ["slick", 6, 7]]
			for d in demo:
				b.grid.add_state(Vector2i(d[1], d[2]), d[0], 30.0)
			b.grid.add_state(Vector2i(7, 7), "heat", 30.0)
			b.grid.add_state(Vector2i(7, 7), "heat", 30.0, Vector2i.ZERO, true)
			for k in 8:
				if not b.telegraphs.is_empty():
					break
				b.cmd_wait(1)
			screen.shown_frame = b.frames.size() - 1
			screen._refresh()
		1:
			_shot("01_room_idle")
		2:
			var cv = null
			for c2 in screen.cards:
				if c2 != null and "[" in c2.def().get("desc", ""):
					cv = c2
			screen._on_card_hover(cv, true)
		3:
			_shot("02_card_hover_keywords")
		4:
			screen._clear_tips()
			screen.hovered_card = null
			var s: int = _slot_of(b, "laser")
			screen.selected = s
			screen._refresh()
			var foe = b.actors[1]
			screen.board.hover = foe.pos
			screen.board.preview = b.preview(s, foe.pos)
		5:
			_shot("03_aim_in_range")
		6:
			var s2: int = _slot_of(b, "spark")
			screen.selected = s2
			screen._refresh()
			screen.board.hover = Vector2i(14, 8)
		7:
			_shot("04_aim_out_of_range")
		8:
			screen.selected = -1
			var s3: int = _slot_of(b, "bullet_time")
			b.cmd_play(s3, b.human().pos)
			screen.shown_frame = b.frames.size() - 1
			screen._refresh()
		9:
			_shot("05_borrowed_time")
		10:
			b.cmd_wait(1)
			screen.shown_frame = b.frames.size() - 1
			b.cmd_wait(2)
			screen._refresh()
		11:
			pass
		12:
			_shot("06_replay")
		13:
			flow.phase = "reward"
			flow.rewards = ["crystallize", "hurry", "body_swap"]
			screen._refresh()
		14:
			_shot("07_reward")
		15:
			flow.index = 2
			flow._start_battle()
			b = flow.battle
			for k in 16:
				if not b.telegraphs.is_empty():
					break
				b.cmd_wait(1)
			screen.shown_frame = b.frames.size() - 1
			screen._refresh()
		16:
			_shot("08_boss_warning")
		17:
			flow.index = 1
			flow._start_battle()
			b = flow.battle
			for k in 10:
				if not b.telegraphs.is_empty():
					break
				b.cmd_wait(1)
			screen.shown_frame = b.frames.size() - 1
			screen._refresh()
		18:
			_shot("09_imp_golem_warning")
		19:
			quit(0)
	step += 1
	return false
