extends TestCase

var c: Catalog

func ids(b: HandBelt) -> Array:
	return b.slots.map(func(s): return null if s == null else s["card_id"])

func run() -> void:
	c = Catalog.load_dir("res://data")
	c.cards["light"] = {"id": "light", "weight": 1}
	c.cards["heavy"] = {"id": "heavy", "weight": 2}
	var deck := []
	for i in 10:
		deck.append("light")
	var b := HandBelt.new(deck, SimRng.new(1), c)
	assert_eq(b.slots.size(), 5, "5 slots")
	assert_true(b.slots.all(func(s): return s != null), "initially full")
	assert_eq(b.preview(), "light", "preview next")
	assert_eq(b.take(2), "light", "take returns card")
	assert_true(b.slots[2] == null, "taken slot empty")
	b.end_turn(1.0)
	assert_true(b.slots.all(func(s): return s != null), "gap refilled after end_turn")
	# heavy card at the left stays one extra turn
	var hb := HandBelt.new(["heavy", "light", "light", "light", "light", "light", "light", "light"], SimRng.new(1), c, 5, false)
	assert_eq(ids(hb)[0], "heavy", "heavy first (unshuffled)")
	hb.end_turn(1.0)
	assert_eq(ids(hb)[0], "heavy", "heavy survives first flow")
	hb.end_turn(1.0)
	assert_true(ids(hb)[0] != "heavy" or hb.discard.has("heavy"), "heavy gone after second flow")
	assert_true(hb.discard.has("heavy"), "heavy discarded")
	# hold: no flow
	var h2 := HandBelt.new(["light", "heavy", "light", "light", "light", "light", "light"], SimRng.new(1), c, 5, false)
	var before := ids(h2)
	h2.hold()
	h2.end_turn(1.0)
	assert_eq(ids(h2), before, "hold: nothing flows")
	assert_eq(h2.discard.size(), 0, "hold: nothing discarded")
	# speed rounding
	var s1 := HandBelt.new(deck.duplicate(), SimRng.new(1), c)
	s1.end_turn(0.4)
	assert_eq(s1.discard.size(), 0, "speed 0.4 -> no flow")
	s1.end_turn(1.6)
	assert_eq(s1.discard.size(), 2, "speed 1.6 -> 2 flows")
	# flush discards leftmost immediately
	var f := HandBelt.new(deck.duplicate(), SimRng.new(1), c)
	f.flush()
	assert_eq(f.discard.size(), 1, "flush discards one")
	assert_true(f.slots.all(func(s): return s != null), "flush refills")
	# small deck reuses discard pile
	var small := HandBelt.new(["light", "light", "light"], SimRng.new(1), c)
	assert_eq(ids(small).filter(func(x): return x != null).size(), 3, "only 3 cards")
	small.take(0); small.take(1)
	small.end_turn(1.0)
	assert_true(ids(small).filter(func(x): return x != null).size() >= 2, "discard reshuffled into draw")
	# all empty: stays null without errors
	var none := HandBelt.new([], SimRng.new(1), c)
	none.end_turn(1.0)
	assert_true(none.slots.all(func(s): return s == null), "empty deck: all null")
	assert_eq(none.preview(), "", "no preview")
