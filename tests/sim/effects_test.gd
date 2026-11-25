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
	# var add over circle
	Effects.apply(card([{"op": "var", "id": "temperature", "mode": "add", "value": 50}], "circle", 1), me, Vector2i(4, 3), ctx)
	assert_eq(ctx.grid.get_var(Vector2i(5, 4), "temperature"), 70.0, "circle heated")
	assert_eq(ctx.grid.get_var(Vector2i(7, 3), "temperature"), 20.0, "outside untouched")
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
	# beam reflects off ice and hits unit behind the user
	var c2 := ctx_with([])
	var shooter := mk("s", 3, 0); var behind := mk("b", 4, 1)
	c2.actors = [shooter, behind]
	c2.grid.place_unit(shooter, Vector2i(3, 1)); c2.grid.place_unit(behind, Vector2i(1, 1))
	c2.grid.set_material(Vector2i(5, 1), "metal")
	Effects.apply(card([{"op": "beam", "damage": 8, "kind": "energy", "length": 8}]), shooter, Vector2i(6, 1), c2)
	assert_eq(behind.hp, 22, "reflected beam hits unit behind")
	assert_eq(shooter.hp, 30, "beam passes through its shooter")
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
	# sustained var (turns) reapplies each tick
	Effects.apply(card([{"op": "var", "id": "noise", "mode": "add", "value": 2, "turns": 2}]), u3, Vector2i(6, 6), c3)
	assert_eq(c3.grid.get_var(Vector2i(6, 6), "noise"), 2.0, "applied now")
	Effects.tick_pending(c3); Effects.tick_pending(c3); Effects.tick_pending(c3)
	assert_eq(c3.grid.get_var(Vector2i(6, 6), "noise"), 6.0, "reapplied for 2 ticks only")
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
	assert_true(not me4.deck.has("summon:slime"), "cardify fails at 50%")
	sl.hp = int(sl.max_hp * 0.2)
	Effects.apply(card([{"op": "cardify"}]), me4, Vector2i(1, 0), c4)
	assert_true(me4.deck.has("summon:slime"), "cardify adds summon card")
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
	# gravity toward aim
	Effects.apply(card([{"op": "var", "id": "gravity", "mode": "set", "value": {"dir": "toward_aim", "strength": 3}}], "circle", 1), a5, Vector2i(4, 3), c5)
	assert_eq(c5.grid.get_var(Vector2i(3, 3), "gravity"), Vector2(3, 0), "pulls toward aim")
