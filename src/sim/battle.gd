class_name Battle
extends RefCounted
## One fight: turn order, time budget, flowing hand, enemy telegraphs, win/lose.
## Player turn -> environment step -> enemy turn (resolve telegraphs, act) -> environment step.

const TURN_TIME := 10
const HOLD_COST := 2

var catalog: Catalog
var rng: SimRng
var grid: Grid
var ctx: Effects.BattleContext
var actors: Array = []
var belt: HandBelt
var belt_owner: Actor
var time_left := TURN_TIME
var phase := "player"
var telegraphs: Array = []
var log: Array = []
var turn := 1
var _moved := false
var _ability_used := false

func _init(cat: Catalog, seed_value: int, player_def: String, enemy_defs: Array, layout: Dictionary = {}) -> void:
	catalog = cat
	rng = SimRng.new(seed_value)
	grid = Grid.new(catalog)
	ctx = Effects.BattleContext.new()
	ctx.grid = grid
	ctx.catalog = catalog
	ctx.rng = rng
	ctx.log = log
	ctx.actors = actors
	ctx.on_meta = _on_meta
	var lay := layout if not layout.is_empty() else _random_layout(enemy_defs.size())
	for m in lay.get("materials", []):
		grid.set_material(Vector2i(m[0], m[1]), m[2])
	for v in lay.get("vars", []):
		grid.set_var(Vector2i(v[0], v[1]), v[2], v[3])
	var pl := Actor.from_def(catalog.actors[player_def], 1)
	pl.team = 0
	pl.controller = "human"
	_spawn(pl, Vector2i(lay["player_pos"][0], lay["player_pos"][1]))
	var uid := 2
	for i in enemy_defs.size():
		var e := Actor.from_def(catalog.actors[enemy_defs[i]], uid)
		uid += 1
		var ep: Array = lay["enemy_pos"][i] if i < lay["enemy_pos"].size() else [7, i]
		_spawn(e, Vector2i(ep[0], ep[1]))
	ctx.next_uid = 100
	_rebuild_belt()

func _spawn(a: Actor, p: Vector2i) -> void:
	if not grid.place_unit(a, p):
		grid.set_material(p, "none")
		grid.place_unit(a, p)
	actors.append(a)

func _random_layout(n_enemies: int) -> Dictionary:
	var player := [1, 3]
	var enemies := []
	for i in n_enemies:
		enemies.append([7, [3, 1, 5, 2, 4][i % 5]])
	var reserved := [Vector2i(1, 3)]
	for e in enemies:
		reserved.append(Vector2i(e[0], e[1]))
	var mats := []
	var pool := ["water", "water", "oil", "wall", "crystal", "ice"]
	for k in 7:
		var p := Vector2i(2 + rng.next_int(5), rng.next_int(Grid.H))
		if reserved.has(p):
			continue
		mats.append([p.x, p.y, pool[rng.next_int(pool.size())]])
	return {"player_pos": player, "enemy_pos": enemies, "materials": mats}

func human() -> Actor:
	for a in actors:
		if a.controller == "human" and a.alive():
			return a
	return null

func _rebuild_belt() -> void:
	belt_owner = human()
	if belt_owner != null:
		belt = HandBelt.new(belt_owner.deck, rng, catalog)

func _on_meta(part: Dictionary, user) -> void:
	if user != human():
		return
	match part["op"]:
		"time_budget":
			time_left = max(0, time_left + int(part.get("delta", 0)))
		"belt":
			match part.get("action", "freeze"):
				"freeze": belt.hold()
				"advance":
					for i in int(part.get("amount", 1)):
						belt.flush()
				"reverse": belt.reverse_next = true

static func dist(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)

func _ts(p: Vector2i) -> float:
	return float(grid.get_var(p, "time_scale"))

# ---- player commands -------------------------------------------------------

