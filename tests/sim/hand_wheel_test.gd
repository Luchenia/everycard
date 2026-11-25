extends TestCase
## Hand as a ring over the whole deck, turned by the mouse wheel.

var c: Catalog

func run() -> void:
	c = Catalog.load_dir("res://data")
	c.cards["a"] = {"id": "a", "time": 1, "weight": 1}
	c.cards["hv"] = {"id": "hv", "time": 1, "weight": 2}
	test_roll_left_sends_first_to_back()
	test_roll_right_brings_last_to_left()
	test_full_turn_returns_to_start()
	test_used_card_goes_to_back()
	test_heavy_roll_costs_two()
	test_roll_empty_hand()

func _ids(b: HandBelt) -> Array:
	return b.slots.map(func(s): return "" if s == null else ("~" if s.get("tail", false) else s["card_id"]))

const DECK := ["strike", "guard", "step", "frost", "spark", "rain", "gust"]

func test_roll_left_sends_first_to_back() -> void:
	var b := HandBelt.new(DECK, SimRng.new(1), c, 5, false)
	assert_eq(_ids(b), ["strike", "guard", "step", "frost", "spark"], "window on the ring")
	assert_eq(b.roll(-1), "strike", "left card leaves")
	assert_eq(_ids(b), ["guard", "step", "frost", "spark", "rain"], "next card enters on the right")
	assert_eq(b.ring(), ["guard", "step", "frost", "spark", "rain", "gust", "strike"], "strike went to the back of the ring")
	assert_eq(b.discard.size(), 0, "no discard pile")

func test_roll_right_brings_last_to_left() -> void:
	var b := HandBelt.new(DECK, SimRng.new(1), c, 5, false)
	assert_eq(b.roll(1), "spark", "right card leaves")
	assert_eq(_ids(b), ["gust", "strike", "guard", "step", "frost"], "the ring's last card enters on the left")

func test_full_turn_returns_to_start() -> void:
	var b := HandBelt.new(DECK, SimRng.new(1), c, 5, false)
	for i in DECK.size():
		b.roll(-1)
	assert_eq(_ids(b), ["strike", "guard", "step", "frost", "spark"], "a full turn of the ring comes back to the start")

func test_used_card_goes_to_back() -> void:
	var b := HandBelt.new(DECK, SimRng.new(1), c, 5, false)
	assert_eq(b.take(1), "guard", "use guard")
	b.refill_one()
	assert_eq(_ids(b), ["strike", "step", "frost", "spark", "rain"], "window slides and the next card enters on the right")
	assert_eq(b.ring()[-1], "guard", "used card is at the back of the ring")

func test_heavy_roll_costs_two() -> void:
	c.actors["hh"] = {"id": "hh", "hp": 30, "mass": 1, "base_ability": "step1", "deck": ["a", "a", "a", "hv", "a", "a", "a"]}
	c.actors["idle"] = {"id": "idle", "hp": 30, "mass": 1, "deck": [], "pattern": []}
	c.config = {"round_time": 10}
	var bt := Battle.new(c, 1, "hh", ["idle"], {"player_pos": [1, 3], "enemy_pos": [[7, 3]], "materials": []})
	bt.belt = HandBelt.new(["a", "a", "a", "hv", "a", "a"], bt.rng, c, 5, false)
	assert_eq(_ids(bt.belt), ["a", "a", "a", "hv", "~"], "heavy at right end")
	assert_true(bt.cmd_wheel(1), "roll right")
	assert_eq(bt.now, 2, "turning a heavy card out costs 2 seconds")
	assert_true(bt.cmd_wheel(-1), "roll left")
	assert_eq(bt.now, 3, "normal card costs 1 second")

func test_roll_empty_hand() -> void:
	var b := HandBelt.new([], SimRng.new(1), c, 5, false)
	assert_eq(b.roll(1), "", "nothing to drop")
	assert_eq(b.slots.count(null), 5, "still empty, no crash")
