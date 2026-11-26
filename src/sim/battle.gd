class_name Battle
extends RefCounted
## One fight on a single shared clock. Every action costs game seconds and the world runs while
## they pass: each second the player's finishing action resolves first, then (every env_every
## seconds) the environment, then due telegraphs, then enemies whose turn has come.
## Rounds (round_time seconds) are only the draw rhythm of the hand.

const HAND_MODE := "relaxed"   # "relaxed" | "lifespan"
const DEFAULTS := {"round_time": 10, "grid_w": 9, "grid_h": 7, "env_every": 2, "move_time": 1,
	"wheel_time": 1, "draws_per_round": 2}

var catalog: Catalog
var cfg: Dictionary = {}
var rng: SimRng
var grid: Grid
var ctx: Effects.BattleContext
var actors: Array = []
var belt: HandBelt
var belt_owner: Actor
var now := 0                 # battle clock in seconds
var phase := "player"        # player | won | lost
var telegraphs: Array = []   # {actor_uid, card_id, aim, cells, fire_at, track, foe_uid}
var log: Array = []
var borrow_left := 0          # 불릿타임: borrowed seconds still to spend while the world stays frozen
var borrow_used := 0          # borrowed seconds spent so far (repaid x1.5 as exhaustion)
var frames: Array = []        # one per passed second: {t, pos {uid: Vector2i}, hp {uid: int}} for the view to replay

func _init(cat: Catalog, seed_value: int, player_def: String, enemy_defs: Array, layout: Dictionary = {}) -> void:
	catalog = cat
	cfg = DEFAULTS.duplicate()
	cfg.merge(catalog.config, true)
	Grid.W = int(cfg["grid_w"])
	Grid.H = int(cfg["grid_h"])
	rng = SimRng.new(seed_value)
	grid = Grid.new(catalog)
	ctx = Effects.BattleContext.new()
	ctx.grid = grid
	ctx.catalog = catalog
	ctx.rng = rng
	ctx.log = log
	ctx.actors = actors
	ctx.on_meta = _on_meta
	ctx.on_deck_add = _on_deck_add
	var lay := layout if not layout.is_empty() else _random_layout(enemy_defs.size())
	for m in lay.get("materials", []):
		grid.set_material(Vector2i(m[0], m[1]), m[2])
	for v in lay.get("states", []):
		grid.add_state(Vector2i(v[0], v[1]), v[2], float(v[3]) if v.size() > 3 else -1.0)
	var pl := Actor.from_def(catalog.actors[player_def], 1)
	pl.team = 0
	pl.controller = "human"
	_spawn(pl, Vector2i(lay["player_pos"][0], lay["player_pos"][1]))
	var uid := 2
	for i in enemy_defs.size():
		var e := Actor.from_def(catalog.actors[enemy_defs[i]], uid)
		uid += 1
		e.next_at = 1 + i   # enemies start staggered, one second apart
		var ep: Array = lay["enemy_pos"][i] if i < lay["enemy_pos"].size() else [Grid.W - 2, i]
		_spawn(e, Vector2i(ep[0], ep[1]))
	ctx.next_uid = 100
	_rebuild_belt()
	_frame()

func _spawn(a: Actor, p: Vector2i) -> void:
	if not grid.place_unit(a, p):
		grid.set_material(p, "none")
		grid.place_unit(a, p)
	actors.append(a)

func _random_layout(n_enemies: int) -> Dictionary:
	var mid := Grid.H / 2
	var player := [1, mid]
	var enemies := []
	var rows := [mid, mid - 2, mid + 2, mid - 1, mid + 1]
	for i in n_enemies:
		enemies.append([Grid.W - 2, clampi(rows[i % rows.size()], 0, Grid.H - 1)])
	var reserved := [Vector2i(player[0], player[1])]
	for e in enemies:
		reserved.append(Vector2i(e[0], e[1]))
	var mats := []
	var pool := ["water", "water", "oil", "wall", "crystal", "ice"]
	for k in int(Grid.W * Grid.H / 9):
		var p := Vector2i(2 + rng.next_int(maxi(1, Grid.W - 4)), rng.next_int(Grid.H))
		if reserved.has(p):
			continue
		var m: String = pool[rng.next_int(pool.size())]
		mats.append([p.x, p.y, m])
	return {"player_pos": player, "enemy_pos": enemies, "materials": mats}

