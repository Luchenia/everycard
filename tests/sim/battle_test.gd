extends TestCase
## Timeline battle: one shared clock, actions cost seconds, enemies act on the same clock.

var c: Catalog

func setup_catalog() -> void:
	c = Catalog.load_dir("res://data")
	c.config = {"round_time": 10, "grid_w": 9, "grid_h": 7, "env_every": 2, "move_time": 1, "wheel_time": 1, "draws_per_round": 2}
	c.cards["t3"] = {"id": "t3", "time": 3, "weight": 1, "rarity": "common", "target": {"shape": "cell", "range": 9}, "parts": [{"op": "damage", "amount": 3, "kind": "true"}]}
	c.cards["tx"] = {"id": "tx", "time": 1, "exhaust": 3, "weight": 1, "rarity": "common", "target": {"shape": "cell", "range": 9}, "parts": [{"op": "damage", "amount": 1, "kind": "true"}]}
	c.cards["bite"] = {"id": "bite", "time": 2, "weight": 1, "telegraph": true, "target": {"shape": "cell", "range": 9}, "parts": [{"op": "damage", "amount": 10, "kind": "true"}]}
	c.cards["slam"] = {"id": "slam", "time": 2, "weight": 1, "telegraph": true, "target": {"shape": "circle", "range": 9, "size": 1}, "parts": [{"op": "damage", "amount": 10, "kind": "true"}]}
	c.cards["quake"] = {"id": "quake", "time": 3, "weight": 1, "telegraph": true, "safe": 3, "target": {"shape": "all", "range": 0}, "parts": [{"op": "damage", "amount": 10, "kind": "true"}]}
	c.cards["snipe"] = {"id": "snipe", "time": 3, "weight": 1, "telegraph": true, "track": true, "target": {"shape": "cell", "range": 9}, "parts": [{"op": "damage", "amount": 10, "kind": "true"}]}
	c.cards["swap"] = {"id": "swap", "time": 2, "weight": 1, "rarity": "epic", "target": {"shape": "cell", "range": 9}, "parts": [{"op": "swap_bodies"}]}
	c.cards["kill"] = {"id": "kill", "time": 1, "weight": 1, "rarity": "epic", "target": {"shape": "cell", "range": 9}, "parts": [{"op": "damage", "amount": 999, "kind": "true"}]}
	c.actors["hero"] = {"id": "hero", "hp": 40, "mass": 2, "base_ability": "step1", "deck": ["t3", "t3", "t3", "t3", "t3", "t3", "t3", "t3", "t3"]}
	c.actors["hero_x"] = {"id": "hero_x", "hp": 40, "mass": 2, "base_ability": "step1", "deck": ["tx", "tx", "tx", "tx", "tx"]}
	c.actors["idle"] = {"id": "idle", "hp": 30, "mass": 1, "deck": [], "pattern": []}
	c.actors["biter"] = {"id": "biter", "hp": 30, "mass": 1, "deck": ["bite"], "pattern": ["bite"]}
	c.actors["slammer"] = {"id": "slammer", "hp": 30, "mass": 1, "deck": ["slam"], "pattern": ["slam"]}
	c.actors["quaker"] = {"id": "quaker", "hp": 30, "mass": 1, "deck": ["quake"], "pattern": ["quake"]}
	c.actors["sniper"] = {"id": "sniper", "hp": 30, "mass": 1, "deck": ["snipe"], "pattern": ["snipe"]}
	c.actors["swapper"] = {"id": "swapper", "hp": 40, "mass": 2, "base_ability": "step1", "deck": ["swap", "swap", "swap", "swap", "swap", "swap"]}
	c.actors["dummy_killer"] = {"id": "dummy_killer", "hp": 20, "mass": 1, "deck": ["kill", "kill", "kill", "kill", "kill"], "pattern": ["noop"]}
	c.cards["noop"] = {"id": "noop", "time": 5, "weight": 1, "target": {"shape": "self"}, "parts": []}

const LAYOUT := {"player_pos": [1, 3], "enemy_pos": [[7, 3]], "materials": []}

