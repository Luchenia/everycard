extends SceneTree
## Compiles every view script and reports errors (the test runner only compiles the simulation).
func _initialize() -> void:
	for f in ["art", "card_view", "timeline_bar", "board_view", "battle_screen", "run_flow"]:
		var s = load("res://src/view/%s.gd" % f)
		print(f, ": ", "ok" if s != null and s.can_instantiate() else "FAILED")
	quit(0)