func human() -> Actor:
	for a in actors:
		if a.controller == "human" and a.alive():
			return a
	return null

func _rebuild_belt() -> void:
	belt_owner = human()
	if belt_owner != null:
		belt = HandBelt.new(belt_owner.deck, rng, catalog, 5, true, HAND_MODE)
		belt.per_round = int(cfg["draws_per_round"])

func _on_meta(part: Dictionary, user) -> void:
	if part.get("op", "") == "borrow":
		if user == human():
			borrow_left += int(part.get("secs", 10))
			_log("borrow", "%s 시간 %d초 가불" % [user.name, borrow_left], {"secs": borrow_left})
		return
	if user != human():
		return
	match part["op"]:
		"guard":
			# 받아치기 / 구르기 cards: the second the card lands is the guarded second
			user.guard_kind = part.get("kind", "parry")
			user.guard_at = now
			user.guard_from = user.pos
			if user.guard_kind == "parry":
				_log("brace", "%s 받아치기 자세" % user.name, {"uid": user.uid})
		"interrupt":
			var n0 := telegraphs.size()
			telegraphs = telegraphs.filter(func(t): return int(t["actor_uid"]) != int(part["uid"]))
			var v := _actor(int(part["uid"]))
			if n0 != telegraphs.size() and v != null:
				v.next_at = maxi(v.next_at, now + 1)
				_log("interrupt", "%s의 공격을 끊음" % v.name, {"uid": v.uid, "cells": [v.pos]})
		"delay_actor":
			var v2 := _actor(int(part["uid"]))
			if v2 != null:
				var s2 := int(part.get("secs", 2))
				v2.next_at += s2
				for t in telegraphs:
					if int(t["actor_uid"]) == v2.uid:
						t["fire_at"] = int(t["fire_at"]) + s2
				_log("delay_actor", "%s 행동 %d초 늦춤" % [v2.name, s2], {"uid": v2.uid, "cells": [v2.pos]})
		"clone":
			_spawn_clone(user, part["aim"], int(part.get("secs", 8)))
		"time_budget":
			# buys time: every other team's next action and pending telegraph is pushed back
			var d := int(part.get("delta", 0))
			for a in actors:
				if a.team != user.team:
					a.next_at = maxi(now + 1, a.next_at + d)
			for t in telegraphs:
				t["fire_at"] = maxi(now + 1, int(t["fire_at"]) + d)
		"belt":
			match part.get("action", "freeze"):
				"freeze": belt.hold()
				"advance":
					for i in int(part.get("amount", 1)):
						belt.roll(1)
				"reverse": belt.reverse_next = true

## 그림자 분신: a shadow of the player that repeats every attack card from where it stands.
func _spawn_clone(user: Actor, at: Vector2i, secs: int) -> void:
	var spot := at
	if not (grid.passable(spot) and grid.unit_at(spot) == null):
		spot = Vector2i(-1, -1)
		for n in grid.neighbors4(user.pos):
			if grid.passable(n) and grid.unit_at(n) == null:
				spot = n
				break
	if spot == Vector2i(-1, -1):
		_log("no_target", "분신을 둘 자리가 없음", {})
		return
	var c := Actor.from_def({"id": "shadow_clone", "name": "그림자 분신", "hp": 1, "mass": 1}, ctx.next_uid)
	ctx.next_uid += 1
	c.team = user.team
	c.controller = "echo"
	c.facing = user.facing
	c.expires_at = now + secs
	grid.place_unit(c, spot)
	actors.append(c)
	_log("clone", "그림자 분신", {"uid": c.uid, "cells": [spot]})

## A card gained mid-battle (cardify, steal, plant) becomes the next card the hand draws.
func _on_deck_add(actor, card_id: String) -> void:
	if belt != null and actor == belt_owner:
		belt.draw_pile.push_front(card_id)

static func dist(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)

func _ts(p: Vector2i) -> float:
	return grid.time_scale(p)

