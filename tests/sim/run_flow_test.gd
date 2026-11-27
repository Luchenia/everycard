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
	# boss last
	var v := RunFlow.new(c, 14)
	v.start_battle(RunFlow.FIGHTS.size() - 1)
	assert_eq(v.battle.actors.filter(func(a): return a.team == 1)[0].def_id, "boss_tide_warden", "boss at the end")
	win(v)
	assert_eq(v.phase, "victory", "boss down -> victory")
