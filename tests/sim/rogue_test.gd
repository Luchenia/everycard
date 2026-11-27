extends TestCase
## 도적 cards and systems: back attacks, shadows, bombs, traps, smoke, interrupts, the shadow clone, one-shot cards.

var c: Catalog

func _battle(card_id: String, lay: Dictionary, foes := ["idle"]) -> Battle:
	c.actors["p_" + card_id] = {"id": "p_" + card_id, "hp": 40, "mass": 2, "base_ability": "step1", "facing": [1, 0],
		"passives": ["backstab"], "deck": [card_id, card_id, card_id, card_id, card_id, card_id, card_id]}
	return Battle.new(c, 1, "p_" + card_id, foes, lay)

func _lay(p: Array, foes: Array) -> Dictionary:
	return {"player_pos": p, "enemy_pos": foes, "materials": []}

func run() -> void:
	c = Catalog.load_dir("res://data")
	test_diagonal_throw()
	c.config = {"round_time": 10, "grid_w": 9, "grid_h": 7, "env_every": 2, "move_time": 1, "wheel_time": 1, "draws_per_round": 2}
	c.actors["idle"] = {"id": "idle", "hp": 30, "mass": 1, "deck": [], "pattern": []}
	c.cards["slow_hit"] = {"id": "slow_hit", "time": 3, "weight": 1, "telegraph": true, "target": {"shape": "cell", "range": 9}, "parts": [{"op": "damage", "amount": 7, "kind": "true"}]}
	c.actors["hitter"] = {"id": "hitter", "hp": 30, "mass": 1, "deck": ["slow_hit"], "pattern": ["slow_hit"]}
	test_shadow_tread_and_backstab()
	test_shadow_walk()
	test_time_bomb()
	test_rabbit_trap()
	test_weak_spot_and_poison()
	test_ambush_and_stolen_time()
	test_smoke_hides()
	test_dagger_fan()
	test_clone_echoes()
	test_once_card_leaves_deck()

func test_shadow_tread_and_backstab() -> void:
	var b := _battle("shadow_tread", _lay([1, 3], [[3, 3]]))
	var foe: Actor = b.actors[1]
	foe.facing = Vector2i.LEFT
	assert_true(b.cmd_play(0, foe.pos), "shadow tread")
	assert_eq(b.human().pos, Vector2i(4, 3), "stands at the foe's back")
	var hp0 := foe.hp
	Effects.apply({"parts": [{"op": "damage", "amount": 6, "kind": "physical"}], "target": {"shape": "cell"}}, b.human(), foe.pos, b.ctx)
	assert_eq(foe.hp, hp0 - 6 - Actor.BACKSTAB_BONUS, "back attack bonus")
	foe.facing = Vector2i.RIGHT
	hp0 = foe.hp
	Effects.apply({"parts": [{"op": "damage", "amount": 6, "kind": "physical"}], "target": {"shape": "cell"}}, b.human(), foe.pos, b.ctx)
	assert_eq(foe.hp, hp0 - 6, "no bonus from the front")

func test_shadow_walk() -> void:
	var b := _battle("shadow_walk", _lay([1, 3], [[3, 3], [8, 0]]))
	var foe: Actor = b.actors[1]
	foe.facing = Vector2i.LEFT
	var hp0 := foe.hp
	assert_true(b.cmd_play(0, Vector2i(5, 3)), "shadow walk")
	assert_eq(b.human().pos, Vector2i(5, 3), "ran through to the far cell")
	assert_eq(foe.hp, hp0 - 4, "cut on the way")
	assert_true(foe.has_status("shadowed"), "left a shadow")
	hp0 = foe.hp
	foe.facing = Vector2i.RIGHT   # facing the rogue now: no back attack
	Effects.apply({"parts": [{"op": "damage", "amount": 2, "kind": "physical"}], "target": {"shape": "cell"}}, b.human(), foe.pos, b.ctx)
	assert_eq(foe.hp, hp0 - 2 - Actor.SHADOW_BONUS, "shadow makes the next hit harder")
	assert_true(not foe.has_status("shadowed"), "and is used up")

