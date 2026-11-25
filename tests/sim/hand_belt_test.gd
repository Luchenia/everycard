extends TestCase
## Lifespan hand: every card in hand has its own remaining life; at turn end lives drop by
## the turn speed and burnt-out cards leave. No row flow: cards stay in their slots.

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
	assert_eq(b.slots[0]["life"], float(HandBelt.BASE_LIFE), "light card starts with base life")
	assert_eq(b.preview(), "light", "preview next")
	assert_eq(b.take(2), "light", "take returns card")
	assert_true(b.slots[2] == null, "taken slot empty")
	b.end_turn(1.0)
	assert_true(b.slots[2] != null, "gap refilled in place")
	assert_eq(b.slots[0]["life"], float(HandBelt.BASE_LIFE - 1), "life drops by 1 at speed 1")
	assert_eq(b.slots[2]["life"], float(HandBelt.BASE_LIFE), "new card has full life")
	# lives run out -> burn
	for k in HandBelt.BASE_LIFE - 1:
		b.end_turn(1.0)
	assert_eq(b.discard.size(), 5, "four original cards + taken card burned/discarded")
	# heavy cards live longer
	var hb := HandBelt.new(["heavy", "light", "light", "light", "light", "light"], SimRng.new(1), c, 5, false)
	assert_eq(hb.slots[0]["life"], float(HandBelt.BASE_LIFE + HandBelt.HEAVY_BONUS), "heavy card lives longer")
	for k in HandBelt.BASE_LIFE:
		hb.end_turn(1.0)
	assert_eq(ids(hb)[0], "heavy", "heavy outlives light cards")
	# speed scales decay
	var s1 := HandBelt.new(deck.duplicate(), SimRng.new(1), c)
	s1.end_turn(0.5)
	assert_eq(s1.slots[0]["life"], float(HandBelt.BASE_LIFE) - 0.5, "slow time: life drops slower")
	s1.end_turn(2.0)
	assert_eq(s1.slots[0]["life"], float(HandBelt.BASE_LIFE) - 2.5, "fast time: life drops faster")
	# hold all: no decay this turn
	var h2 := HandBelt.new(deck.duplicate(), SimRng.new(1), c)
	h2.hold()
	h2.end_turn(1.0)
	assert_eq(h2.slots[0]["life"], float(HandBelt.BASE_LIFE), "hold: no decay")
	# hold one card: extends its life
	h2.hold(3)
	assert_eq(h2.slots[3]["life"], float(HandBelt.BASE_LIFE + HandBelt.HOLD_BONUS), "hold slot: life extended")
	# flush burns the card closest to burning out and refills
	var f := HandBelt.new(deck.duplicate(), SimRng.new(1), c)
	f.slots[4]["life"] = 0.5
	f.flush()
	assert_eq(f.discard.size(), 1, "flush discards one")
	assert_eq(f.slots[4]["life"], float(HandBelt.BASE_LIFE), "flushed the lowest-life card, refilled in place")
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