func run() -> void:
	setup_catalog()
	test_move_costs_one_second()
	test_card_time_advances_clock()
	test_slow_cell_doubles_duration()
	test_frozen_player_can_wait()
	test_round_boundary_draws()
	test_die_during_windup_no_effect()
	test_exhaust_passes_time()
	test_telegraph_fires_after_card_time()
	test_move_dodges_one_tile_attack()
	test_area_attack_needs_two_moves()
	test_safe_zone_leaves_safe_cells()
	test_tracking_locks_one_second_before()
	test_frozen_enemy_delays_telegraph()
	test_pattern_index_only_on_use()
	test_body_swap_and_win()
	test_determinism()
	test_preview_restores()
	test_gained_card_drawn_next()
	test_time_budget_delays_foes()
	test_config_grid_size()
	test_review_fixes()

func test_move_costs_one_second() -> void:
	var b := Battle.new(c, 1, "hero", ["idle"], LAYOUT)
	assert_true(b.cmd_move(Vector2i.UP), "move")
	assert_eq(b.now, 1, "move costs 1 second")
	assert_eq(b.human().pos, Vector2i(1, 2), "moved up")
	assert_true(b.cmd_move(Vector2i.UP), "can keep moving while time allows")
	assert_eq(b.now, 2, "second move another second")

func test_card_time_advances_clock() -> void:
	var b := Battle.new(c, 1, "hero", ["idle"], LAYOUT)
	var foe: Actor = b.actors[1]
	assert_true(b.cmd_play(0, foe.pos), "play t3")
	assert_eq(b.now, 3, "3-second card advances 3 seconds")
	assert_eq(foe.hp, 27, "effect landed")
	assert_true(not b.cmd_play(0, Vector2i(30, 30)), "out of range rejected")
	assert_eq(b.now, 3, "rejected play costs nothing")

func test_slow_cell_doubles_duration() -> void:
	var b := Battle.new(c, 1, "hero", ["idle"], LAYOUT)
	b.grid.set_var(b.human().pos, "time_scale", 0.5)
	assert_eq(b.action_secs(1, b.human()), 2, "half speed: 1s action takes 2s")
	b.cmd_move(Vector2i.UP)
	assert_eq(b.now, 2, "slow move took 2 seconds")

func test_frozen_player_can_wait() -> void:
	var b := Battle.new(c, 1, "hero", ["idle"], LAYOUT)
	b.grid.set_var(b.human().pos, "time_scale", 0.0)
	assert_true(not b.cmd_move(Vector2i.UP), "frozen player cannot move")
	assert_true(not b.cmd_play(0, b.actors[1].pos), "frozen player cannot play")
	assert_true(b.cmd_wait(), "but can wait")
	assert_eq(b.now, 1, "waiting passes time")

func test_round_boundary_draws() -> void:
	var b := Battle.new(c, 1, "hero", ["idle"], LAYOUT)
	b.cmd_play(0, b.actors[1].pos)
	b.cmd_play(1, b.actors[1].pos)
	assert_eq(b.belt.slots.count(null), 0, "used slots refill straight away")
	assert_eq(b.next_draw_at(), 10, "next draw at 10s")
	assert_eq(b.frames.size(), 7, "one replay frame per passed second plus the start")
	assert_eq(b.frames[-1]["t"], 6, "last frame at the current second")

func test_die_during_windup_no_effect() -> void:
	var b := Battle.new(c, 1, "hero", ["biter"], LAYOUT)
	var foe: Actor = b.actors[1]
	# biter telegraphs at 1s and fires at 3s
	b.human().hp = 5
	b.cmd_wait(1)
	assert_eq(b.telegraphs.size(), 1, "enemy telegraphed at 1s")
	var hp := foe.hp
	b.cmd_play(0, foe.pos)   # wind-up 1s..4s; the bite lands at 3s
	assert_eq(b.phase, "lost", "player died during wind-up")
	assert_eq(foe.hp, hp, "effect never landed")

func test_exhaust_passes_time() -> void:
	var b := Battle.new(c, 1, "hero_x", ["idle"], LAYOUT)
	b.cmd_play(0, b.actors[1].pos)
	assert_eq(b.now, 4, "1s card + 3s exhaustion")

func test_telegraph_fires_after_card_time() -> void:
	var b := Battle.new(c, 1, "hero", ["biter"], LAYOUT)
	var p := b.human()
	b.cmd_wait(1)
	assert_eq(b.telegraphs.size(), 1, "telegraph posted at 1s")
	assert_eq(b.telegraphs[0]["fire_at"], 3, "fires 2s later")
	b.cmd_wait(1)
	assert_eq(p.hp, 40, "not yet")
	b.cmd_wait(1)
	assert_eq(p.hp, 30, "hit at 3s")

