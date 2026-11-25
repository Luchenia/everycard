extends TestCase

var c: Catalog

func win(flow: RunFlow) -> void:
	for a in flow.battle.actors:
		if a.team == 1:
			a.hp = 0
	flow.battle.cmd_wait(10)
	flow.update()

func run() -> void:
	c = Catalog.load_dir("res://data")
	var f := RunFlow.new(c, 11)
	assert_eq(f.phase, "battle", "starts in battle")
	assert_eq(f.index, 0, "first battle")
	assert_eq(f.battle.actors.filter(func(a): return a.team == 1).size(), 2, "two slimes")
	win(f)
	assert_eq(f.phase, "reward", "reward after win")
	assert_eq(f.rewards.size(), 3, "3 reward choices")
	var g := RunFlow.new(c, 11)
	win(g)
	assert_eq(g.rewards, f.rewards, "same seed same rewards")
	var pick: String = f.rewards[1]
	var n := f.deck.size()
	f.choose_reward(1)
	assert_eq(f.deck.size(), n + 1, "deck grew")
	assert_true(f.deck.has(pick), "picked card in deck")
	assert_eq(f.phase, "battle", "next battle")
	assert_eq(f.index, 1, "second battle")
	assert_true(f.battle.human().deck.has(pick), "battle uses run deck")
	# loss
	var l := RunFlow.new(c, 12)
	l.battle.human().hp = 0
	l.battle.cmd_wait(10)
	l.update()
	assert_eq(l.phase, "game_over", "loss -> game over")
	# win after body swap: next battle uses the new body
	var s := RunFlow.new(c, 13)
	var b := s.battle
	var slime: Actor = b.actors.filter(func(a): return a.def_id == "slime")[0]
	var old_body := b.human()
	Effects.apply(Effects.card_def("body_swap", c), old_body, slime.pos, b.ctx)
	b._after_action()
	assert_true(b.human() == slime, "controlling slime")
	win(s)
	assert_eq(s.phase, "reward", "won as slime")
	s.choose_reward(0)
	assert_eq(s.battle.human().def_id, "slime", "next battle in the slime body")
	# full victory
	var v := RunFlow.new(c, 14)
	for i in 3:
		win(v)
		if v.phase == "reward":
			v.choose_reward(0)
	assert_eq(v.phase, "victory", "three wins -> victory")