## Real seconds an action of `base` seconds takes for this actor (slow cells stretch it, fast
## cells shrink it). -1 when the actor stands in stopped time and cannot act.
func action_secs(base: int, actor: Actor) -> int:
	if base <= 0:
		return 0
	var ts := _ts(actor.pos)
	if ts <= 0.0:
		return -1
	return maxi(1, int(ceil(float(base) / ts - 0.0001)))

func round_time() -> int:
	return int(cfg["round_time"])

func next_draw_at() -> int:
	return (now / round_time() + 1) * round_time()

func _can_act() -> bool:
	return not _check_end() and human() != null

# ---- player commands -------------------------------------------------------

## Basic character's personal ability: one tile, move_time seconds. Resolves when the move ends.
func cmd_move(dir: Vector2i) -> bool:
	var h := human()
	if not _can_act() or h.base_ability != "step1" or absi(dir.x) + absi(dir.y) != 1 or h.rooted():
		return false
	var to: Vector2i = h.pos + dir
	if not grid.passable(to) or grid.unit_at(to) != null:
		return false
	var secs := action_secs(int(cfg["move_time"]), h)
	if secs < 0:
		return false
	_spend(secs, func():
		if grid.passable(to) and grid.unit_at(to) == null:
			grid.move_unit(h, to)
			h.facing = dir
			if grid.mat_def(to).get("lethal", false):
				h.hp = 0
			_log("move", "%s 이동" % h.name, {"to": to}))
	return true

## Non-move base abilities (other characters, swapped bodies): one second each.
func cmd_ability(aim: Vector2i) -> bool:
	var h := human()
	if not _can_act():
		return false
	var secs := action_secs(1, h)
	if secs < 0:
		return false
	match h.base_ability:
		"heat_self", "belt1":
			pass
		"pull1":
			var u = grid.unit_at(aim)
			if u == null or u == h or dist(aim, h.pos) > 2:
				return false
		_:
			return false
	_spend(secs, func():
		match h.base_ability:
			"heat_self":
				grid.add_state(h.pos, "heat")
				for n in grid.neighbors4(h.pos):
					grid.add_state(n, "heat")
			"pull1":
				var u = grid.unit_at(aim)
				if u != null and dist(u.pos, h.pos) > 1:
					EnvironmentStep.push_unit(grid, u, -Targeting.dir_to(h.pos, u.pos), 1, log)
			"belt1":
				belt.roll(1)
		_log("ability", "%s 기본 능력" % h.name, {"ability": h.base_ability}))
	return true

func can_play(slot: int, aim: Vector2i) -> bool:
	var h := human()
	if not _can_act() or belt == null or slot < 0 or slot >= belt.slots.size() or belt.slots[slot] == null:
		return false
	var card := Effects.card_def(belt.slots[slot]["card_id"], catalog)
	if card.is_empty() or action_secs(int(card.get("time", 0)), h) < 0:
		return false
	var shape: String = card.get("target", {}).get("shape", "cell")
	if shape != "self" and shape != "all" and shape != "around":
		if not grid.in_bounds(aim) or dist(h.pos, aim) > int(card.get("target", {}).get("range", 1)):
			return false
	return true

