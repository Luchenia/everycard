extends TestCase
## Mouse-wheel roll on the hand.

var c: Catalog

func run() -> void:
	c = Catalog.load_dir("res://data")
	c.cards["a"] = {"id": "a", "time": 1, "weight": 1}
	c.cards["hv"] = {"id": "hv", "time": 1, "weight": 2}
	test_roll_right_drops_last_draws_left()
	test_roll_left_drops_first()
	test_heavy_roll_costs_two()
	test_roll_empty_hand()

func _ids(b: HandBelt) -> Array:
	return b.slots.map(func(s): return "" if s == null else ("~" if s.get("tail", false) else s["card_id"]))

func test_roll_right_drops_last_draws_left() -> void:
	var deck := ["strike", "guard", "step", "frost", "spark", "rain", "gust"]
	var b := HandBelt.new(deck, SimRng.new(1), c, 5, false)
	assert_eq(_ids(b), ["strike", "guard", "step", "frost", "spark"], "initial hand")
	assert_eq(b.end_card(1), "spark", "right end")
	assert_eq(b.roll(1), "spark", "dropped right end")
	assert_eq(_ids(b), ["rain", "strike", "guard", "step", "frost"], "new card enters on the left")
	assert_true(b.discard.has("spark"), "dropped card discarded")

func test_roll_left_drops_first() -> void:
	var deck := ["strike", "guard", "step", "frost", "spark", "rain", "gust"]
	var b := HandBelt.new(deck, SimRng.new(1), c, 5, false)
	assert_eq(b.roll(-1), "strike", "dropped left end")
	assert_eq(_ids(b), ["guard", "step", "frost", "spark", "rain"], "new card enters on the right")

func test_heavy_roll_costs_two() -> void:
	c.actors["hh"] = {"id": "hh", "hp": 30, "mass": 1, "base_ability": "step1", "deck": ["a", "a", "a", "hv", "a", "a", "a"]}
	c.actors["idle"] = {"id": "idle", "hp": 30, "mass": 1, "deck": [], "pattern": []}
	c.config = {"round_time": 10}
	var bt := Battle.new(c, 1, "hh", ["idle"], {"player_pos": [1, 3], "enemy_pos": [[7, 3]], "materials": []})
	bt.belt = HandBelt.new(["a", "a", "a", "hv", "a", "a"], bt.rng, c, 5, false)
	assert_eq(_ids(bt.belt), ["a", "a", "a", "hv", "~"], "heavy at right end")
	assert_true(bt.cmd_wheel(1), "roll right")
	assert_eq(bt.now, 2, "dropping a heavy card costs 2 seconds")
	assert_true(bt.cmd_wheel(-1), "roll left")
	assert_eq(bt.now, 3, "normal card costs 1 second")

func test_roll_empty_hand() -> void:
	var b := HandBelt.new([], SimRng.new(1), c, 5, false)
	assert_eq(b.roll(1), "", "nothing to drop")
	assert_eq(b.slots.count(null), 5, "still empty, no crash")
