extends TestCase

const BASIC := ["strike", "guard", "step", "heat_wave", "frost", "oil_spill", "spark", "rain", "shock", "gravity_well",
	"gust", "compress", "laser", "mirror", "slow_field", "haste_field", "stasis", "body_swap", "pickpocket", "bind_soul"]

func run() -> void:
	var c := Catalog.load_dir("res://data")
	for id in BASIC:
		assert_true(c.cards.has(id), "card exists: " + id)
	for id in c.cards:
		var r := Power.check(c.cards[id], c)
		assert_true(r["ok"], "within budget: %s %s" % [id, str(r)])
		assert_true(c.cards[id].has("name") and c.cards[id].has("time"), "has name/time: " + id)
	for aid in c.actors:
		for cid in c.actors[aid].get("deck", []) + c.actors[aid].get("pattern", []):
			assert_true(c.cards.has(cid), "%s deck card exists: %s" % [aid, cid])
		if c.actors[aid].has("signature"):
			assert_true(c.cards.has(c.actors[aid]["signature"]), "signature exists: " + aid)
			assert_true(not Effects.card_def("foe:" + aid, c).is_empty(), "foe card resolves: " + aid)
	# every card usable in an empty battle without errors, random aims
	var all_ids: Array = c.cards.keys()
	for seed_value in range(1, 21):
		var rng := SimRng.new(seed_value)
		var b := Battle.new(c, seed_value, "walker", ["slime", "iron_golem"], {})
		var h := b.human()
		var id: String = all_ids[rng.next_int(all_ids.size())]
		var aim := Vector2i(rng.next_int(Grid.W), rng.next_int(Grid.H))
		Effects.apply(Effects.card_def(id, c), h, aim, b.ctx)
		b.cmd_wait(10)
		assert_true(b.phase in ["player", "won", "lost"], "battle continues after %s" % id)
