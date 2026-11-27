extends SceneTree
## Study capture: a hand card picked and carried across to the board.
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
	if frame < 40: return false
	var cv = screen.cards[1]
	var start: Vector2 = cv.global_position + cv.size * cv.scale / 2
	var goal := Vector2(520, 300)
	if frame == 40:
		root.warp_mouse(start)
		screen._on_card_picked(cv)
	if frame > 40 and frame < 80:
		var k := float(frame - 40) / 40.0
		root.warp_mouse(start.lerp(goal, k * k * (3.0 - 2.0 * k)))
	if frame % 4 == 0:
		root.get_viewport().get_texture().get_image().save_png(out + "f%04d.png" % n)
		n += 1
	if frame > 100: quit()
	return false
