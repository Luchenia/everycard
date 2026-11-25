extends SceneTree
## Boots the battle screen, plays a scripted oil+fire chain and a laser, saves screenshots to evidence/stage1/.

var screen
var frame := 0
var step := 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	screen = load("res://scenes/battle.tscn").instantiate()
	root.add_child(screen)

func _shot(name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://evidence/stage1"))
	root.get_viewport().get_texture().get_image().save_png("res://evidence/stage1/%s.png" % name)
	print("saved ", name)

func _process(_d: float) -> bool:
	frame += 1
	if frame % 15 != 0:
		return false
	var flow = screen.flow
	var b = flow.battle
	match step:
		0:
			_shot("01_start")
		1:
			# put oil in front of the slime and light it
			var foe = b.actors[1]
			var h = b.human()
			b.belt.slots[0] = {"card_id": "oil_spill", "age": 0}
			b.belt.slots[1] = {"card_id": "spark", "age": 0}
			b.belt.slots[2] = {"card_id": "laser", "age": 0}
			b.belt.slots[3] = {"card_id": "gravity_well", "age": 0}
			b.belt.slots[4] = {"card_id": "body_swap", "age": 0}
			b.grid.move_unit(h, Vector2i(4, 3))
			print("oil ", b.cmd_play(0, foe.pos + Vector2i(-1, 0)))
			screen._refresh()
			screen.selected = 1
			screen._refresh()
			screen.board.hover = foe.pos + Vector2i(-1, 0)
			screen.board.preview = b.preview(1, foe.pos + Vector2i(-1, 0))
			screen.board.queue_redraw()
		2:
			_shot("02_oil_and_preview")
		3:
			var foe2 = b.actors[1]
			print("spark ", b.cmd_play(1, foe2.pos + Vector2i(-2, 0)))
			screen.selected = -1
			b.cmd_end_turn()
			flow.update()
			screen._refresh()
		4:
			_shot("03_after_chain")
		5:
			quit(0)
	step += 1
	return false