## Plays a card: its time passes (wind-up), the effect lands at the end, then `exhaust` seconds
## pass with the character idle.
func cmd_play(slot: int, aim: Vector2i) -> bool:
	if not can_play(slot, aim):
		return false
	var h := human()
	var id := belt.take(slot)
	var card := Effects.card_def(id, catalog)
	if card.get("once", false):
		# 일회성: gone from the deck once played
		if not belt.draw_pile.is_empty() and belt.draw_pile.back() == id:
			belt.draw_pile.pop_back()
		h.deck.erase(id)
		_log("once", "%s 사라짐" % card.get("name", id), {"card": id})
	belt.refill_one()   # the used slot fills straight away
	var secs := action_secs(int(card.get("time", 0)), h)
	var tg0: Dictionary = card.get("target", {})
	var shown_secs := maxi(0, secs - (mini(h.discount, secs) if secs > 0 else 0))
	_log("play", "%s: %s (%d초)" % [h.name, card.get("name", id), secs], {"card": id, "aim": aim, "uid": h.uid,
		"secs": 0 if borrow_left > 0 else shown_secs, "cells": Targeting.cells(tg0.get("shape", "cell"), h.pos, aim, int(tg0.get("size", 0)))})
	_spend(secs, func():
		var tg: Dictionary = card.get("target", {})
		_log("land", "%s 발동" % card.get("name", id), {"card": id, "user": h.uid,
			"cells": Targeting.cells(tg.get("shape", "cell"), h.pos, aim, int(tg.get("size", 0)))})
		if aim != h.pos:
			h.facing = Targeting.dir_to(h.pos, aim)
		Effects.apply(card, h, aim, ctx)
		if Effects.is_attack(card):
			for c2 in actors.duplicate():
				if c2.controller == "echo" and c2.alive() and grid.units.has(c2) and c2.team == h.team:
					_log("land", "분신: %s" % card.get("name", id), {"card": id, "user": c2.uid,
						"cells": Targeting.cells(tg.get("shape", "cell"), c2.pos, aim, int(tg.get("size", 0)))})
					Effects.apply(card, c2, aim, ctx)
		_after_action())
	var ex := int(card.get("exhaust", 0))
	if ex > 0 and phase == "player":
		_log("exhaust", "%s 탈진 %d초" % [h.name, ex], {"secs": ex})
		_spend(ex, Callable(), false)
	return true

## Mouse-wheel roll: the end card on that side is discarded and a new card enters on the other
## side. Costs wheel_time per weight of the discarded card.
func cmd_wheel(dir: int) -> bool:
	var h := human()
	if not _can_act() or belt == null or dir == 0:
		return false
	var end_id := belt.end_card(dir)
	var w := maxi(1, int(Effects.card_def(end_id, catalog).get("weight", 1))) if end_id != "" else 1
	var secs := action_secs(w * int(cfg["wheel_time"]), h)
	if secs < 0:
		return false
	_spend(secs, func():
		var dropped := belt.roll(dir)
		_log("wheel", "손패 굴리기%s" % ("" if dropped == "" else " (버림: %s)" % Effects.card_def(dropped, catalog).get("name", dropped)), {"dropped": dropped}))
	return true

## Lets time pass (also the only thing a player in stopped time can do).
func cmd_wait(secs := 1) -> bool:
	if not _can_act() or secs <= 0:
		return false
	if borrow_left > 0:   # waiting ends the borrowed time early: the debt comes due now
		_repay()
		return true
	advance(secs)
	return true

func borrowing() -> bool:
	return borrow_left > 0

## Spends `secs` of the human's time on an action. A pending 서두름 discount comes off first;
## while time is borrowed (불릿타임) the action happens with the world frozen.
func _spend(secs: int, on_done: Callable = Callable(), discountable := true) -> void:
	var h := human()
	if discountable and h != null and h.discount > 0 and secs > 0:
		var cut := mini(h.discount, secs)
		secs -= cut
		h.discount = 0
	if borrow_left > 0 and secs <= borrow_left:
		borrow_left -= secs
		borrow_used += secs
		advance(0, on_done)
		if borrow_left == 0:
			_repay()
		return
	if borrow_left > 0:
		_repay()
	advance(secs, on_done)

## Ends borrowed time: the character is exhausted for 1.5x the borrowed seconds it used.
func _repay() -> void:
	var debt := int(ceil(float(borrow_used) * 1.5))
	borrow_left = 0
	borrow_used = 0
	if debt > 0 and phase == "player":
		_log("exhaust", "가불 상환: 탈진 %d초" % debt, {"secs": debt})
		advance(debt)

# ---- clock -----------------------------------------------------------------

## Runs the world `secs` seconds. on_done (the player's finishing action) resolves at the start
## of the last second, before the world reacts in that second. secs 0 = resolve immediately.
func advance(secs: int, on_done: Callable = Callable()) -> void:
	var actor := human()   # the body that started the action; if control moved away, it is cancelled
	if secs <= 0:
		if on_done.is_valid():
			on_done.call()
			_after_action()
		_frame()   # instant actions still get a frame, so the view glides instead of jumping
		return
	for i in secs:
		if phase != "player":
			return
		now += 1
		ctx.now = now
		if i == secs - 1 and on_done.is_valid():
			if human() != null and human() == actor:
				on_done.call()
				_after_action()
			if phase != "player":
				_frame()
				return
		_world_second()
		_frame()