func test_time_bomb() -> void:
	var b := _battle("time_bomb", _lay([1, 3], [[3, 3]]))
	var foe: Actor = b.actors[1]
	var hp0 := foe.hp
	assert_true(b.cmd_play(0, Vector2i(2, 3)), "plant the bomb")
	assert_eq(foe.hp, hp0, "nothing yet")
	b.cmd_wait(3)
	assert_eq(foe.hp, hp0 - 8, "it went off around the bomb")
	assert_true(b.human().hp < 40, "and the planter was in range")

func test_rabbit_trap() -> void:
	c.actors["walkerfoe"] = {"id": "walkerfoe", "hp": 30, "mass": 1, "deck": ["strike"], "pattern": ["strike"]}
	var b := _battle("rabbit_trap", _lay([1, 3], [[4, 3]]), ["walkerfoe"])
	var foe: Actor = b.actors[1]
	var hp0 := foe.hp
	assert_true(b.cmd_play(0, Vector2i(3, 3)), "set the trap")
	b.cmd_wait(3)
	assert_eq(foe.hp, hp0 - 4, "the trap caught the foe")
	assert_eq(b.grid.get_material(Vector2i(3, 3)), "none", "trap used up")

func test_weak_spot_and_poison() -> void:
	var b := _battle("weak_spot", _lay([1, 3], [[2, 3]]))
	var foe: Actor = b.actors[1]
	foe.facing = Vector2i.LEFT
	assert_true(b.cmd_play(0, b.human().pos), "weak spot")
	var hp0 := foe.hp
	Effects.apply({"parts": [{"op": "damage", "amount": 3, "kind": "physical"}], "target": {"shape": "cell"}}, b.human(), foe.pos, b.ctx)
	assert_eq(foe.hp, hp0 - 7, "+4 on the next attack")
	hp0 = foe.hp
	Effects.apply({"parts": [{"op": "damage", "amount": 3, "kind": "physical"}], "target": {"shape": "cell"}}, b.human(), foe.pos, b.ctx)
	assert_eq(foe.hp, hp0 - 3, "only once")
	var b2 := _battle("poison_blade", _lay([1, 3], [[2, 3]]))
	var f2: Actor = b2.actors[1]
	f2.facing = Vector2i.LEFT
	assert_true(b2.cmd_play(0, b2.human().pos), "coat the blade")
	for k in 3:
		f2.statuses.erase("poisoned")
		Effects.apply({"parts": [{"op": "damage", "amount": 1, "kind": "physical"}], "target": {"shape": "cell"}}, b2.human(), f2.pos, b2.ctx)
		assert_eq(f2.has_status("poisoned"), k < 2, "poison on attack %d" % (k + 1))

func test_ambush_and_stolen_time() -> void:
	var b := _battle("ambush", _lay([1, 3], [[2, 3]]), ["hitter"])
	var foe: Actor = b.actors[1]
	for k in 4:
		if not b.telegraphs.is_empty():
			break
		b.cmd_wait(1)
	assert_true(not b.telegraphs.is_empty(), "the foe announced an attack")
	assert_true(b.cmd_play(0, foe.pos), "ambush")
	assert_true(b.telegraphs.is_empty(), "announced attack cancelled")
	var b2 := _battle("stolen_time", _lay([1, 3], [[4, 3]]), ["hitter"])
	var f2: Actor = b2.actors[1]
	var at0 := f2.next_at
	assert_true(b2.cmd_play(0, f2.pos), "steal time")
	assert_eq(f2.next_at, at0 + 2, "its next action is 2 seconds later")