func cmd_move(dir: Vector2i) -> bool:
	var h := human()
	if phase != "player" or h == null or _moved or h.base_ability != "step1":
		return false
	var to: Vector2i = h.pos + dir
	if absi(dir.x) + absi(dir.y) != 1 or not grid.passable(to) or grid.unit_at(to) != null:
		return false
	grid.move_unit(h, to)
	_moved = true
	if grid.mat_def(to).get("lethal", false):
		h.hp = 0
	_log("move", "%s 이동" % h.name, {"to": to})
	_check_end()
	return true

func cmd_ability(aim: Vector2i) -> bool:
	var h := human()
	if phase != "player" or h == null or _ability_used:
		return false
	match h.base_ability:
		"heat_self":
			grid.add_var(h.pos, "temperature", 60)
			for n in grid.neighbors4(h.pos):
				grid.add_var(n, "temperature", 30)
		"pull1":
			var u = grid.unit_at(aim)
			if u == null or dist(aim, h.pos) != 1 and dist(aim, h.pos) != 2:
				return false
			EnvironmentStep.push_unit(grid, u, -Targeting.dir_to(h.pos, aim), 1, log)
		"belt1":
			belt.flush()
		_:
			return false
	_ability_used = true
	_log("ability", "%s 기본 능력" % h.name, {"ability": h.base_ability})
	_check_end()
	return true

func can_play(slot: int, aim: Vector2i) -> bool:
	var h := human()
	if phase != "player" or h == null or belt == null or slot < 0 or slot >= belt.slots.size() or belt.slots[slot] == null:
		return false
	var card := Effects.card_def(belt.slots[slot]["card_id"], catalog)
	if card.is_empty() or int(card.get("time", 0)) > time_left:
		return false
	var shape: String = card.get("target", {}).get("shape", "cell")
	if shape != "self" and shape != "all":
		if not grid.in_bounds(aim) or dist(h.pos, aim) > int(card.get("target", {}).get("range", 1)):
			return false
	return true

func cmd_play(slot: int, aim: Vector2i) -> bool:
	if not can_play(slot, aim):
		return false
	var h := human()
	var id := belt.take(slot)
	var card := Effects.card_def(id, catalog)
	time_left -= int(card.get("time", 0))
	_log("play", "%s: %s" % [h.name, card.get("name", id)], {"card": id, "aim": aim})
	Effects.apply(card, h, aim, ctx)
	_after_action()
	return true

func cmd_hold() -> bool:
	if phase != "player" or time_left < HOLD_COST:
		return false
	time_left -= HOLD_COST
	belt.hold()
	_log("hold", "손패 붙잡기", {})
	return true

func cmd_flush() -> bool:
	if phase != "player":
		return false
	belt.flush()
	_log("flush", "손패 흘려보내기", {})
	return true

func cmd_end_turn() -> void:
	if phase != "player":
		return
	var h := human()
	if h != null and belt != null:
		belt.end_turn(_ts(h.pos))
	_env()
	if _check_end():
		return
	phase = "enemy"
	_enemy_turn()
	if phase == "enemy":
		_env()
	if _check_end():
		return
	phase = "player"
	turn += 1
	_moved = false
	_ability_used = false
	h = human()
	time_left = int(round(TURN_TIME * _ts(h.pos)))

# ---- internals ---------------------------------------------------------------

func _env() -> void:
	EnvironmentStep.run(grid, catalog, rng, log)
	Effects.tick_pending(ctx)
	_cleanup()

func _enemy_turn() -> void:
	var due := telegraphs
	telegraphs = []
	for t in due:
		var a: Actor = _actor(t["actor_uid"])
		if a == null or not a.alive() or a.controller != "ai":
			continue
		_log("telegraph_hit", "%s 예고 공격" % a.name, {"cells": t["cells"]})
		Effects.apply(Effects.card_def(t["card_id"], catalog), a, t["aim"], ctx)
	_cleanup()
	for a in actors.duplicate():
		if phase != "enemy":
			return
		if a.controller != "ai" or not a.alive() or not grid.units.has(a):
			continue
		_ai_act(a)
		_after_action()

