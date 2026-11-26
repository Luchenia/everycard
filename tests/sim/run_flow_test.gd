extends TestCase

var c: Catalog

func win(flow: RunFlow) -> void:
	for a in flow.battle.actors:
		if a.team == 1:
			a.hp = 0
	flow.battle.cmd_wait(1)
	flow.update()

## Puts the run in the first room of this kind, as if walked in through one of its doors.
func enter(flow: RunFlow, kind: String) -> void:
	for p in flow.dungeon.rooms:
		if flow.dungeon.rooms[p]["kind"] == kind:
			var d: Vector2i = flow.dungeon.doors(p)[0]
			flow.at = p
			flow._enter(-d)
			return

func step_on(flow: RunFlow, cell: Vector2i) -> void:
	var me := flow.battle.human()
	flow.battle.grid.move_unit(me, cell)
	flow.update()

func run() -> void:
	c = Catalog.load_dir("res://data")
	test_dungeon()
	var f := RunFlow.new(c, 11)
	assert_eq(f.phase, "battle", "starts in a room")
	assert_true(f.calm(), "start room is calm")
	assert_true(f.battle.phase == "player", "an empty room does not end")
	# a fight seals every door but the one you came in by
	enter(f, "fight")
	var foes := f.battle.actors.filter(func(a): return a.team == 1)
	assert_true(foes.size() >= 1, "monsters in a fight room")
	var sealed := 0
	for d in f.dungeon.doors(f.at):
		var m := f.battle.grid.get_material(RunFlow.door_cell(d, Grid.W, Grid.H))
		if m == "door_sealed":
			sealed += 1
		if d == -f.came_from:
			assert_eq(m, "door", "the way back stays open")
	assert_eq(sealed, f.dungeon.doors(f.at).size() - 1, "other doors sealed")
	win(f)
	assert_eq(f.phase, "reward", "reward after clearing")
	assert_true(f.gold > 0, "gold for the fight")
	for d in f.dungeon.doors(f.at):
		assert_eq(f.battle.grid.get_material(RunFlow.door_cell(d, Grid.W, Grid.H)), "door", "doors open when cleared")
	var pick: String = f.rewards[1]
	var n := f.deck.size()
	f.choose_reward(1)
	assert_eq(f.deck.size(), n + 1, "deck grew")
	assert_true(f.battle.human().deck.has(pick), "the room's hand gets the card")
	assert_eq(f.phase, "battle", "back to walking")
	# stepping on a door asks the screen to slide over
	var back: Vector2i = -f.came_from
	step_on(f, RunFlow.door_cell(back, Grid.W, Grid.H))
	assert_eq(f.exit_dir, back, "door step sets the exit")
	var from := f.at
	f.go(f.exit_dir)
	assert_eq(f.at, from + back, "moved to the next room")
	assert_eq(f.battle.human().pos, RunFlow.door_cell(-back, Grid.W, Grid.H) + back, "enters beside the door")
	test_flee()
	test_chest_shop_spring()
	# loss
	var l := RunFlow.new(c, 12)
	enter(l, "fight")
	l.battle.human().hp = 0
	l.battle.cmd_wait(1)
	l.update()
	assert_eq(l.phase, "game_over", "loss -> game over")
	# body swap carries into the next room
	var s := RunFlow.new(c, 13)
	enter(s, "fight")
	var b := s.battle
	var foe: Actor = b.actors.filter(func(a): return a.team == 1)[0]
	Effects.apply(Effects.card_def("body_swap", c), b.human(), foe.pos, b.ctx)
	b._after_action()
	win(s)
	s.choose_reward(0)
	var kept := s.battle.human().def_id
	s.go(-s.came_from)
	assert_eq(s.battle.human().def_id, kept, "next room in the swapped body")
	# boss
	var v := RunFlow.new(c, 14)
	enter(v, "boss")
	assert_eq(v.battle.actors.filter(func(a): return a.team == 1)[0].def_id, "boss_tide_warden", "boss waits in its room")
	win(v)
	assert_eq(v.phase, "victory", "boss down -> victory")

func test_dungeon() -> void:
	var d := Dungeon.new(5)
	var d2 := Dungeon.new(5)
	assert_eq(d.rooms.keys(), d2.rooms.keys(), "same seed same floor")
	assert_eq(d.rooms.size(), 10, "ten rooms")
	var kinds := {}
	for p in d.rooms:
		kinds[d.rooms[p]["kind"]] = kinds.get(d.rooms[p]["kind"], 0) + 1
		assert_true(d.doors(p).size() <= 4 and d.doors(p).size() >= 1, "1 to 4 doors")
	for k in ["start", "boss", "chest", "shop", "spring", "fight"]:
		assert_true(kinds.has(k), "floor has a " + k)
	assert_eq(d.doors(d.boss_at).size(), 1, "boss room is a dead end")
	# every room reachable
	var seen := {d.start: true}
	var q := [d.start]
	while not q.is_empty():
		var p: Vector2i = q.pop_back()
		for dd in d.doors(p):
			if not seen.has(p + dd):
				seen[p + dd] = true
				q.append(p + dd)
	assert_eq(seen.size(), d.rooms.size(), "all rooms connected")

func test_flee() -> void:
	var f := RunFlow.new(c, 21)
	enter(f, "fight")
	var foe: Actor = f.battle.actors.filter(func(a): return a.team == 1)[0]
	foe.hp = 3
	var room := f.at
	var back: Vector2i = -f.came_from
	f.go(back)
	assert_true(not f.dungeon.rooms[room]["cleared"], "fled room is not cleared")
	f.go(-back)
	var again: Actor = f.battle.actors.filter(func(a): return a.team == 1 and a.def_id == foe.def_id)[0]
	assert_eq(again.hp, 3, "the wounded monster is still wounded")

func test_chest_shop_spring() -> void:
	var f := RunFlow.new(c, 31)
	var mid := Vector2i(Grid.W / 2, Grid.H / 2)
	enter(f, "chest")
	var g0 := f.gold
	step_on(f, mid)
	assert_eq(f.phase, "reward", "chest gives a card choice")
	assert_true(f.gold > g0, "and gold")
	f.choose_reward(-1)
	assert_eq(f.phase, "battle", "a reward can be skipped")
	step_on(f, mid + Vector2i.RIGHT); step_on(f, mid)
	assert_eq(f.phase, "battle", "an opened chest stays empty")
	enter(f, "shop")
	f.gold = 500
	step_on(f, mid)
	assert_eq(f.phase, "shop", "stall opens the shop")
	assert_eq(f.stock().size(), 4, "four cards for sale")
	var n := f.deck.size()
	assert_true(f.buy(0), "bought")
	assert_true(not f.buy(0), "sold out")
	assert_eq(f.deck.size(), n + 1, "bought card in deck")
	f.leave_shop()
	assert_eq(f.phase, "battle", "left the shop")
	enter(f, "spring")
	f.battle.human().hp = 10
	step_on(f, mid)
	assert_true(f.battle.human().hp > 10, "spring heals")
