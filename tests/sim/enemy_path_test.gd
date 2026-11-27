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
