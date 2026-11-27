extends TestCase
## Shared-pool card mechanics: shield, dash, 서두름 discount, 불릿타임 borrowed time, 결정 encasing.

var c: Catalog
const LAYOUT := {"player_pos": [1, 3], "enemy_pos": [[7, 3]], "materials": []}

func _battle(card_id: String, enemy := "idle", lay := LAYOUT) -> Battle:
	c.actors["p_" + card_id] = {"id": "p_" + card_id, "hp": 40, "mass": 2, "base_ability": "step1",
		"deck": [card_id, card_id, card_id, card_id, card_id, card_id, card_id]}
	return Battle.new(c, 1, "p_" + card_id, [enemy], lay)

func run() -> void:
	c = Catalog.load_dir("res://data")
	c.config = {"round_time": 10, "grid_w": 9, "grid_h": 7, "env_every": 2, "move_time": 1, "wheel_time": 1, "draws_per_round": 2}
	c.actors["idle"] = {"id": "idle", "hp": 30, "mass": 1, "deck": [], "pattern": []}
	c.cards["hit7"] = {"id": "hit7", "time": 1, "weight": 1, "telegraph": true, "target": {"shape": "cell", "range": 9}, "parts": [{"op": "damage", "amount": 7, "kind": "true"}]}
	c.actors["hitter"] = {"id": "hitter", "hp": 30, "mass": 1, "deck": ["hit7"], "pattern": ["hit7"]}
	c.cards["borrow10"] = {"id": "borrow10", "time": 0, "weight": 1, "target": {"shape": "self", "range": 0}, "parts": [{"op": "borrow", "secs": 10}]}
	c.cards["hit7_4s"] = {"id": "hit7_4s", "time": 4, "weight": 1, "telegraph": true, "target": {"shape": "cell", "range": 9}, "parts": [{"op": "damage", "amount": 7, "kind": "true"}]}
	c.actors["slow_hitter"] = {"id": "slow_hitter", "hp": 30, "mass": 1, "deck": ["hit7_4s"], "pattern": ["hit7_4s"]}
	test_shield_absorbs_then_expires()
	test_dash_runs_two_cells_and_stops_at_blocker()
	test_discount_cuts_next_action()
	test_borrowed_time_freezes_world_then_exhausts()
	test_wait_ends_borrow_early()
	test_bullet_time_slows_the_world()
	test_haste_field_shortens_actions()
	test_crystal_roots_and_shatters()
	test_oil_on_fire_flares()

func test_shield_absorbs_then_expires() -> void:
	var b := _battle("guard")
	var h := b.human()
	assert_true(b.cmd_play(0, h.pos), "guard plays")
	assert_eq(h.shield, 8, "8 shield")
	assert_eq(h.take_damage(5, "true"), 0, "shield takes the hit")
	assert_eq(h.shield, 3, "3 left")
	b.cmd_wait(6)
	assert_eq(h.shield, 0, "shield gone after a while")

func test_dash_runs_two_cells_and_stops_at_blocker() -> void:
	var b := _battle("step")
	var h := b.human()
	assert_true(b.cmd_play(0, Vector2i(3, 3)), "dash 2 cells")
	assert_eq(h.pos, Vector2i(3, 3), "ran two cells")
	b.grid.set_material(Vector2i(4, 2), "wall")
	assert_true(not b.cmd_play(0, Vector2i(4, 2)), "a wall is not a place to dash to")
	assert_eq(h.pos, Vector2i(3, 3), "did not move")
	assert_true(b.cmd_play(0, Vector2i(5, 3)), "dash right")
	assert_eq(h.pos, Vector2i(5, 3), "ran right")

func test_discount_cuts_next_action() -> void:
	c.actors["p_mix"] = {"id": "p_mix", "hp": 40, "mass": 2, "base_ability": "step1", "deck": ["haste_field", "spark", "spark", "spark", "spark"]}
	var b := Battle.new(c, 1, "p_mix", ["idle"], LAYOUT)
	var slot := -1
	for i in b.belt.slots.size():
		if b.belt.slots[i] != null and b.belt.slots[i]["card_id"] == "haste_field":
			slot = i
	assert_true(slot >= 0, "서두름 in hand")
	var t0 := b.now
	assert_true(b.cmd_play(slot, b.human().pos), "서두름 plays")
	assert_eq(b.now, t0, "0-second card: the world does not move")
	assert_eq(b.human().discount, 2, "discount 2 pending")
	var s2 := -1
	for i in b.belt.slots.size():
		if b.belt.slots[i] != null and b.belt.slots[i]["card_id"] == "spark":
			s2 = i
	assert_true(b.cmd_play(s2, Vector2i(2, 3)), "spark plays")
	assert_eq(b.now, t0, "2-second spark became free")
	assert_eq(b.human().discount, 0, "discount used up")