## Snapshot of where every unit is and its hp at the current second (view replay).
func _frame() -> void:
	var pos := {}
	var hp := {}
	for a in actors:
		if grid.units.has(a):
			pos[a.uid] = a.pos
		hp[a.uid] = a.hp
	frames.append({"t": now, "pos": pos, "hp": hp})

## Crystals broken outside an effect (shoved units, collisions) still throw their shards.
func _throw_shards() -> void:
	ctx.now = now
	for guard in 8:
		var any := false
		while not grid.shatter_queue.is_empty():
			Effects.shatter(ctx, grid.shatter_queue.pop_front(), null)
			any = true
		while not grid.trap_queue.is_empty():
			var v = grid.trap_queue.pop_front()
			var md: Dictionary = grid.mat_def(v.pos)
			if not md.has("trap") or not v.alive():
				continue
			var tr: Dictionary = md["trap"]
			grid.set_material(v.pos, "none")
			_log("trap", "%s 덫에 걸림" % v.name, {"uid": v.uid, "cells": [v.pos]})
			v.add_status(tr.get("status", "rooted"), int(tr.get("turns", 2)))
			var dd: int = v.take_damage(int(tr.get("damage", 0)), "physical")
			_log("damage", "%s 덫 %d" % [v.name, dd], {"uid": v.uid, "amount": dd})
			any = true
		for a in actors:
			if a.shattered:
				a.shattered = false
				Effects.shatter(ctx, a.pos, a)
				any = true
		if not any:
			break

func _world_second() -> void:
	for a in actors:
		if a.shield > 0 and now >= a.shield_until:
			a.shield = 0
		if a.expires_at >= 0 and now >= a.expires_at and grid.units.has(a):
			a.hp = 0
			_log("vanish", "%s 사라짐" % a.name, {"uid": a.uid, "cells": [a.pos]})
	ctx.now = now
	var due := ctx.timers.filter(func(t): return int(t["at"]) <= now)
	if not due.is_empty():
		ctx.timers = ctx.timers.filter(func(t): return int(t["at"]) > now)
		for t in due:
			_log("timer_fire", "시한폭탄 폭발", {"cells": t["cells"], "cell": t["aim"]})
			Effects.apply_part(t["part"], t["user"], t["aim"], t["cells"], ctx)
		_after_action()
	if now % int(cfg["env_every"]) == 0:
		EnvironmentStep.run(grid, catalog, rng, log, true, float(cfg["env_every"]))
		Effects.tick_pending(ctx, true)
		_after_action()
	if phase != "player":
		return
	_resolve_telegraphs()
	if phase != "player":
		return
	for a in actors.duplicate():
		if phase != "player":
			return
		if a.controller != "ai" or not a.alive() or not grid.units.has(a) or now < a.next_at:
			continue
		if _busy(a):
			continue
		if _ts(a.pos) <= 0.0:
			a.next_at = now + 1
			continue
		_ai_act(a)
		_after_action()
	_track_telegraphs()
	if now % round_time() == 0 and phase == "player":
		var h := human()
		if h != null and belt != null:
			belt.end_turn(_ts(h.pos))
		_log("round", "%d초: 카드 보충" % now, {})

func _busy(a: Actor) -> bool:
	for t in telegraphs:
		if t["actor_uid"] == a.uid:
			return true
	return false

