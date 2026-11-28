extends TestCase
## Relaxed (ring) hand: cards stay until used, a used card goes to the back of the ring and the
## window slides; heavy cards take two slots.

var c: Catalog

func cards_in(b: HandBelt) -> int:
	return b.slots.filter(func(s): return s != null and not s.get("tail", false)).size()

func run() -> void:
	c = Catalog.load_dir("res://data")
	c.cards["light"] = {"id": "light", "weight": 1}
	c.cards["heavy"] = {"id": "heavy", "weight": 2}
	var deck := []
	for i in 12:
		deck.append("light")
	var b := HandBelt.new(deck, SimRng.new(1), c, 5, true, "relaxed")
	assert_eq(cards_in(b), 5, "starts full")
	b.end_turn(1.0)
	assert_eq(cards_in(b), 5, "unused cards stay")
	b.take(0)
	assert_eq(cards_in(b), 4, "used card leaves the window")
	assert_eq(b.ring().size(), 12, "but stays in the ring")
	b.refill_one()
	assert_eq(cards_in(b), 5, "window refills")
	# heavy takes two slots
	var h := HandBelt.new(["heavy", "light", "light", "light", "light", "light"], SimRng.new(1), c, 5, false, "relaxed")
	assert_eq(h.slots[0]["card_id"], "heavy", "heavy first")
	assert_true(h.slots[1]["tail"], "heavy occupies next slot")
	assert_eq(cards_in(h), 4, "heavy + 3 light fill 5 slots")
	assert_eq(h.take(1), "heavy", "taking the tail takes the heavy card")
	assert_eq(h.slots[0]["card_id"], "light", "window slid left")
	assert_eq(h.slots.count(null), 2, "two slots freed at the right")
	var none := HandBelt.new([], SimRng.new(1), c, 5, true, "relaxed")
	none.end_turn(1.0)
	assert_true(none.slots.all(func(s): return s == null), "empty deck ok")