func test_smoke_hides() -> void:
	var b := _battle("smoke_bomb", _lay([1, 3], [[6, 3]]), ["hitter"])
	assert_true(b.cmd_play(0, b.human().pos + Vector2i(1, 0)) or b.cmd_play(0, Vector2i(2, 3)), "smoke")
	assert_eq(b.grid.get_material(b.human().pos), "smoke_screen", "standing in smoke")
	assert_true(EnemyAI.nearest_foe(b.actors[1], b) == null, "the foe cannot single us out")
	b.cmd_wait(7)
	assert_eq(b.grid.get_material(b.human().pos), "none", "the smoke clears after a while")

func test_dagger_fan() -> void:
	var b := _battle("dagger_fan", _lay([1, 3], [[3, 3], [3, 5], [3, 1]]), ["idle", "idle", "idle"])
	var hp := [b.actors[1].hp, b.actors[2].hp, b.actors[3].hp]
	assert_true(b.cmd_play(0, Vector2i(4, 3)), "fan")
	assert_true(b.actors[1].hp < hp[0], "middle hit")
	assert_true(b.actors[2].hp < hp[1] and b.actors[3].hp < hp[2], "both diagonals hit")

func test_clone_echoes() -> void:
	c.actors["p_mix"] = {"id": "p_mix", "hp": 40, "mass": 2, "base_ability": "step1", "facing": [1, 0],
		"deck": ["shadow_clone", "throw_dagger", "throw_dagger", "throw_dagger", "throw_dagger"]}
	var b := Battle.new(c, 1, "p_mix", ["idle"], _lay([1, 3], [[6, 3]]))
	var s := -1
	for i in b.belt.slots.size():
		if b.belt.slots[i] != null and b.belt.slots[i]["card_id"] == "shadow_clone":
			s = i
	b.belt.slots[0] = {"card_id": "shadow_clone", "life": 3.0}
	assert_true(b.cmd_play(0, Vector2i(2, 4)), "leave a clone")
	var clone: Actor = null
	for a in b.actors:
		if a.controller == "echo":
			clone = a
	assert_true(clone != null, "clone exists")
	b.belt.slots[1] = {"card_id": "throw_dagger", "life": 3.0}
	b.grid.move_unit(b.actors[1], Vector2i(4, 3))
	var hp0: int = b.actors[1].hp
	assert_true(b.cmd_play(1, Vector2i(4, 3)), "throw")
	assert_eq(b.actors[1].hp, hp0 - 4, "only my dagger hits: the clone's lane is row 4")
	b.cmd_wait(9)
	assert_true(not clone.alive(), "the clone fades")

func test_once_card_leaves_deck() -> void:
	c.actors["p_once"] = {"id": "p_once", "hp": 40, "mass": 2, "base_ability": "step1", "deck": ["body_swap", "strike", "strike", "strike", "strike", "strike"]}
	var b := Battle.new(c, 1, "p_once", ["idle"], _lay([1, 3], [[3, 3]]))
	b.belt.slots[0] = {"card_id": "body_swap", "life": 3.0}
	var h := b.human()
	var n0 := h.deck.count("body_swap")
	assert_true(b.cmd_play(0, b.actors[1].pos), "swap")
	var me := b.human()
	assert_true(not b.belt.ring().has("body_swap") or n0 > 1, "gone from the ring")
	assert_eq(h.deck.count("body_swap"), n0 - 1, "gone from the deck")

func test_diagonal_throw() -> void:
	var cc := Catalog.load_dir("res://data")
	var b := Battle.new(cc, 1, "walker", ["slime"], {"player_pos": [2, 2], "enemy_pos": [[5, 5]], "materials": []})
	var foe: Actor = b.actors[1]
	var hp := foe.hp
	var card := Effects.card_def("throw_dagger", cc)
	assert_true(Battle.in_reach(card, Vector2i(2, 2), Vector2i(5, 5)), "the dagger reaches along the diagonal")
	Effects.apply(card, b.human(), Vector2i(5, 5), b.ctx)
	assert_true(foe.hp < hp, "and flies diagonally into the slime")
