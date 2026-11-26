extends TestCase
## 결정 rules: a crystal is a wall; physical blows break it and the shards hurt everything around;
## light and magic glance off in a random direction. A crystallized unit counts as a crystal.

var c: Catalog

func _battle(card_id: String, lay: Dictionary) -> Battle:
	c.actors["p_" + card_id] = {"id": "p_" + card_id, "hp": 40, "mass": 2, "base_ability": "step1",
		"deck": [card_id, card_id, card_id, card_id, card_id, card_id, card_id]}
	return Battle.new(c, 1, "p_" + card_id, ["idle", "idle"], lay)

func run() -> void:
	c = Catalog.load_dir("res://data")
	c.config = {"round_time": 10, "grid_w": 9, "grid_h": 7, "env_every": 2, "move_time": 1, "wheel_time": 1, "draws_per_round": 2}
	c.actors["idle"] = {"id": "idle", "hp": 30, "mass": 1, "deck": [], "pattern": []}
	c.cards["bolt"] = {"id": "bolt", "time": 1, "weight": 1, "target": {"shape": "cell", "range": 9}, "parts": [{"op": "damage", "amount": 5, "kind": "electric"}]}
	test_crystal_is_a_wall()
	test_blow_breaks_crystal_and_shards_hit_neighbours()
	test_light_glances_off_crystal()
	test_crystallized_unit_counts_as_crystal()

func test_crystal_is_a_wall() -> void:
	var b := _battle("strike", {"player_pos": [1, 3], "enemy_pos": [[7, 1], [7, 5]], "materials": []})
	b.grid.set_material(Vector2i(2, 3), "crystal")
	assert_true(not b.grid.passable(Vector2i(2, 3)), "crystal blocks like a wall")
	var h := b.human()
	b.cmd_move(Vector2i.RIGHT)
	assert_eq(h.pos, Vector2i(1, 3), "cannot walk into a crystal")

func test_blow_breaks_crystal_and_shards_hit_neighbours() -> void:
	var b := _battle("strike", {"player_pos": [1, 3], "enemy_pos": [[3, 3], [7, 5]], "materials": []})
	var foe: Actor = b.actors[1]
	b.grid.set_material(Vector2i(2, 3), "crystal")
	var hp0 := foe.hp
	var me0 := b.human().hp
	assert_true(b.cmd_play(0, Vector2i(2, 3)), "strike the crystal")
	assert_eq(b.grid.get_material(Vector2i(2, 3)), "none", "crystal broken")
	assert_eq(foe.hp, hp0 - Actor.SHARD_DAMAGE, "shards hit the foe next to it")
	assert_eq(b.human().hp, me0 - Actor.SHARD_DAMAGE, "and the striker too")

func test_light_glances_off_crystal() -> void:
	var b := _battle("laser", {"player_pos": [1, 3], "enemy_pos": [[7, 3], [7, 6]], "materials": []})
	var foe: Actor = b.actors[1]
	b.grid.set_material(Vector2i(4, 3), "crystal")
	var hp0 := foe.hp
	assert_true(b.cmd_play(0, Vector2i(7, 3)), "fire the beam")
	assert_eq(foe.hp, hp0, "the beam never reaches the foe behind the crystal")
	assert_eq(b.grid.get_material(Vector2i(4, 3)), "crystal", "light does not break crystal")
	var path: Array = []
	for e in b.log:
		if e["t"] == "beam":
			path = e["data"]["path"]
	assert_true(path.size() >= 3, "beam goes on")
	var last: Vector2i = path[path.size() - 1]
	assert_true(last.y != 3, "turned off its line")

func test_crystallized_unit_counts_as_crystal() -> void:
	var b := _battle("crystallize", {"player_pos": [1, 3], "enemy_pos": [[3, 3], [4, 3]], "materials": []})
	var foe: Actor = b.actors[1]
	var other: Actor = b.actors[2]
	assert_true(b.cmd_play(0, foe.pos), "crystallize the foe")
	assert_true(foe.has_status("crystal") and foe.rooted(), "bound")
	assert_eq(foe.take_damage(5, "electric"), 0, "magic glances off")
	assert_eq(foe.take_damage(5, "energy"), 0, "light glances off")
	var o0 := other.hp
	var hp0 := foe.hp
	b.ctx.now = b.now
	Effects.apply_part({"op": "damage", "amount": 3, "kind": "physical"}, b.human(), foe.pos, [foe.pos], b.ctx)
	assert_eq(foe.hp, hp0 - 3 - Actor.CRYSTAL_BONUS, "a blow breaks it for extra damage")
	assert_true(not foe.has_status("crystal"), "crystal gone")
	assert_eq(other.hp, o0 - Actor.SHARD_DAMAGE, "shards hit the neighbour")
