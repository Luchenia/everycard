extends TestCase
## A run: battles one after another, a card reward after each, the boss last.

var c: Catalog

func win(flow: RunFlow) -> void:
	for a in flow.battle.actors:
		if a.team == 1:
			a.hp = 0
	flow.battle.cmd_wait(1)
	flow.update()

func run() -> void:
	c = Catalog.load_dir("res://data")
	var f := RunFlow.new(c, 11)
	assert_eq(f.phase, "battle", "starts in a battle")
	assert_eq(f.index, 0, "the first battle")
	var foes := f.battle.actors.filter(func(a): return a.team == 1)
	assert_eq(foes.size(), RunFlow.FIGHTS[0]["enemies"].size(), "its monsters")
	assert_true(f.battle.human().pos.x < foes[0].pos.x, "player on the left, monsters on the right")
	win(f)
	assert_eq(f.phase, "reward", "reward after a win")
	var pick: String = f.rewards[1]
	var n := f.deck.size()
	f.choose_reward(1)
	assert_eq(f.deck.size(), n + 1, "deck grew")
	assert_eq(f.index, 1, "next battle")
	assert_eq(f.phase, "battle", "fighting again")
	assert_true(f.battle.human().deck.has(pick), "the new battle has the card")
	# hp carries over
	f.battle.human().hp = 20
	f.update()
	win(f)
	f.choose_reward(-1)
	assert_eq(f.battle.human().hp, 20, "hp carries over")
	assert_eq(f.battle.frames.size(), 1, "the new fight's replay starts from its first moment")
	assert_eq(int(f.battle.frames[0]["hp"][f.battle.human().uid]), 20, "...with the carried hp, not a full bar")
	f.battle.cmd_wait(1)
	assert_true(not f.battle.log.any(func(e): return e["t"] == "unknown"), "carried hp is not logged as an unknown hit")
	assert_eq(f.deck.size(), n + 1, "a reward can be skipped")
	# loss
	var l := RunFlow.new(c, 12)
	l.battle.human().hp = 0
	l.battle.cmd_wait(1)
	l.update()
	assert_eq(l.phase, "game_over", "loss -> game over")
	# body swap carries into the next battle
	var s := RunFlow.new(c, 13)
	var b := s.battle
	var foe: Actor = b.actors.filter(func(a): return a.team == 1)[0]
	Effects.apply(Effects.card_def("body_swap", c), b.human(), foe.pos, b.ctx)
	b._after_action()
	win(s)
	var kept := s.battle.human().def_id
	s.choose_reward(0)
	assert_eq(s.battle.human().def_id, kept, "next battle in the swapped body")
	# a chest on the board: a card mid-fight, then the fight goes on
	var ch: RunFlow = null
	var spot := Vector2i(-1, -1)
	for sd in range(15, 60):
		ch = RunFlow.new(c, sd)
		for p in ch.battle.grid.all_cells():
			if ch.battle.grid.get_material(p) == "chest":
				spot = p
		if spot.x >= 0:
			break
	assert_true(spot.x >= 0, "a chest on the board")
	ch.battle.grid.move_unit(ch.battle.human(), spot)
	ch.update()
	assert_eq(ch.phase, "reward", "the chest offers cards")
	var m := ch.deck.size()
	ch.choose_reward(0)
	assert_eq(ch.phase, "battle", "and the fight goes on")
	assert_eq(ch.index, 0, "in the same battle")
	assert_eq(ch.deck.size(), m + 1, "with the new card")
	assert_true(ch.battle.belt.ring().has(ch.deck[ch.deck.size() - 1]), "the card joins the ring")
	assert_eq(ch.battle.belt.ring().size(), ch.deck.size(), "every card once on the ring")
	assert_eq(ch.battle.grid.get_material(spot), "chest_open", "the chest stays open")
	var with_chest := 0
	for sd in range(1, 41):
		var rf := RunFlow.new(c, sd)
		if rf.battle.grid.all_cells().any(func(p): return rf.battle.grid.get_material(p) == "chest"):
			with_chest += 1
	assert_true(with_chest > 5 and with_chest < 35, "a chest in some battles, not all (%d of 40)" % with_chest)
	# no two of a card: rewards never offer one the deck has
	for id in ch.rewards:
		assert_true(not ch.deck.has(id), "reward not already in the deck")
	var seen := {}
	for id in RunFlow.new(c, 16).deck:
		assert_true(not seen.has(id), "starting deck has no copies: " + id)
		seen[id] = true
	# boss last
	var v := RunFlow.new(c, 14)
	v.start_battle(RunFlow.FIGHTS.size() - 1)
	assert_eq(v.battle.actors.filter(func(a): return a.team == 1)[0].def_id, "boss_tide_warden", "boss at the end")
	win(v)
	assert_eq(v.phase, "victory", "boss down -> victory")
