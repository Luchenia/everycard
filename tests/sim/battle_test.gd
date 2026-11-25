extends TestCase

var c: Catalog

func setup_catalog() -> void:
	c = Catalog.load_dir("res://data")
	c.cards["t4"] = {"id": "t4", "time": 4, "weight": 1, "rarity": "common", "target": {"shape": "cell", "range": 9}, "parts": [{"op": "damage", "amount": 3, "kind": "physical"}]}
	c.cards["tele"] = {"id": "tele", "time": 2, "weight": 1, "rarity": "common", "telegraph": true, "target": {"shape": "cell", "range": 9}, "parts": [{"op": "damage", "amount": 10, "kind": "physical"}]}
	c.cards["swap"] = {"id": "swap", "time": 2, "weight": 1, "rarity": "epic", "target": {"shape": "cell", "range": 9}, "parts": [{"op": "swap_bodies"}]}
	c.cards["kill"] = {"id": "kill", "time": 1, "weight": 1, "rarity": "epic", "target": {"shape": "cell", "range": 9}, "parts": [{"op": "damage", "amount": 999, "kind": "true"}]}
	c.actors["hero"] = {"id": "hero", "hp": 40, "mass": 2, "base_ability": "step1", "deck": ["t4", "t4", "t4", "t4", "t4", "t4"]}
	c.actors["dummy"] = {"id": "dummy", "hp": 20, "mass": 1, "base_ability": "step1", "deck": ["tele"], "pattern": ["tele"]}
	c.actors["swapper"] = {"id": "swapper", "hp": 40, "mass": 2, "base_ability": "step1", "deck": ["swap", "swap", "swap", "swap", "swap", "swap"]}
	c.actors["dummy_killer"] = {"id": "dummy_killer", "hp": 20, "mass": 1, "deck": ["kill", "kill", "kill", "kill", "kill"], "pattern": ["tele"]}

const LAYOUT := {"player_pos": [1, 3], "enemy_pos": [[7, 3]], "materials": []}

func slot_of(b: Battle, id: String) -> int:
	for i in b.belt.slots.size():
		if b.belt.slots[i] != null and b.belt.slots[i]["card_id"] == id:
			return i
	return -1

func run() -> void:
	setup_catalog()
	var b := Battle.new(c, 1, "hero", ["dummy"], LAYOUT)
	var foe: Actor = b.actors[1]
	assert_eq(b.time_left, 10, "turn time 10")
	assert_true(b.cmd_play(0, foe.pos), "first t4")
	assert_true(b.cmd_play(1, foe.pos), "second t4")
	var snap := b.grid.duplicate_state()
	var hp := foe.hp
	assert_true(not b.cmd_play(2, foe.pos), "third t4 rejected (time 2 left)")
	assert_eq(foe.hp, hp, "rejected play changed nothing")
	assert_eq(b.time_left, 2, "time unchanged after rejection")
	assert_true(b.belt.slots[2] != null, "card still in hand")
	assert_eq(b.grid.duplicate_state()["material"], snap["material"], "grid unchanged")
	assert_true(not b.cmd_play(3, Vector2i(20, 20)), "out of range rejected")
	# move once per turn
	assert_true(b.cmd_move(Vector2i.UP), "move once")
	assert_true(not b.cmd_move(Vector2i.UP), "second move rejected")
	# telegraph: stay -> hit
	var s := Battle.new(c, 2, "hero", ["dummy"], LAYOUT)
	var p: Actor = s.human()
	s.cmd_end_turn()
	assert_eq(s.telegraphs.size(), 1, "enemy telegraphed")
	assert_eq(p.hp, 40, "telegraph does not hit immediately")
	s.cmd_end_turn()
	assert_eq(p.hp, 30, "stayed on telegraphed cell -> hit")
	# telegraph: dodge -> no damage
	var d := Battle.new(c, 2, "hero", ["dummy"], LAYOUT)
	var p2: Actor = d.human()
	d.cmd_end_turn()
	d.cmd_move(Vector2i.UP)
	d.cmd_end_turn()
	assert_eq(p2.hp, 40, "dodged telegraph")
	# time_scale on player cell sets next turn budget
	var t := Battle.new(c, 3, "hero", ["dummy"], LAYOUT)
	t.grid.set_var(t.human().pos, "time_scale", 0.3)
	t.cmd_end_turn()
	var ts := float(t.grid.get_var(t.human().pos, "time_scale"))
	assert_eq(t.time_left, int(round(10.0 * ts)), "budget follows cell time_scale")
	assert_true(t.time_left < 10, "slowed turn has less time")
	# determinism
	var r1 := _scripted(7)
	var r2 := _scripted(7)
	assert_eq(r1, r2, "same seed + same commands -> same result")
	# preview does not change state
	var pv := Battle.new(c, 4, "hero", ["dummy"], LAYOUT)
	var before := pv.grid.duplicate_state()
	var fhp: int = pv.actors[1].hp
	var info := pv.preview(0, pv.actors[1].pos)
	assert_true(info["damage_by_uid"].get(pv.actors[1].uid, 0) > 0, "preview predicts damage")
	assert_eq(pv.actors[1].hp, fhp, "preview restored hp")
	assert_eq(pv.grid.duplicate_state()["values"]["temperature"], before["values"]["temperature"], "preview restored grid")
	# body swap, then defeat own old body -> won
	var w := Battle.new(c, 5, "swapper", ["dummy_killer"], LAYOUT)
	var old_body: Actor = w.human()
	var target: Actor = w.actors[1]
	assert_true(w.cmd_play(0, target.pos), "swap played")
	assert_true(w.human() == target, "now controlling the enemy body")
	assert_eq(w.belt.slots[0]["card_id"], "kill", "hand rebuilt from new body's deck")
	assert_true(w.cmd_play(0, old_body.pos), "attack old body")
	assert_eq(w.phase, "won", "defeating old body wins")
	# empty enemy list -> immediate win; human death -> lost
	var l := Battle.new(c, 6, "hero", ["dummy"], LAYOUT)
	l.human().hp = 0
	l.cmd_end_turn()
	assert_eq(l.phase, "lost", "dead human loses")
	test_frozen_enemy_skips()
	test_hold_one_card()

func _scripted(seed_value: int) -> Array:
	var b := Battle.new(c, seed_value, "hero", ["dummy"], {})
	b.cmd_play(0, b.actors[1].pos)
	b.cmd_end_turn()
	b.cmd_move(Vector2i.DOWN)
	b.cmd_end_turn()
	b.cmd_play(1, b.actors[1].pos)
	b.cmd_end_turn()
	return [b.grid.duplicate_state()["values"], b.grid.material, b.actors.map(func(a): return [a.hp, a.pos])]

func test_frozen_enemy_skips() -> void:
	var f := Battle.new(c, 8, "hero", ["dummy"], LAYOUT)
	Effects.apply(Effects.card_def("stasis", c), f.human(), f.actors[1].pos, f.ctx)
	f.cmd_end_turn()
	assert_eq(f.telegraphs.size(), 0, "enemy in stopped time does not act")

func test_hold_one_card() -> void:
	var b := Battle.new(c, 9, "hero", ["dummy"], LAYOUT)
	var life: float = b.belt.slots[2]["life"]
	assert_true(b.cmd_hold(2), "hold a single card")
	assert_eq(b.time_left, 8, "hold costs 2 time")
	assert_eq(b.belt.slots[2]["life"], life + HandBelt.HOLD_BONUS, "that card lives longer")
