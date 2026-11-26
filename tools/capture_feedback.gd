extends SceneTree
## Screenshots for the play-feedback pass: warnings with arrows, a card being performed, the hand flip.
## xvfb-run -a -s "-screen 0 1280x800x24" tools/run.sh --rendering-driver opengl3 --script res://tools/capture_feedback.gd -- --seed=5

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

func _process(_d: float) -> bool:
	frame += 1
	var b = screen.flow.battle
	match step:
		0:
			if frame < 20: return false
			var h = b.human()
			# bring a slime close so it leaps
			var foe = b.actors[1]
			b.grid.move_unit(foe, h.pos + Vector2i(3, 0))
			for k in 6:
				if not b.telegraphs.is_empty():
					break
				b.cmd_wait(1)
			screen.shown_frame = b.frames.size() - 1
			screen._refresh()
			step = 1; t0 = frame
		1:
			if frame - t0 > 20:
				_shot("10_warning_arrows"); step = 2
		2:
			var slot := -1
			for i in b.belt.slots.size():
				var s = b.belt.slots[i]
				if s != null and int(Effects.card_def(s["card_id"], b.catalog).get("time", 0)) >= 2 and Effects.card_def(s["card_id"], b.catalog).get("target", {}).get("shape", "") != "self":
					slot = i
			if slot < 0:
				b.belt.slots[0] = {"card_id": "oil_spill", "life": 3.0}
				slot = 0
			var aim = b.human().pos + Vector2i(1, 0)
			for p in b.grid.all_cells():
				if b.can_play(slot, p):
					aim = p
					break
			b.cmd_play(slot, aim)
			screen._after()
			step = 3; t0 = frame
		3:
			if frame - t0 == 25:
				_shot("11_card_performing"); step = 4
		4:
			if not screen._replaying():
				screen._roll(1)
				step = 5; t0 = frame
		5:
			if frame - t0 == 5:
				_shot("12_hand_flip")
			if frame - t0 == 40:
				screen.hand_cursor.pick(screen.cards[2])
			if frame - t0 == 52:
				_shot("15_hand_pick"); step = 6
		6:
			if not screen._replaying() and frame - t0 > 40:
				var h = b.human()
				screen.dragging = true
				screen.drag_from = h.pos
				screen.drag_manual = false
				screen.drag_from = h.pos + Vector2i(2, 2)
				screen.drag_px = Vector2(500, 400)
				screen.board.walk_path = screen._path(h.pos, h.pos + Vector2i(2, 2))
				screen.board.walk_mode = "hold"
				step = 7; t0 = frame
		7:
			if frame - t0 == 5:
				_shot("14_drag_path")
				var h2 = b.human()
				screen._end_drag(h2.pos + Vector2i(2, 2), Vector2(560, 400))
				step = 8; t0 = frame
		8:
			if frame - t0 == 15:
				_shot("13_walking"); return true
	return false
