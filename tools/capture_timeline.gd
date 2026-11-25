extends SceneTree
## Boots the battle screen and saves timeline-battle screenshots to evidence/timeline/.

var screen
var frame := 0
var step := 0

func _initialize() -> void:
	screen = load("res://scenes/battle.tscn").instantiate()
	root.add_child(screen)

func _shot(name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://evidence/timeline"))
	root.get_viewport().get_texture().get_image().save_png("res://evidence/timeline/%s.png" % name)
	print("saved ", name)

func _process(_d: float) -> bool:
	frame += 1
	if frame % 15 != 0:
		return false
	var flow = screen.flow
	var b = flow.battle
	match step:
		0:
			for k in 6:
				b.cmd_wait(1)
			screen._refresh()
		1:
			_shot("01_slimes_telegraph")
		2:
			b.belt.slots[0] = {"card_id": "laser", "life": 3.0}
			screen.selected = 0
			screen._refresh()
			var foe = b.actors[1]
			screen.board.hover = foe.pos
			screen.board.preview = b.preview(0, foe.pos)
			screen.board.queue_redraw()
		3:
			_shot("02_card_selected_time_span")
		4:
			# jump to the boss to show the safe-zone attack
			flow.index = 2
			flow._start_battle()
			var boss = flow.battle.actors[1]
			boss.pattern_index = 3   # quake next
			flow.battle.cmd_wait(1)
			screen.selected = -1
			screen._refresh()
		5:
			_shot("03_boss_safe_zone")
		6:
			quit(0)
	step += 1
	return false
