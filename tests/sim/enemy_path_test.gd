extends TestCase
## Enemy movement: real paths around walls and bodies, hazards avoided, and the next blow shown ahead.

var c: Catalog

func battle(layout: Dictionary) -> Battle:
	return Battle.new(c, 1, "walker", ["slime"], layout)

func run() -> void:
	c = Catalog.load_dir("res://data")
	# a wall between: the greedy step stalled, the path goes around
	var b := battle({"player_pos": [1, 3], "enemy_pos": [[5, 3]], "materials": [[4, 2, "wall"], [4, 3, "wall"], [4, 4, "wall"]]})
	var s: Actor = b.actors[1]
	var step := b.ai_step_cell(s, b.human().pos)
	assert_true(step != s.pos, "finds a way around the wall")
	assert_true(step == Vector2i(5, 2) or step == Vector2i(5, 4), "steps toward the gap")
	# a line of fire across the way: walks around it instead of through
	var fire := []
	for y in range(0, 6):
		fire.append([3, y, "fire"])
	b = battle({"player_pos": [1, 3], "enemy_pos": [[5, 3]], "materials": fire})
	s = b.actors[1]
	s.temper = "careful"
	for k in 8:
		var nxt := b.ai_step_cell(s, b.human().pos)
		if nxt == s.pos:
			break
		assert_true(not b.hazard(nxt), "never steps into fire (step %d)" % k)
		b.grid.move_unit(s, nxt)
	# standing in fire: steps out first
	b = battle({"player_pos": [1, 3], "enemy_pos": [[5, 3]], "materials": [[5, 3, "fire"]]})
	s = b.actors[1]
	s.temper = "careful"
	var it := b.ai_intent(s)
	assert_eq(it.get("kind", ""), "move", "intends to leave the fire")
	assert_true(not b.hazard(it["to"]), "to a safe cell")
	# next to the hero: the coming bite is shown before it starts
	b = battle({"player_pos": [3, 3], "enemy_pos": [[4, 3]], "materials": []})
	s = b.actors[1]
	it = b.ai_intent(s)
	assert_eq(it.get("kind", ""), "attack", "shows the coming blow")
	assert_true(it["cells"].has(Vector2i(3, 3)), "on the hero's cell")
	assert_true(int(it["fire_at"]) > b.now, "with when it lands")
	test_tempers()
	test_likes_dislikes()
	test_split()
	test_move_styles()

func ring_of_fire() -> Array:
	var ring := []
	for p in [[4, 2], [5, 2], [6, 2], [4, 3], [6, 3], [4, 4], [5, 4], [6, 4]]:
		ring.append([p[0], p[1], "fire"])
	return ring

func test_tempers() -> void:
	# reckless: straight through the fire
	var b := battle({"player_pos": [1, 3], "enemy_pos": [[5, 3]], "materials": ring_of_fire()})
	var s: Actor = b.actors[1]
	s.temper = "reckless"
	assert_eq(b.ai_step_cell(s, b.human().pos), Vector2i(4, 3), "reckless walks into the fire")
	# careful: shut in, waits... then loses patience
	b = battle({"player_pos": [1, 3], "enemy_pos": [[5, 3]], "materials": ring_of_fire()})
	s = b.actors[1]
	s.temper = "careful"
	assert_eq(b.ai_step_cell(s, b.human().pos), Vector2i(5, 3), "careful waits inside the ring")
	s.stuck = Battle.STUCK_LIMIT
	assert_true(b.ai_step_cell(s, b.human().pos) != Vector2i(5, 3), "after a while it breaks out")
	# careful one left in the ring for a while gets out in the end
	b = battle({"player_pos": [1, 3], "enemy_pos": [[5, 3]], "materials": ring_of_fire()})
	s = b.actors[1]
	s.temper = "careful"
	b.cmd_wait(10)
	assert_true(s.pos != Vector2i(5, 3) or not s.alive(), "not shut in forever")
	# stubborn: breaks through at once when the way round is closed
	b = battle({"player_pos": [1, 3], "enemy_pos": [[5, 3]], "materials": ring_of_fire()})
	s = b.actors[1]
	s.temper = "stubborn"
	assert_true(b.ai_step_cell(s, b.human().pos) != Vector2i(5, 3), "stubborn breaks through")
	# but goes round a short detour instead of through fire
	var wall := []
	for y in range(0, 6):
		wall.append([3, y, "fire"])
	b = battle({"player_pos": [1, 3], "enemy_pos": [[5, 5]], "materials": wall})
	s = b.actors[1]
	s.temper = "stubborn"
	var burnt := false
	for k in 8:
		var nxt := b.ai_step_cell(s, b.human().pos)
		if nxt == s.pos:
			break
		burnt = burnt or b.hazard(nxt)
		b.grid.move_unit(s, nxt)
	assert_true(not burnt, "stubborn takes a short way round")

