extends TestCase

func run() -> void:
	var c := Catalog.load_dir("res://data")
	var strike := {"id": "strike", "time": 2, "weight": 1, "rarity": "basic", "target": {"shape": "cell", "range": 1, "size": 0}, "parts": [{"op": "damage", "amount": 6, "kind": "physical"}]}
	var r := Power.check(strike, c)
	assert_true(r["ok"], "strike within basic budget: " + str(r))
	assert_eq(r["budget"], Power.budget("basic", c), "budget reported")
	var big := strike.duplicate(true)
	big["target"] = {"shape": "circle", "range": 3, "size": 2}
	assert_true(Power.score(big, c) > Power.score(strike, c), "area raises score")
	assert_true(not Power.check(big, c)["ok"], "circle 2 strike over budget")
	var cheap := strike.duplicate(true); cheap["time"] = 0
	assert_true(Power.score(cheap, c) > Power.score(strike, c), "lower time cost -> higher net score")
	var swap := {"id": "s", "time": 6, "weight": 2, "rarity": "epic", "target": {"shape": "cell", "range": 3}, "parts": [{"op": "swap_bodies"}]}
	assert_true(Power.check(swap, c)["ok"], "body swap fits epic")
	assert_true(not Power.check(swap.merged({"rarity": "basic"}, true), c)["ok"], "body swap too strong for basic")
	var sustained := {"id": "z", "time": 3, "rarity": "common", "target": {"shape": "cell"}, "parts": [{"op": "var", "id": "time_scale", "mode": "set", "value": 0.3}]}
	var longer := sustained.duplicate(true); longer["parts"][0]["turns"] = 3
	assert_true(Power.score(longer, c) > Power.score(sustained, c), "turns raise score")