func test_move_dodges_one_tile_attack() -> void:
	var b := Battle.new(c, 1, "hero", ["biter"], LAYOUT)
	var p := b.human()
	b.cmd_wait(2)
	b.cmd_move(Vector2i.UP)   # finishes at 3s, before the bite resolves
	assert_eq(p.hp, 40, "one move dodges a one-tile attack, even on the last second")

func test_area_attack_needs_two_moves() -> void:
	var b := Battle.new(c, 1, "hero", ["slammer"], LAYOUT)
	var p := b.human()
	b.cmd_wait(2)
	b.cmd_move(Vector2i.UP)
	assert_eq(p.hp, 30, "one move is not enough to leave a 3x3")
	var b2 := Battle.new(c, 1, "hero", ["slammer"], LAYOUT)
	b2.cmd_wait(1)
	b2.cmd_move(Vector2i.UP)
	b2.cmd_move(Vector2i.UP)
	assert_eq(b2.human().hp, 40, "two moves leave the 3x3")

func test_safe_zone_leaves_safe_cells() -> void:
	var b := Battle.new(c, 1, "hero", ["quaker"], LAYOUT)
	b.cmd_wait(1)
	var t: Dictionary = b.telegraphs[0]
	var total := Grid.W * Grid.H
	assert_true(t["cells"].size() <= total - 3 and t["cells"].size() >= total - 4, "all but the safe cells (and the attacker)")
	var safe_near := false
	for x in Grid.W:
		for y in Grid.H:
			var q := Vector2i(x, y)
			if not t["cells"].has(q) and Battle.dist(q, b.human().pos) <= 2 and q != b.human().pos:
				safe_near = true
	assert_true(safe_near, "a safe cell within two moves of the target")

func test_tracking_locks_one_second_before() -> void:
	var b := Battle.new(c, 1, "hero", ["sniper"], LAYOUT)
	var p := b.human()
	b.cmd_wait(1)                 # telegraph at 1s, fires at 4s
	b.cmd_move(Vector2i.UP)       # 2s: still tracking
	assert_eq(b.telegraphs[0]["aim"], p.pos, "aim follows the target")
	b.cmd_move(Vector2i.UP)       # 3s: aim updates one last time, then locks
	var locked: Vector2i = b.telegraphs[0]["aim"]
	assert_eq(locked, p.pos, "locked on the 3s position")
	b.cmd_move(Vector2i.UP)       # 4s: moves first, then the shot lands on the locked cell
	assert_eq(p.hp, 40, "moving in the final second dodges the locked shot")

func test_frozen_enemy_delays_telegraph() -> void:
	var b := Battle.new(c, 1, "hero", ["biter"], LAYOUT)
	b.cmd_wait(1)
	Effects.apply(Effects.card_def("stasis", c), b.human(), b.actors[1].pos, b.ctx)
	b.cmd_wait(2)
	assert_eq(b.human().hp, 40, "frozen attacker's telegraph waits")
	assert_eq(b.telegraphs.size(), 1, "telegraph still pending")

func test_pattern_index_only_on_use() -> void:
	var lay := {"player_pos": [0, 3], "enemy_pos": [[8, 3]], "materials": []}
	c.cards["near"] = {"id": "near", "time": 1, "weight": 1, "target": {"shape": "cell", "range": 1}, "parts": []}
	c.actors["walker2"] = {"id": "walker2", "hp": 10, "mass": 1, "deck": ["near"], "pattern": ["near"]}
	var b := Battle.new(c, 1, "hero", ["walker2"], lay)
	b.cmd_wait(2)
	assert_eq(b.actors[1].pattern_index, 0, "approaching does not use up the pattern")

func test_body_swap_and_win() -> void:
	var w := Battle.new(c, 5, "swapper", ["dummy_killer"], LAYOUT)
	var old_body: Actor = w.human()
	var target: Actor = w.actors[1]
	assert_true(w.cmd_play(0, target.pos), "swap played")
	assert_true(w.human() == target, "now controlling the enemy body")
	assert_eq(w.belt.slots[0]["card_id"], "kill", "hand rebuilt from new body's deck")
	assert_true(w.cmd_play(0, old_body.pos), "attack old body")
	assert_eq(w.phase, "won", "defeating old body wins")

