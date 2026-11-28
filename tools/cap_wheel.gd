extends SceneTree
## Study capture: turning the card ring three times (time slips by in grey).
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
	if frame in [45, 52, 59]:
		screen._roll(1)
	if frame % 2 == 0:
		root.get_viewport().get_texture().get_image().save_png(out + "f%04d.png" % n)
		n += 1
	if frame > 150: quit()
	return false