func _resolve_telegraphs() -> void:
	var keep: Array = []
	for t in telegraphs:
		var a: Actor = _actor(t["actor_uid"])
		if a == null or not a.alive() or a.controller != "ai" or not grid.units.has(a):
			continue
		if int(t["fire_at"]) > now:
			keep.append(t)
			continue
		if _ts(a.pos) <= 0.0:
			# the attacker is frozen in time: the attack waits
			t["fire_at"] = now + 1
			keep.append(t)
			continue
		var cells: Array = t["cells"]
		var h := human()
		if h != null and h.guard_at == now and h.guard_kind != "" and (cells.has(h.pos) or cells.has(h.guard_from)):
			cells = cells.filter(func(p): return p != h.pos)
			if h.guard_kind == "parry":
				_log("parry", "받아치기!", {"uid": h.uid, "cells": [h.pos, a.pos]})
				ctx.now = now
				Effects.hit(ctx, h, a, Actor.PARRY_DAMAGE, "physical", "받아치기")
				a.add_status("stunned", 1)
				a.next_at = maxi(a.next_at, now + 2)
			else:
				_log("dodge", "회피!", {"uid": h.uid, "cells": [h.pos]})
				h.discount += 1
			h.guard_kind = ""
		_log("telegraph_hit", "%s: %s" % [a.name, Effects.card_def(t["card_id"], catalog).get("name", "")], {"cells": cells, "user": a.uid})
		if cells.is_empty():
			a.next_at = maxi(a.next_at, now + 1)
			continue
		Effects.apply(Effects.card_def(t["card_id"], catalog), a, t["aim"], ctx, cells)
		a.next_at = maxi(a.next_at, now + 1)
		_after_action()
		if phase != "player":
			break
	telegraphs = keep

## Tracking attacks follow their target until one second before they fire, then lock.
func _track_telegraphs() -> void:
	for t in telegraphs:
		if not t.get("track", false) or int(t["fire_at"]) - now < 1:
			continue
		var a: Actor = _actor(t["actor_uid"])
		if a == null:
			continue
		var f: Actor = _actor(t.get("foe_uid", -1))
		if f == null or not f.alive() or not grid.units.has(f) or f.team == a.team:
			# the target died or changed sides (body swap): follow the nearest foe instead
			f = EnemyAI.nearest_foe(a, self)
			if f == null:
				continue
			t["foe_uid"] = f.uid
		var card := Effects.card_def(t["card_id"], catalog)
		if dist(a.pos, f.pos) > int(card.get("target", {}).get("range", 1)):
			continue   # out of range: keep the last aim
		t["aim"] = f.pos
		t["cells"] = _attack_cells(card, a, f.pos, f)

func _attack_cells(card: Dictionary, a: Actor, aim: Vector2i, foe: Actor) -> Array:
	var tgt: Dictionary = card.get("target", {})
	var cells: Array = Targeting.cells(tgt.get("shape", "cell"), a.pos, aim, int(tgt.get("size", 0)))
	var n_safe := int(card.get("safe", 0))
	if n_safe > 0:
		# safe-zone attack: everything except a few cells, one of them within reach of the target
		var safe: Array = []
		var near := grid.all_cells().filter(func(p): return dist(p, foe.pos) <= 2 and dist(p, foe.pos) >= 1 and grid.passable(p))
		if not near.is_empty():
			safe.append(near[rng.next_int(near.size())])
		var tries := 0
		while safe.size() < n_safe and tries < 50:
			tries += 1
			var p := Vector2i(rng.next_int(Grid.W), rng.next_int(Grid.H))
			if not safe.has(p):
				safe.append(p)
		cells = cells.filter(func(p): return not safe.has(p) and p != a.pos)
	return cells

func _ai_act(a: Actor) -> void:
	var choice := EnemyAI.choose(a, self)
	if choice.is_empty():
		a.next_at = now + 1
		return
	var card := Effects.card_def(choice["card_id"], catalog)
	var tgt: Dictionary = card.get("target", {})
	var aim: Vector2i = choice["aim"]
	var foe: Actor = choice["foe"]
	var shape: String = tgt.get("shape", "cell")
	if shape != "self" and shape != "all" and shape != "around" and dist(a.pos, aim) > int(tgt.get("range", 1)):
		_ai_step_toward(a, aim)
		a.next_at = now + maxi(1, action_secs(int(cfg["move_time"]), a))
		return
	a.pattern_index += 1
	if aim != a.pos:
		a.facing = Targeting.dir_to(a.pos, aim)
	var secs := maxi(1, action_secs(int(card.get("time", 1)), a))
	if card.get("telegraph", false):
		var cells := _attack_cells(card, a, aim, foe)
		telegraphs.append({"actor_uid": a.uid, "card_id": choice["card_id"], "aim": aim, "cells": cells, "set_at": now,
			"fire_at": now + secs, "track": card.get("track", false), "foe_uid": foe.uid})
		a.next_at = now + secs + 1
		_log("telegraph", "%s: %s 예고 (%d초 뒤)" % [a.name, card.get("name", choice["card_id"]), secs], {"cells": cells})
	else:
		_log("play", "%s: %s" % [a.name, card.get("name", choice["card_id"])], {"card": choice["card_id"], "aim": aim})
		Effects.apply(card, a, aim, ctx)
		a.next_at = now + secs

