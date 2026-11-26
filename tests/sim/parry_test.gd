extends TestCase
## Timed-second parry (받아치기) and dodge (구르기): only the exact second a blow lands counts.

var c: Catalog

func _battle(lay: Dictionary, card := "parry") -> Battle:
	c.actors["p_" + card] = {"id": "p_" + card, "hp": 40, "mass": 2, "base_ability": "step1", "facing": [1, 0], "deck": [card, card, card, card, card, card]}
	return Battle.new(c, 1, "p_" + card, ["hitter"], lay)

func run() -> void:
	c = Catalog.load_dir("res://data")
	c.config = {"round_time": 10, "grid_w": 9, "grid_h": 7, "env_every": 99, "move_time": 1, "wheel_time": 1, "draws_per_round": 2}
	c.cards["slow_hit"] = {"id": "slow_hit", "time": 3, "weight": 1, "telegraph": true, "target": {"shape": "cell", "range": 9}, "parts": [{"op": "damage", "amount": 7, "kind": "true"}]}
	c.actors["hitter"] = {"id": "hitter", "hp": 30, "mass": 1, "deck": ["slow_hit"], "pattern": ["slow_hit"]}
	test_parry_on_time()
	test_parry_too_early()
	test_roll_on_time()

func _fire_at(b: Battle) -> int:
	for k in 5:
		if not b.telegraphs.is_empty():
			break
		b.cmd_wait(1)
	return int(b.telegraphs[0]["fire_at"]) if not b.telegraphs.is_empty() else -1

func _wait_until(b: Battle, sec: int) -> void:
	if sec - b.now > 0:
		b.cmd_wait(sec - b.now)

func test_parry_on_time() -> void:
	var b := _battle({"player_pos": [2, 3], "enemy_pos": [[6, 3]], "materials": []})
	var foe: Actor = b.actors[1]
	var at := _fire_at(b)
	assert_true(at > 0, "foe telegraphs")
	_wait_until(b, at - 1)
	var hp0 := b.human().hp
	var fhp := foe.hp
	assert_true(b.cmd_play(0, b.human().pos), "parry card")
	assert_eq(b.human().hp, hp0, "blow stopped")
	assert_eq(foe.hp, fhp - Actor.PARRY_DAMAGE, "damage returned")
	assert_true(foe.next_at >= b.now + 1, "attacker staggered")
	assert_true(b.log.any(func(e): return e["t"] == "parry"), "logged")

func test_parry_too_early() -> void:
	var b := _battle({"player_pos": [2, 3], "enemy_pos": [[6, 3]], "materials": []})
	var at := _fire_at(b)
	_wait_until(b, at - 2)
	var hp0 := b.human().hp
	b.cmd_play(0, b.human().pos)
	b.cmd_wait(1)
	assert_eq(b.human().hp, hp0 - 7, "a second early is a miss")

func test_roll_on_time() -> void:
	var b := _battle({"player_pos": [2, 3], "enemy_pos": [[6, 3]], "materials": []}, "roll")
	var at := _fire_at(b)
	_wait_until(b, at - 1)
	var hp0 := b.human().hp
	assert_true(b.cmd_play(0, Vector2i(2, 2)), "roll card")
	assert_eq(b.human().pos, Vector2i(2, 2), "rolled a cell")
	assert_eq(b.human().hp, hp0, "dodged")
	assert_eq(b.human().discount, 1, "next action a second faster")
