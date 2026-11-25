extends SceneTree
## Loads every res://tests/sim/*_test.gd (optionally filtered by name args) and runs it.

func _initialize() -> void:
	var filters: PackedStringArray = OS.get_cmdline_user_args()
	var dir := DirAccess.open("res://tests/sim")
	var names: Array = []
	for f in dir.get_files():
		if f.ends_with("_test.gd"):
			names.append(f)
	names.sort()
	var total := 0
	var failed := 0
	for f in names:
		if filters.size() > 0 and not filters.has(f.trim_suffix(".gd")):
			continue
		var script = load("res://tests/sim/" + f)
		if script == null or not script.can_instantiate():
			printerr("LOAD FAIL " + f)
			failed += 1
			continue
		Grid.W = 9   # unit tests assume the 9x7 board; Battle sets its own size from config
		Grid.H = 7
		var t = script.new()
		t.current = f
		t.run()
		print("%s checks=%d failures=%d" % [f, t.checks, t.failures])
		total += t.checks
		failed += t.failures
	print("ALL checks=%d failures=%d" % [total, failed])
	quit(1 if failed > 0 else 0)
