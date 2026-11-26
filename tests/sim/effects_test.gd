extends TestCase

var c: Catalog

func ctx_with(units: Array) -> Effects.BattleContext:
	var ctx := Effects.BattleContext.new()
	ctx.catalog = c
	ctx.grid = Grid.new(c)
	ctx.rng = SimRng.new(3)
	ctx.actors = units
	ctx.next_uid = 100
	return ctx

func mk(id: String, uid: int, team: int, hp := 30) -> Actor:
	var a := Actor.from_def({"id": id, "name": id, "hp": hp, "mass": 1, "deck": ["x1", "x2"]}, uid)
	a.team = team
	return a

func card(parts: Array, shape := "cell", size := 0) -> Dictionary:
	return {"id": "t", "time": 1, "weight": 1, "rarity": "common", "target": {"shape": shape, "range": 9, "size": size}, "parts": parts}

func run() -> void:
	c = Catalog.load_dir("res://data")
	var me := mk("me", 1, 0); var foe := mk("foe", 2, 1)
	var ctx := ctx_with([me, foe])
	ctx.grid.place_unit(me, Vector2i(1, 3)); ctx.grid.place_unit(foe, Vector2i(5, 3))
	# state over circle
	Effects.apply(card([{"op": "state", "id": "heat"}], "circle", 1), me, Vector2i(4, 3), ctx)
	assert_true(ctx.grid.has_state(Vector2i(5, 4), "heat"), "circle heated")
	assert_true(not ctx.grid.has_state(Vector2i(7, 3), "heat"), "outside untouched")
	ctx.grid.cell_states.map(func(st): st.clear())
	# damage respects resistance
	foe.resist = {"fire": 0.5}
	Effects.apply(card([{"op": "damage", "amount": 10, "kind": "fire"}]), me, Vector2i(5, 3), ctx)
	assert_eq(foe.hp, 25, "fire damage halved")
	# empty cell damage -> no_target
	ctx.log.clear()
	Effects.apply(card([{"op": "damage", "amount": 10, "kind": "physical"}]), me, Vector2i(6, 6), ctx)
	assert_true(ctx.log.any(func(e): return e["t"] == "no_target"), "no_target logged")
	# push away into wall: stops and takes collision damage
	ctx.grid.set_material(Vector2i(7, 3), "wall")
	var hp0 := foe.hp
	Effects.apply(card([{"op": "push", "dist": 3, "dir": "away"}]), me, Vector2i(5, 3), ctx)
	assert_eq(foe.pos, Vector2i(6, 3), "stopped at wall")
	assert_true(foe.hp < hp0, "collision damage on push")
	# beam reflects off a mirror straight back along its path
	var c2 := ctx_with([])
	var shooter := mk("s", 3, 0); var behind := mk("b", 4, 1)
	c2.actors = [shooter, behind]
	c2.grid.place_unit(shooter, Vector2i(3, 1)); c2.grid.place_unit(behind, Vector2i(1, 1))
	c2.grid.set_material(Vector2i(5, 1), "metal")
	Effects.apply(card([{"op": "beam", "damage": 8, "kind": "energy", "length": 8}]), shooter, Vector2i(6, 1), c2)
	# a mirror sends it straight back: the shooter is the first thing in its way
	assert_eq(shooter.hp, 22, "reflected beam comes back to its shooter")
	assert_eq(behind.hp, 30, "and stops there")
	# if: condition false -> nothing
	var c3 := ctx_with([])
	var u3 := mk("u", 5, 0); var f3 := mk("f", 6, 1)
	c3.actors = [u3, f3]
	c3.grid.place_unit(u3, Vector2i(0, 0)); c3.grid.place_unit(f3, Vector2i(2, 0))
	Effects.apply(card([{"op": "if", "cond": [{"status": "wet"}], "part": {"op": "damage", "amount": 9, "kind": "electric"}}]), u3, Vector2i(2, 0), c3)
	assert_eq(f3.hp, 30, "if false: no damage")
	f3.add_status("wet", 2)
	Effects.apply(card([{"op": "if", "cond": [{"status": "wet"}], "part": {"op": "damage", "amount": 9, "kind": "electric"}}]), u3, Vector2i(2, 0), c3)
	assert_eq(f3.hp, 21, "if true: damage")
	# delay goes to pending, fires after ticks
	Effects.apply(card([{"op": "delay", "ticks": 2, "part": {"op": "material", "id": "fire"}}]), u3, Vector2i(4, 4), c3)
	assert_eq(c3.pending.size(), 1, "delay pending")
	Effects.tick_pending(c3)
	assert_eq(c3.grid.get_material(Vector2i(4, 4)), "none", "not yet")
	Effects.tick_pending(c3)
	assert_eq(c3.grid.get_material(Vector2i(4, 4)), "fire", "delayed fire placed")
	assert_eq(c3.pending.size(), 0, "pending cleared")
	# a state with its own seconds
	Effects.apply(card([{"op": "state", "id": "echo", "secs": 6}]), u3, Vector2i(6, 6), c3)
	assert_eq(float(c3.grid.cell_states[c3.grid.idx(Vector2i(6, 6))]["echo"]["left"]), 6.0, "lasts the seconds the card says")
	# lightning on a puddle runs through the whole puddle at once
	for x in range(0, 4):
		c3.grid.set_material(Vector2i(x, 6), "water")
	Effects.apply(card([{"op": "state", "id": "charged"}]), u3, Vector2i(0, 6), c3)
	assert_true(c3.grid.has_state(Vector2i(3, 6), "charged"), "charge flows through water")
	assert_true(not c3.grid.has_state(Vector2i(4, 5), "charged"), "dry floor does not carry it")
	# swap with boss refused
	var boss := Actor.from_def({"id": "boss", "hp": 100, "is_boss": true, "deck": ["y"]}, 7)
	c3.actors.append(boss); c3.grid.place_unit(boss, Vector2i(5, 5))
	c3.log.clear()
	Effects.apply(card([{"op": "swap_bodies"}]), u3, Vector2i(5, 5), c3)
	assert_eq(boss.controller, "ai", "boss not swapped")
	assert_true(c3.log.any(func(e): return e["t"] == "swap_refused"), "refusal logged")
	# swap with normal foe
	u3.controller = "human"
	Effects.apply(card([{"op": "swap_bodies"}]), u3, Vector2i(2, 0), c3)
	assert_eq(f3.controller, "human", "foe body now human")
	# cardify: 50% hp fails, 20% succeeds
	var c4 := ctx_with([])
	var me4 := mk("me", 8, 0); var sl := Actor.from_def(c.actors["slime"], 9)
	c4.actors = [me4, sl]
	c4.grid.place_unit(me4, Vector2i(0, 0)); c4.grid.place_unit(sl, Vector2i(1, 0))
	sl.hp = sl.max_hp / 2
	Effects.apply(card([{"op": "cardify"}]), me4, Vector2i(1, 0), c4)
	assert_true(not me4.deck.has("foe:slime"), "cardify fails at 50%")
	sl.hp = int(sl.max_hp * 0.2)
	Effects.apply(card([{"op": "cardify"}]), me4, Vector2i(1, 0), c4)
	assert_true(me4.deck.has("foe:slime"), "cardify turns the enemy itself into a card")
	var fc := Effects.card_def("foe:slime", c)
	assert_true(fc["parts"].size() >= 2, "foe card = signature move + trait parts")
	assert_true(not fc["parts"].any(func(p): return p["op"] == "summon"), "slime card does not summon")
	assert_true(c4.grid.unit_at(Vector2i(1, 0)) == null, "cardified unit removed")
	# summon card resolves and summons ally
	var sc := Effects.card_def("summon:slime", c)
	assert_eq(sc["parts"][0]["op"], "summon", "summon card generated")
	Effects.apply(sc, me4, Vector2i(2, 0), c4)
	var ally = c4.grid.unit_at(Vector2i(2, 0))
	assert_true(ally != null and ally.team == 0 and ally.controller == "ai", "ally summoned")
	# steal and plant
	var c5 := ctx_with([])
	var a5 := mk("a", 20, 0); var b5 := mk("b", 21, 1)
	a5.deck = []; c5.actors = [a5, b5]
	c5.grid.place_unit(a5, Vector2i(0, 0)); c5.grid.place_unit(b5, Vector2i(1, 0))
	Effects.apply(card([{"op": "steal_card"}]), a5, Vector2i(1, 0), c5)
	assert_eq(a5.deck.size(), 1, "stole one card")
	assert_eq(b5.deck.size(), 1, "victim lost one")
	Effects.apply(card([{"op": "plant_card", "card_id": "zz"}]), a5, Vector2i(1, 0), c5)
	assert_true(b5.deck.has("zz"), "planted")
	# meta ops go to on_meta
	var seen := []
	c5.on_meta = func(part, user): seen.append(part["op"])
	Effects.apply(card([{"op": "belt", "action": "freeze", "amount": 1}, {"op": "time_budget", "delta": 2}], "self"), a5, Vector2i(0, 0), c5)
	assert_eq(seen, ["belt", "time_budget"], "meta forwarded")
	test_cardify_state()
	# gravity toward aim
	Effects.apply(card([{"op": "state", "id": "pull", "dir": "toward_aim"}], "circle", 1), a5, Vector2i(4, 3), c5)
	assert_eq(c5.grid.state_dir(Vector2i(3, 3), "pull"), Vector2i.RIGHT, "pulls toward aim")
	assert_eq(c5.grid.state_dir(Vector2i(4, 3), "pull"), Vector2i.ZERO, "centre has no pull")