func test_likes_dislikes() -> void:
	# a fire imp hates water: it goes round a pool, and standing in it hurts
	var b := Battle.new(c, 1, "walker", ["ember_imp"], {"player_pos": [1, 3], "enemy_pos": [[5, 3]], "materials": [[4, 3, "water"]]})
	var imp: Actor = b.actors[1]
	assert_true(b.hazard(Vector2i(4, 3), imp), "water is harm to the imp")
	assert_true(not b.hazard(Vector2i(4, 3)), "but not to anyone")
	assert_true(b.ai_step_cell(imp, b.human().pos) != Vector2i(4, 3), "goes round the water")
	b.grid.move_unit(imp, Vector2i(4, 3))
	var hp := imp.hp
	b._likes_dislikes()
	assert_true(imp.hp < hp, "water hurts the imp")
	# and likes fire: not harm, and it heals there
	b.grid.set_material(Vector2i(4, 3), "fire")
	assert_true(not b.hazard(Vector2i(4, 3), imp), "fire is home to the imp")
	imp.hp = 5
	b._likes_dislikes()
	assert_true(imp.hp > 5, "fire heals the imp")
	# even a reckless slime steps off ice it hates
	b = battle({"player_pos": [1, 3], "enemy_pos": [[5, 3]], "materials": [[5, 3, "ice"]]})
	var s: Actor = b.actors[1]
	assert_true(b._wants_out(s), "slime leaves the ice")

func test_split() -> void:
	var b := battle({"player_pos": [1, 3], "enemy_pos": [[5, 3]], "materials": []})
	var s: Actor = b.actors[1]
	var n := b.actors.size()
	s.hp = s.max_hp / 2
	b._after_action()
	assert_eq(b.actors.size(), n + 1, "the slime split in two")
	var kid: Actor = b.actors[b.actors.size() - 1]
	assert_eq(kid.def_id, "slime", "into another slime")
	assert_true(kid.alive() and s.alive(), "both halves alive")
	assert_eq(kid.hp + s.hp, 9, "the hp is shared out")
	assert_true(b.grid.units.has(kid) and kid.pos.distance_to(s.pos) == 1.0, "side by side")
	s.hp = 1
	b._after_action()
	assert_eq(b.actors.size(), n + 1, "a half does not split again")

func test_move_styles() -> void:
	# slime hops two cells at a time
	var b := battle({"player_pos": [1, 3], "enemy_pos": [[7, 3]], "materials": []})
	var s: Actor = b.actors[1]
	var card := Effects.card_def("enemy_bite", c)
	var plan := b.move_plan(s, b.human(), b.human().pos, card)
	assert_eq(Battle.dist(s.pos, plan["to"]), 2, "slime hops two cells")
	# imp keeps off your row and column
	b = Battle.new(c, 1, "walker", ["ember_imp"], {"player_pos": [1, 3], "enemy_pos": [[8, 3]], "materials": []})
	var imp: Actor = b.actors[1]
	var walked := imp.pos
	for k in 6:
		var pl := b.move_plan(imp, b.human(), b.human().pos, Effects.card_def("enemy_ember", c))
		if pl["to"] == imp.pos:
			break
		b.grid.move_unit(imp, pl["to"])
	assert_true(imp.pos.y != 3 or Battle.dist(imp.pos, b.human().pos) > 3, "imp comes in off your line")
	# and backs off when you are next to it
	b.grid.move_unit(b.human(), imp.pos + Vector2i.LEFT if b.grid.unit_at(imp.pos + Vector2i.LEFT) == null else imp.pos + Vector2i.UP)
	var away := b.move_plan(imp, b.human(), b.human().pos, Effects.card_def("enemy_ember", c))
	assert_true(Battle.dist(away["to"], b.human().pos) > 1, "imp backs off")
	# golem rushes down a clear lane
	b = Battle.new(c, 1, "walker", ["iron_golem"], {"player_pos": [1, 3], "enemy_pos": [[6, 3]], "materials": []})
	var g: Actor = b.actors[1]
	var ch := EnemyAI.choose(g, b)
	assert_eq(ch.get("card_id", ""), "enemy_charge", "golem charges when you stand in its lane")
	var hp := b.human().hp
	Effects.apply(Effects.card_def("enemy_charge", c), g, ch["aim"], b.ctx)
	assert_true(b.human().hp < hp, "the charge hits")
	assert_true(Battle.dist(g.pos, b.human().pos) <= 2, "and the golem ends up in your face")
	# out of the lane it walks, slowly
	b = Battle.new(c, 1, "walker", ["iron_golem"], {"player_pos": [1, 1], "enemy_pos": [[6, 4]], "materials": []})
	g = b.actors[1]
	assert_true(EnemyAI.choose(g, b).get("card_id", "") != "enemy_charge", "no lane, no charge")
	assert_eq(b.move_plan(g, b.human(), b.human().pos, Effects.card_def("enemy_slam", c))["secs"], 2, "golem steps take 2 seconds")