func _ai_step_toward(a: Actor, target: Vector2i) -> void:
	var best := ai_step_cell(a, target)
	if best != a.pos:
		a.facing = best - a.pos
		grid.move_unit(a, best)

## The cell an enemy steps to when its target is out of reach (its own cell if it cannot move).
func ai_step_cell(a: Actor, target: Vector2i) -> Vector2i:
	if a.rooted():
		return a.pos
	var best := a.pos
	var best_d := dist(a.pos, target)
	for n in grid.neighbors4(a.pos):
		if grid.passable(n) and grid.unit_at(n) == null and not grid.mat_def(n).get("lethal", false) and dist(n, target) < best_d:
			best = n
			best_d = dist(n, target)
	return best

## What an idle enemy will do next, for the view: {kind: "move", to, at} or {kind: "attack", at}.
func ai_intent(a: Actor) -> Dictionary:
	if a.controller != "ai" or not a.alive() or not grid.units.has(a) or _busy(a):
		return {}
	var choice := EnemyAI.choose(a, self)
	if choice.is_empty():
		return {}
	var card := Effects.card_def(choice["card_id"], catalog)
	var tgt: Dictionary = card.get("target", {})
	var shape: String = tgt.get("shape", "cell")
	if shape != "self" and shape != "all" and shape != "around" and dist(a.pos, choice["aim"]) > int(tgt.get("range", 1)):
		var to := ai_step_cell(a, choice["aim"])
		if to != a.pos:
			return {"kind": "move", "to": to, "at": maxi(a.next_at, now + 1)}
	return {}

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
	_throw_shards()
	_cleanup()
	if human() != belt_owner and human() != null:
		# body swap: the body the player left becomes an AI that needs a moment to get its bearings
		if belt_owner != null and belt_owner.controller == "ai":
			belt_owner.next_at = maxi(belt_owner.next_at, now + 2)
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
	log.append({"t": t, "msg": msg, "data": data, "at": now})

## Simulates playing a card without changing anything (the card's effect only, as if it landed
## now; the world seconds of its wind-up are not simulated).
func preview(slot: int, aim: Vector2i) -> Dictionary:
	if not can_play(slot, aim):
		return {"cells": [], "damage_by_uid": {}, "moved_by_uid": {}}
	var h := human()
	var card := Effects.card_def(belt.slots[slot]["card_id"], catalog)
	var gsnap := grid.duplicate_state()
	var asnap := actors.map(func(a): return [a, a.hp, a.statuses.duplicate(), a.deck.duplicate(), a.controller, a.team, a.shield, a.shield_until, a.discount, a.facing, a.next_bonus, a.coat.duplicate()])
	var qsnap := [grid.shatter_queue.duplicate(), grid.trap_queue.duplicate()]
	var rstate = rng.get_state()
	var tmp := Effects.BattleContext.new()
	tmp.grid = grid
	tmp.catalog = catalog
	tmp.rng = rng
	tmp.actors = actors.duplicate()
	tmp.next_uid = ctx.next_uid
	tmp.now = now
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
		s[0].shield = s[6]; s[0].shield_until = s[7]; s[0].discount = s[8]
		s[0].facing = s[9]; s[0].next_bonus = s[10]; s[0].coat = s[11]
	grid.shatter_queue = qsnap[0]
	grid.trap_queue = qsnap[1]
	rng.set_state(rstate)
	return {"cells": cells, "damage_by_uid": dmg, "moved_by_uid": moved,
		"secs": maxi(0, action_secs(int(card.get("time", 0)), h) - (h.discount if int(card.get("time", 0)) > 0 else 0)), "exhaust": int(card.get("exhaust", 0))}