func _ai_act(a: Actor) -> void:
	var choice := EnemyAI.choose(a, self)
	if choice.is_empty():
		return
	var card := Effects.card_def(choice["card_id"], catalog)
	var rng_range := int(card.get("target", {}).get("range", 1))
	var aim: Vector2i = choice["aim"]
	if card.get("target", {}).get("shape", "cell") != "self" and dist(a.pos, aim) > rng_range:
		_ai_step_toward(a, aim)
		if dist(a.pos, aim) > rng_range:
			_log("wait", "%s 접근" % a.name, {})
			return
	if card.get("telegraph", false):
		var cells := Targeting.cells(card.get("target", {}).get("shape", "cell"), a.pos, aim, int(card.get("target", {}).get("size", 0)))
		telegraphs.append({"actor_uid": a.uid, "cells": cells, "card_id": choice["card_id"], "aim": aim})
		_log("telegraph", "%s: %s 예고" % [a.name, card.get("name", choice["card_id"])], {"cells": cells})
	else:
		_log("play", "%s: %s" % [a.name, card.get("name", choice["card_id"])], {"card": choice["card_id"], "aim": aim})
		Effects.apply(card, a, aim, ctx)

func _ai_step_toward(a: Actor, target: Vector2i) -> void:
	var best := a.pos
	var best_d := dist(a.pos, target)
	for n in grid.neighbors4(a.pos):
		if grid.passable(n) and grid.unit_at(n) == null and not grid.mat_def(n).get("lethal", false) and dist(n, target) < best_d:
			best = n
			best_d = dist(n, target)
	if best != a.pos:
		grid.move_unit(a, best)

func _actor(uid: int) -> Actor:
	for a in actors:
		if a.uid == uid:
			return a
	return null

func _cleanup() -> void:
	for a in actors:
		if not a.alive() and grid.units.has(a):
			grid.remove_unit(a)
			_log("death", "%s 쓰러짐" % a.name, {"uid": a.uid})

func _after_action() -> void:
	_cleanup()
	if human() != belt_owner and human() != null:
		_rebuild_belt()
	_check_end()

func _check_end() -> bool:
	if phase == "won" or phase == "lost":
		return true
	if human() == null:
		phase = "lost"
		return true
	var foes := actors.filter(func(a): return a.alive() and a.team == 1 and grid.units.has(a))
	if foes.is_empty():
		phase = "won"
		return true
	return false

func _log(t: String, msg: String, data: Dictionary) -> void:
	log.append({"t": t, "msg": msg, "data": data})

## Simulates playing a card without changing anything. Environment step not included.
func preview(slot: int, aim: Vector2i) -> Dictionary:
	if not can_play(slot, aim):
		return {"cells": [], "damage_by_uid": {}, "moved_by_uid": {}}
	var h := human()
	var card := Effects.card_def(belt.slots[slot]["card_id"], catalog)
	var gsnap := grid.duplicate_state()
	var asnap := actors.map(func(a): return [a, a.hp, a.statuses.duplicate(), a.deck.duplicate(), a.controller, a.team])
	var rstate = rng.get_state()
	var tmp := Effects.BattleContext.new()
	tmp.grid = grid
	tmp.catalog = catalog
	tmp.rng = rng
	tmp.actors = actors.duplicate()
	tmp.next_uid = ctx.next_uid
	var before := {}
	for a in actors:
		before[a.uid] = [a.hp, a.pos]
	Effects.apply(card, h, aim, tmp)
	var dmg := {}
	var moved := {}
	for a in actors:
		if a.hp < before[a.uid][0]:
			dmg[a.uid] = before[a.uid][0] - a.hp
		if a.pos != before[a.uid][1]:
			moved[a.uid] = a.pos
	var shape: String = card.get("target", {}).get("shape", "cell")
	var cells := Targeting.cells(shape, h.pos if not moved.has(h.uid) else before[h.uid][1], aim, int(card.get("target", {}).get("size", 0)))
	grid.restore_state(gsnap)
	for s in asnap:
		s[0].hp = s[1]; s[0].statuses = s[2]; s[0].deck = s[3]; s[0].controller = s[4]; s[0].team = s[5]
	rng.set_state(rstate)
	return {"cells": cells, "damage_by_uid": dmg, "moved_by_uid": moved}