func test_borrowed_time_freezes_world_then_exhausts() -> void:
	var b := _battle("borrow10")
	var h := b.human()
	assert_true(b.cmd_play(0, h.pos), "bullet time plays")
	assert_eq(b.borrow_left, 10, "10 seconds borrowed")
	var t0 := b.now
	for i in 4:
		assert_true(b.cmd_move(Vector2i.UP if i % 2 == 0 else Vector2i.DOWN), "move on borrowed time")
	assert_eq(b.now, t0, "world frozen while borrowing")
	assert_eq(b.borrow_left, 6, "4 seconds used")
	for i in 6:
		b.cmd_move(Vector2i.UP if i % 2 == 0 else Vector2i.DOWN)
	assert_eq(b.borrow_left, 0, "all borrowed time spent")
	assert_eq(b.now, t0 + 15, "repaid 10 x 1.5 = 15 seconds of exhaustion")

func test_wait_ends_borrow_early() -> void:
	var b := _battle("borrow10")
	b.cmd_play(0, b.human().pos)
	var t0 := b.now
	b.cmd_move(Vector2i.UP)
	b.cmd_move(Vector2i.DOWN)
	assert_true(b.cmd_wait(1), "wait ends borrowing")
	assert_eq(b.borrow_left, 0, "no borrowed time left")
	assert_eq(b.now, t0 + 3, "2 used -> 3 seconds exhausted")

## 불릿타임: the world runs three times slower for 4 world seconds. A 4-second attack warning
## keeps reading 4 seconds but counts down 0.3 s for each second the player spends.
func test_bullet_time_slows_the_world() -> void:
	var b := _battle("bullet_time", "slow_hitter")
	var h := b.human()
	b.cmd_wait(1)   # the foe starts its 4-second wind-up
	assert_eq(b.telegraphs.size(), 1, "attack warned")
	var fire_at := int(b.telegraphs[0]["fire_at"])
	assert_true(b.cmd_play(0, h.pos), "bullet time plays")
	assert_true(b.slowed(), "the world is slowed")
	assert_eq(b.shown_secs(1), 0.3, "a 1-second action shows 0.3 s")
	var t0 := b.tick
	b.cmd_wait(1)
	assert_eq(b.tick - t0, 3, "one player second = 0.3 world seconds")
	assert_eq(int(b.telegraphs[0]["fire_at"]), fire_at, "the warning keeps its time")
	var waited := 1
	while not b.telegraphs.is_empty() and waited < 30:
		b.cmd_wait(1)
		waited += 1
	assert_true(waited >= 9, "about 3x more player seconds before the blow (%d)" % waited)
	for i in 20:
		b.cmd_wait(1)
	assert_true(not b.slowed(), "the slow wears off")
	t0 = b.tick
	b.cmd_wait(1)
	assert_eq(b.tick - t0, Battle.TPS, "back to full speed")

## [가속] (x1.5): a 1-second action in the field takes 0.7 s, and the card shows it.
func test_haste_field_shortens_actions() -> void:
	var b := _battle("strike", "slow_hitter")
	var h := b.human()
	for p in [h.pos, h.pos + Vector2i.UP, h.pos + Vector2i.DOWN]:
		b.grid.add_state(p, "haste", 99.0)
	assert_eq(b.cost_secs(1), 0.7, "1-second card shows 0.7 s in the field")
	var t0 := b.tick
	assert_true(b.cmd_move(Vector2i.UP), "step in the field")
	assert_eq(b.tick - t0, 7, "the step took 0.7 s")
	var foe: Actor = b.actors[1]
	b.grid.add_state(foe.pos, "haste", 99.0)
	for i in 4:
		if not b.telegraphs.is_empty():
			break
		b.cmd_wait(1)
	assert_eq(int(b.telegraphs[0]["fire_at"]) - int(b.telegraphs[0]["set_at"]), 27, "a 4-second wind-up in the field takes 2.7 s")
	b._on_meta({"op": "slow", "factor": 3, "secs": 4}, h)
	assert_eq(b.cost_secs(1), 0.2, "and a third of that in bullet time")

func test_crystal_roots_and_shatters() -> void:
	var lay := {"player_pos": [1, 3], "enemy_pos": [[3, 3]], "materials": []}
	var b := _battle("crystallize", "idle", lay)
	var foe: Actor = b.actors[1]
	assert_true(b.cmd_play(0, foe.pos), "crystallize the foe")
	assert_true(foe.has_status("crystal"), "foe encased")
	assert_true(foe.rooted(), "encased foe cannot move")
	var hp0 := foe.hp
	var dealt := foe.take_damage(3, "true")
	assert_eq(dealt, 3 + Actor.CRYSTAL_BONUS, "hit shatters crystal for extra damage")
	assert_true(not foe.has_status("crystal"), "crystal gone")
	assert_eq(foe.hp, hp0 - dealt, "hp went down")
	assert_true(b.cmd_play(0, Vector2i(2, 1)), "crystallize empty cell")
	assert_eq(b.grid.get_material(Vector2i(2, 1)), "crystal", "a crystal grows on an empty cell")

func test_oil_on_fire_flares() -> void:
	var b := _battle("oil_spill")
	var aim := Vector2i(3, 3)
	b.grid.set_material(aim, "fire")
	assert_true(b.cmd_play(0, aim), "oil poured on fire")
	assert_eq(b.grid.get_material(aim), "fire", "the fire is not put out")
	assert_eq(b.grid.get_material(aim + Vector2i(1, 0)), "fire", "the spill around it catches at once")