func _scripted(seed_value: int) -> Array:
	var b := Battle.new(c, seed_value, "hero", ["slammer", "biter"], {})
	b.cmd_play(0, b.actors[1].pos)
	b.cmd_move(Vector2i.DOWN)
	b.cmd_wheel(1)
	b.cmd_play(1, b.actors[1].pos)
	b.cmd_wait(5)
	return [b.now, b.grid.duplicate_state()["values"], b.grid.material, b.actors.map(func(a): return [a.hp, a.pos])]

func test_determinism() -> void:
	assert_eq(_scripted(7), _scripted(7), "same seed + same commands -> same result")

func test_preview_restores() -> void:
	var pv := Battle.new(c, 4, "hero", ["idle"], LAYOUT)
	var fhp: int = pv.actors[1].hp
	var info := pv.preview(0, pv.actors[1].pos)
	assert_true(info["damage_by_uid"].get(pv.actors[1].uid, 0) > 0, "preview predicts damage")
	assert_eq(info["secs"], 3, "preview shows seconds")
	assert_eq(pv.actors[1].hp, fhp, "preview restored hp")
	assert_eq(pv.now, 0, "preview does not advance time")

func test_gained_card_drawn_next() -> void:
	var cf := Battle.new(c, 13, "hero", ["idle"], LAYOUT)
	var d: Actor = cf.actors[1]
	d.hp = 1
	cf.grid.move_unit(d, cf.human().pos + Vector2i(1, 0))
	c.actors["idle"]["signature"] = "t3"
	Effects.apply({"target": {"shape": "cell"}, "parts": [{"op": "cardify"}]}, cf.human(), d.pos, cf.ctx)
	assert_eq(cf.belt.preview(), "foe:idle", "cardified enemy is the next card drawn")

func test_time_budget_delays_foes() -> void:
	var b := Battle.new(c, 1, "hero", ["biter"], LAYOUT)
	b.cmd_wait(1)
	Effects.apply({"target": {"shape": "self"}, "parts": [{"op": "time_budget", "delta": 3}]}, b.human(), b.human().pos, b.ctx)
	assert_eq(b.telegraphs[0]["fire_at"], 6, "telegraph pushed back 3 seconds")

func test_config_grid_size() -> void:
	var c2 := Catalog.load_dir("res://data")
	c2.config = {"grid_w": 12, "grid_h": 8, "round_time": 8}
	var b := Battle.new(c2, 1, "walker", ["slime"], {})
	assert_eq(b.grid.material.size(), 96, "grid follows config")
	assert_eq(b.next_draw_at(), 8, "round length follows config")
	Grid.W = 9
	Grid.H = 7

func test_review_fixes() -> void:
	# telegraph kill on an odd second (no env step) ends the battle
	var b := Battle.new(c, 1, "hero", ["biter"], LAYOUT)
	b.human().hp = 5
	b.cmd_wait(1)
	b.cmd_wait(2)   # bite fires at 3s
	assert_eq(b.phase, "lost", "telegraph kill ends the battle")
	# an action winding up is cancelled if control moved to another body meanwhile
	var w2 := Battle.new(c, 3, "hero", ["idle"], LAYOUT)
	var f2: Actor = w2.actors[1]
	w2.human().pattern = ["noop"]   # the left-behind body idles once it becomes AI
	w2.cmd_play(0, f2.pos)          # 0s -> 3s
	var hp2 := f2.hp
	var s0 := w2.belt.slots.find_custom(func(x): return x != null)
	# swap control in the middle of the wind-up through a delayed swap
	w2.ctx.pending.append({"mode": "delay", "ticks": 1, "part": {"op": "swap_bodies"}, "user": w2.human(), "aim": f2.pos, "cells": [f2.pos]})
	w2.cmd_play(s0, f2.pos)
	assert_true(w2.human() == f2, "control moved mid wind-up")
	assert_eq(f2.hp, hp2, "the old body's card did not land")
	# rolling with an empty draw pile does not hand back the dropped card
	var r := HandBelt.new(["strike", "guard", "step", "frost", "spark"], SimRng.new(1), c, 5, false)
	r.discard = []
	assert_eq(r.roll(1), "spark", "dropped spark")
	assert_true(not r.slots.map(func(x): return x["card_id"] if x else "").has("spark"), "spark not drawn straight back")