func test_cardify_state() -> void:
	var cx := ctx_with([])
	var me := mk("me", 30, 0); var sl := Actor.from_def(c.actors["slime"], 31)
	cx.actors = [me, sl]
	cx.grid.place_unit(me, Vector2i(0, 0)); cx.grid.place_unit(sl, Vector2i(1, 0))
	sl.hp = 2
	sl.add_status("burning", 2)
	Effects.apply(card([{"op": "cardify"}]), me, Vector2i(1, 0), cx)
	assert_true(me.deck.has("foe:slime|burning"), "state engraved in card id")
	var fc := Effects.card_def("foe:slime|burning", c)
	assert_true(fc["parts"].any(func(p): return p["op"] == "material" and p["id"] == "fire"), "burning adds fire")
	assert_true(not fc["parts"].any(func(p): return p["op"] == "summon"), "normal user: no summon")
	# summoner character makes a summon-type card
	var sm := Actor.from_def({"id": "sm", "hp": 30, "summoner": true, "deck": []}, 32)
	sm.team = 0
	var sl2 := Actor.from_def(c.actors["slime"], 33)
	cx.actors.append_array([sm, sl2])
	cx.grid.place_unit(sm, Vector2i(5, 5)); cx.grid.place_unit(sl2, Vector2i(6, 5))
	sl2.hp = 1
	Effects.apply(card([{"op": "cardify"}]), sm, Vector2i(6, 5), cx)
	assert_true(sm.deck.has("foe:slime|summon"), "summoner gets summon variant")
	assert_true(Effects.card_def("foe:slime|summon", c)["parts"].any(func(p): return p["op"] == "summon"), "summon part present")
