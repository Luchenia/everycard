extends TestCase
## Relaxed hand: cards stay until used; at turn end empty slots receive round(2 x speed) draws;
## heavy cards take two slots.

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
	assert_eq(b.discard.size(), 0, "nothing burns")
	b.take(0); b.take(1); b.take(2)
	b.end_turn(1.0)
	assert_eq(cards_in(b), 4, "normal speed draws 2")
	b.take(0); b.take(1); b.take(3)
	b.end_turn(0.3)
	assert_eq(cards_in(b), 1, "slow time (0.3) draws 0")
	b.end_turn(2.0)
	assert_eq(cards_in(b), 5, "fast time draws up to 4")
	# heavy takes two slots
	var h := HandBelt.new(["heavy", "light", "light", "light", "light", "light"], SimRng.new(1), c, 5, false, "relaxed")
	assert_eq(h.slots[0]["card_id"], "heavy", "heavy first")
	assert_true(h.slots[1]["tail"], "heavy occupies next slot")
	assert_eq(cards_in(h), 4, "heavy + 3 light fill 5 slots")
	assert_eq(h.take(1), "heavy", "taking the tail takes the heavy card")
	assert_true(h.slots[0] == null and h.slots[1] == null, "both slots freed")
	# hold: one extra draw next turn
	var k := HandBelt.new(deck.duplicate(), SimRng.new(1), c, 5, true, "relaxed")
	k.take(0); k.take(1); k.take(2)
	k.hold()
	k.end_turn(1.0)
	assert_eq(cards_in(k), 5, "hold: draws 3 instead of 2")
	# flush: discard one and draw one now
	var f := HandBelt.new(deck.duplicate(), SimRng.new(1), c, 5, true, "relaxed")
	f.flush(2)
	assert_eq(f.discard.size(), 1, "flush discards chosen card")
	assert_eq(cards_in(f), 5, "and draws a replacement")
	var none := HandBelt.new([], SimRng.new(1), c, 5, true, "relaxed")
	none.end_turn(1.0)
	assert_true(none.slots.all(func(s): return s == null), "empty deck ok")
