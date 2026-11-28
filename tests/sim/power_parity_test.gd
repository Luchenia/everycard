extends TestCase
## The server's TypeScript calculator (server/forge/power.ts) must score cards exactly like Power.
## server/forge/power_test.ts writes its scores to server/forge/power_cases.json; this checks them.

func run() -> void:
	var c := Catalog.load_dir("res://data")
	var f := FileAccess.open("res://server/forge/power_cases.json", FileAccess.READ)
	assert_true(f != null, "power_cases.json exists (run server/forge/power_test.ts)")
	if f == null:
		return
	var cases: Dictionary = JSON.parse_string(f.get_as_text())
	var battle: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/battle.json"))
	var w0 := Grid.W
	var h0 := Grid.H
	Grid.W = int(battle.get("grid_w", 9))   # the server scores on the real board size
	Grid.H = int(battle.get("grid_h", 7))
	for id in cases:
		var card := Effects.card_def(id, c)
		assert_true(absf(Power.score(card, c) - float(cases[id])) < 0.01, "%s: gd %.3f vs ts %.3f" % [id, Power.score(card, c), float(cases[id])])
	Grid.W = w0
	Grid.H = h0
