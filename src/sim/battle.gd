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
const TPS := 10              # clock ticks per world second: the world moves in 0.1 s steps
var tick := 0                # battle clock in ticks (TPS per world second)
var now: float:              # the battle clock in world seconds (read only)
	get: return float(tick) / TPS
var slow_until := -1         # 불릿타임: the world runs slow until this tick
var slow_rate := 1.0         # world seconds per player second while slowed (1/3: three times slower)
var phase := "player"        # player | won | lost
var stays_open := false      # a room you can walk around in: no foes left does not end it
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
		e.next_at = (1 + i) * TPS   # enemies start staggered, one second apart
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

## The run has set this fight's body (hp carried over, its deck): start the records from here,
## so the replay and the damage log do not see the carried-over hp as a hit.
func restart_records() -> void:
	frames.clear()
	_audit_hp.clear()
	_audit_log_i = log.size()
	_frame()

func _rebuild_belt() -> void:
	belt_owner = human()
	if belt_owner != null:
		belt = HandBelt.new(belt_owner.deck, rng, catalog, 5, true, HAND_MODE)
		belt.per_round = int(cfg["draws_per_round"])

func _on_meta(part: Dictionary, user) -> void:
	if part.get("op", "") == "slow":
		# 불릿타임: the world runs `factor` times slower for `secs` world seconds (timers keep their
		# value and count down in 0.1 s steps; the player's actions cost a third of the world time)
		slow_rate = 1.0 / maxf(1.0, float(part.get("factor", 3)))
		slow_until = maxi(slow_until, tick) + int(part.get("secs", 4)) * TPS
		_log("slow", "%s 불릿타임: 세상이 %d배 느려짐" % [user.name, int(part.get("factor", 3))], {"secs": int(part.get("secs", 4)), "uid": user.uid})
		return
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
			user.guard_at = tick
			user.guard_until = tick + _step_ticks()
			user.guard_from = user.pos
			if user.guard_kind == "parry":
				_log("brace", "%s 받아치기 자세" % user.name, {"uid": user.uid})
		"interrupt":
			var n0 := telegraphs.size()
			telegraphs = telegraphs.filter(func(t): return int(t["actor_uid"]) != int(part["uid"]))
			var v := _actor(int(part["uid"]))
			if n0 != telegraphs.size() and v != null:
				v.next_at = maxi(v.next_at, tick + TPS)
				_log("interrupt", "%s의 공격을 끊음" % v.name, {"uid": v.uid, "cells": [v.pos]})
		"delay_actor":
			var v2 := _actor(int(part["uid"]))
			if v2 != null:
				var s2 := int(part.get("secs", 2))
				v2.next_at += s2 * TPS
				for t in telegraphs:
					if int(t["actor_uid"]) == v2.uid:
						t["fire_at"] = int(t["fire_at"]) + s2 * TPS
				_log("delay_actor", "%s 행동 %d초 늦춤" % [v2.name, s2], {"uid": v2.uid, "cells": [v2.pos]})
		"clone":
			_spawn_clone(user, part["aim"], int(part.get("secs", 8)))
		"time_budget":
			# buys time: every other team's next action and pending telegraph is pushed back
			var d := int(part.get("delta", 0)) * TPS
			for a in actors:
				if a.team != user.team:
					a.next_at = maxi(tick + TPS, a.next_at + d)
			for t in telegraphs:
				t["fire_at"] = maxi(tick + TPS, int(t["fire_at"]) + d)
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
	c.expires_at = tick + secs * TPS
	grid.place_unit(c, spot)
	actors.append(c)
	_log("clone", "그림자 분신", {"uid": c.uid, "cells": [spot]})

## A card gained mid-battle (cardify, steal, plant) becomes the next card the hand draws.
func _on_deck_add(actor, card_id: String) -> void:
	if belt != null and actor == belt_owner:
		belt.draw_pile.push_front(card_id)

## Whether a card used from `from` reaches `aim` (its range, measured by its "reach" shape).
static func in_reach(card: Dictionary, from: Vector2i, aim: Vector2i) -> bool:
	var tgt: Dictionary = card.get("target", {})
	return Targeting.reaches(tgt.get("reach", "diamond"), from, aim, int(tgt.get("range", 1)))

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

## World second at which the hand next refills.
func next_draw_at() -> float:
	var rt := round_time() * TPS
	return float((tick / rt + 1) * rt) / TPS

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
		if not grid.in_bounds(aim) or not in_reach(card, h.pos, aim):
			return false
		if card.get("parts", []).any(func(pt): return pt.get("op", "") == "dash"):
			# a dash only offers cells it can really land on: free, and not behind a wall
			var path := Effects.dash_path(grid, h, aim)
			if path.is_empty() or path.back() != aim or grid.unit_at(aim) != null:
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
		"secs": 0 if borrow_left > 0 else shown_secs, "wsecs": 0.0 if borrow_left > 0 else shown_secs(maxi(1, shown_secs)), "cells": Targeting.cells(tg0.get("shape", "cell"), h.pos, aim, int(tg0.get("size", 0)))})
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
## The ring turns one way only: the hand's left card goes to the back of the ring and the next
## card comes in on the right. A played card also goes to the back, so it comes round again only
## after every other card has (the wheel either way turns it this way).
func cmd_wheel(dir: int) -> bool:
	var h := human()
	if not _can_act() or belt == null or dir == 0:
		return false
	if belt.mode == "relaxed":
		dir = -1
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
		# one player second: TPS ticks of world time, fewer while the world is slowed
		var n := _step_ticks()
		for k in n:
			if phase != "player":
				return
			tick += 1
			ctx.now = tick
			if i == secs - 1 and k == n - 1 and on_done.is_valid():
				if human() != null and human() == actor:
					on_done.call()
					_after_action()
				if phase != "player":
					_frame()
					return
			_world_tick()
		_frame()

## World ticks one player second takes now (TPS normally, a third of that in 불릿타임).
func _step_ticks() -> int:
	if slowed():
		return maxi(1, int(round(TPS * slow_rate)))
	return TPS

func slowed() -> bool:
	return tick < slow_until

## World seconds one player second takes right now (1.0, or about 0.3 in 불릿타임).
func world_rate() -> float:
	return float(_step_ticks()) / TPS

## Seconds from now until battle tick `t` (negative once it has passed).
func secs_until(t: int) -> float:
	return float(t - tick) / TPS

## A time for the screen: whole seconds as "4", anything else to a tenth ("3.7"), rounded up.
static func fmt_secs(x: float) -> String:
	var tenth := ceilf(x * 10.0 - 0.001) / 10.0
	if absf(tenth - roundf(tenth)) < 0.001:
		return "%d" % int(roundf(tenth))
	return "%.1f" % tenth

## World seconds a player action of `secs` takes right now (what the card cost shows).
func shown_secs(secs: int) -> float:
	return float(secs * _step_ticks()) / TPS

## Snapshot of where every unit is and its hp at the current second (view replay).
const HURT_LOGS := ["damage", "status_damage", "collision", "void", "dislike"]
var _audit_log_i := 0
var _audit_hp := {}

## Damage log check: any hp lost since the last frame that no log line explains is logged as
## "unknown" so a hidden source shows up in the on-screen log.
func _audit() -> void:
	var told := {}
	for i in range(_audit_log_i, log.size()):
		var e: Dictionary = log[i]
		if not e.has("at"):
			e["at"] = tick   # world-step lines (reactions, burns, pushes) are stamped with their second
		if e["t"] in HURT_LOGS or e["t"] == "split":
			var u := int(e["data"].get("uid", e["data"].get("from", -1)))
			if e["t"] == "split":
				var kid := _actor(int(e["data"].get("uid", -1)))
				u = int(e["data"].get("from", -1))
				told[u] = int(told.get(u, 0)) + (kid.hp if kid != null else 0)
				continue
			told[u] = int(told.get(u, 0)) + int(e["data"].get("amount", 0))
	for a in actors:
		if _audit_hp.has(a.uid):
			var lost: int = int(_audit_hp[a.uid]) - a.hp
			var miss: int = lost - int(told.get(a.uid, 0))
			if lost > 0 and miss > 0 and not (a.hp == 0 and e_void(a)):
				_log("unknown", "원인 모름 → %s  %d" % [a.name, miss], {"uid": a.uid, "amount": miss})
		_audit_hp[a.uid] = a.hp
	_audit_log_i = log.size()

func e_void(a: Actor) -> bool:
	for i in range(_audit_log_i, log.size()):
		if log[i]["t"] == "void" and int(log[i]["data"].get("uid", -1)) == a.uid:
			return true
	return false

func _frame() -> void:
	_audit()
	var pos := {}
	var hp := {}
	var glide := {}
	for a in actors:
		if grid.units.has(a):
			pos[a.uid] = a.pos
			# a step still under way (or just finished): where from, where to, and over which world seconds
			if not a.glide.is_empty() and int(a.glide[3]) >= tick - TPS and a.glide[1] == a.pos:
				glide[a.uid] = [a.glide[0], a.glide[1], float(a.glide[2]) / TPS, float(a.glide[3]) / TPS]
		hp[a.uid] = a.hp
	frames.append({"t": now, "pos": pos, "hp": hp, "glide": glide})

## Crystals broken outside an effect (shoved units, collisions) still throw their shards.
func _throw_shards() -> void:
	ctx.now = tick
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

## One world tick (0.1 s): shields and timers run out, every env_every seconds the environment
## steps, due telegraphs land, enemies whose time has come act, and each round the hand refills.
func _world_tick() -> void:
	for a in actors:
		if a.shield > 0 and tick >= a.shield_until:
			a.shield = 0
		if a.expires_at >= 0 and tick >= a.expires_at and grid.units.has(a):
			a.hp = 0
			_log("vanish", "%s 사라짐" % a.name, {"uid": a.uid, "cells": [a.pos]})
	ctx.now = tick
	var due := ctx.timers.filter(func(t): return int(t["at"]) <= tick)
	if not due.is_empty():
		ctx.timers = ctx.timers.filter(func(t): return int(t["at"]) > tick)
		for t in due:
			_log("timer_fire", "시한폭탄 폭발", {"cells": t["cells"], "cell": t["aim"]})
			Effects.apply_part(t["part"], t["user"], t["aim"], t["cells"], ctx)
		_after_action()
	if tick % (int(cfg["env_every"]) * TPS) == 0:
		EnvironmentStep.run(grid, catalog, rng, log, true, float(cfg["env_every"]))
		_likes_dislikes()
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
		if a.controller != "ai" or not a.alive() or not grid.units.has(a) or tick < a.next_at:
			continue
		if _busy(a):
			continue
		if _ts(a.pos) <= 0.0:
			a.next_at = tick + TPS
			continue
		_ai_act(a)
		_after_action()
	_track_telegraphs()
	if tick % (round_time() * TPS) == 0 and phase == "player":
		var h := human()
		if h != null and belt != null:
			belt.end_turn(_ts(h.pos))
		_log("round", "%d초: 카드 보충" % (tick / TPS), {})

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
		if int(t["fire_at"]) > tick:
			keep.append(t)
			continue
		if _ts(a.pos) <= 0.0:
			# the attacker is frozen in time: the attack waits
			t["fire_at"] = tick + TPS
			keep.append(t)
			continue
		var cells: Array = t["cells"]
		var h := human()
		if h != null and tick >= h.guard_at and tick < h.guard_until and h.guard_kind != "" and (cells.has(h.pos) or cells.has(h.guard_from)):
			cells = cells.filter(func(p): return p != h.pos)
			if h.guard_kind == "parry":
				_log("parry", "받아치기!", {"uid": h.uid, "cells": [h.pos, a.pos]})
				ctx.now = tick
				Effects.hit(ctx, h, a, Actor.PARRY_DAMAGE, "physical", "받아치기")
				a.add_status("stunned", 1)
				a.next_at = maxi(a.next_at, tick + 2 * TPS)
			else:
				_log("dodge", "회피!", {"uid": h.uid, "cells": [h.pos]})
				h.discount += 1
			h.guard_kind = ""
		_log("telegraph_hit", "%s: %s" % [a.name, Effects.card_def(t["card_id"], catalog).get("name", "")], {"cells": cells, "user": a.uid})
		if cells.is_empty():
			a.next_at = maxi(a.next_at, tick + TPS)
			continue
		Effects.apply(Effects.card_def(t["card_id"], catalog), a, t["aim"], ctx, cells)
		a.next_at = maxi(a.next_at, tick + TPS)
		_after_action()
		if phase != "player":
			break
	telegraphs = keep

## Tracking attacks follow their target until one second before they fire, then lock.
func _track_telegraphs() -> void:
	for t in telegraphs:
		if not t.get("track", false) or int(t["fire_at"]) - tick < TPS:
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
		if not in_reach(card, a.pos, f.pos):
			continue   # out of range: keep the last aim
		t["aim"] = f.pos
		t["cells"] = _attack_cells(card, a, f.pos, f)

func _attack_cells(card: Dictionary, a: Actor, aim: Vector2i, foe: Actor) -> Array:
	var tgt: Dictionary = card.get("target", {})
	var cells: Array = Targeting.cells(tgt.get("shape", "cell"), a.pos, aim, int(tgt.get("size", 0)))
	if card.get("parts", []).any(func(pt): return pt.get("op", "") == "charge"):
		# a charge's lane ends at the first wall: nothing behind it is in danger
		var lane := []
		for p in cells:
			if not grid.passable(p):
				break
			lane.append(p)
		cells = lane
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
		a.next_at = tick + TPS
		return
	var card := Effects.card_def(choice["card_id"], catalog)
	var tgt: Dictionary = card.get("target", {})
	var aim: Vector2i = choice["aim"]
	var foe: Actor = choice["foe"]
	var shape: String = tgt.get("shape", "cell")
	if _wants_out(a):
		# standing in fire or a curse: get out before anything else
		var out := ai_step_cell(a, aim, int(tgt.get("range", 1)), card)
		if out != a.pos and not hazard(out, a):
			a.facing = out - a.pos
			a.glide = [a.pos, out, tick, tick + maxi(1, action_secs(int(cfg["move_time"]), a)) * TPS]
			grid.move_unit(a, out)
			a.next_at = tick + maxi(1, action_secs(int(cfg["move_time"]), a)) * TPS
			return
	if shape != "self" and shape != "all" and shape != "around" and not in_reach(card, a.pos, aim):
		var plan := move_plan(a, foe, aim, card)
		a.stuck = a.stuck + 1 if plan["to"] == a.pos else 0
		if plan["to"] != a.pos:
			a.facing = Targeting.dir_to(a.pos, plan["to"])
			a.glide = [a.pos, plan["to"], tick, tick + int(plan["secs"]) * TPS]
			grid.move_unit(a, plan["to"])
			if plan["cells"] > 1:
				_log("hop", "%s 도약" % a.name, {"uid": a.uid, "cells": [plan["to"]]})
		a.next_at = tick + int(plan["secs"]) * TPS
		return
	if choice.get("trick", false):
		a.trick_ready[choice["card_id"]] = tick + int(choice["cd"]) * TPS
	else:
		a.pattern_index += 1
	if aim != a.pos:
		a.facing = Targeting.dir_to(a.pos, aim)
	var secs := maxi(1, action_secs(int(card.get("time", 1)), a))
	if card.get("telegraph", false):
		var cells := _attack_cells(card, a, aim, foe)
		telegraphs.append({"actor_uid": a.uid, "card_id": choice["card_id"], "aim": aim, "cells": cells, "set_at": tick,
			"fire_at": tick + secs * TPS, "track": card.get("track", false), "foe_uid": foe.uid})
		a.next_at = tick + (secs + 1) * TPS
		_log("telegraph", "%s: %s 예고 (%d초 뒤)" % [a.name, card.get("name", choice["card_id"]), secs], {"cells": cells})
	else:
		_log("play", "%s: %s" % [a.name, card.get("name", choice["card_id"])], {"card": choice["card_id"], "aim": aim})
		Effects.apply(card, a, aim, ctx)
		a.next_at = tick + secs * TPS

## Where a monster's next move takes it, by its way of moving (no change to the world):
##  chase:     the shortest safe way to where it can strike;
##  hop:       a leap of up to two cells along that way (slimes), a beat slower;
##  kite:      keeps off your row and column and backs off when you get next to it (imps);
##  intercept: heads for where you are going, not where you are (the boss).
## Returns {to, secs, cells}.
func move_plan(a: Actor, foe: Actor, aim: Vector2i, card: Dictionary) -> Dictionary:
	var reach := int(card.get("target", {}).get("range", 1))
	var base := a.move_secs if a.move_secs > 0 else int(cfg["move_time"])
	var secs := maxi(1, action_secs(base, a))
	var to := a.pos
	match a.move_style:
		"kite":
			if dist(a.pos, foe.pos) <= 1 and not a.rooted():
				var best_d := dist(a.pos, foe.pos)
				for n in grid.neighbors4(a.pos):
					if grid.passable(n) and grid.unit_at(n) == null and not hazard(n, a) and dist(n, foe.pos) > best_d:
						best_d = dist(n, foe.pos)
						to = n
				if to != a.pos:
					return {"to": to, "secs": secs, "cells": 1}
			to = ai_step_cell(a, aim, reach, card, true)
		"intercept":
			var ahead: Vector2i = foe.pos + foe.facing * 2
			if grid.in_bounds(ahead) and grid.passable(ahead) and dist(a.pos, ahead) < dist(a.pos, foe.pos) + 2:
				to = ai_step_cell(a, ahead, 1)
			if to == a.pos:
				to = ai_step_cell(a, aim, reach, card)
		"hop":
			to = ai_step_cell(a, aim, reach, card)
			if to != a.pos and not in_reach(card, to, aim):
				var keep := a.pos
				a.pos = to
				var to2 := ai_step_cell(a, aim, reach, card)
				a.pos = keep
				if to2 != to and to2 != a.pos and grid.unit_at(to2) == null:
					return {"to": to2, "secs": secs + 1, "cells": 2}
		_:
			to = ai_step_cell(a, aim, reach, card)
	return {"to": to, "secs": secs, "cells": 1}

## Even a reckless one leaves a cell it hates; the others leave any harm.
func _wants_out(a: Actor) -> bool:
	if a.rooted() or not hazard(a.pos, a):
		return false
	if a.temper != "reckless":
		return true
	return _hates(a.pos, a)

## True when this cell holds something this kind of monster hates (even a reckless one avoids it).
func _hates(p: Vector2i, a: Actor) -> bool:
	if a.dislikes.is_empty():
		return false
	for k in cell_tags(p):
		if a.dislikes.has(k):
			return true
	return false

func _ai_step_toward(a: Actor, target: Vector2i, reach := 1, card := {}) -> void:
	var best := ai_step_cell(a, target, reach, card)
	a.stuck = a.stuck + 1 if best == a.pos else 0
	if best != a.pos:
		a.facing = best - a.pos
		grid.move_unit(a, best)

## Cells an enemy will not walk into when there is another way: burning ground, curses, live wires,
## and whatever that kind of monster hates (water for a fire imp). What it likes is never harm to it.
const HAZARDS := ["blaze", "curse", "miasma", "charged", "collapse"]

func hazard(p: Vector2i, a: Actor = null) -> bool:
	var likes: Dictionary = a.likes if a != null else {}
	if a != null and _hates(p, a):
		return true
	if grid.get_material(p) == "fire" and not likes.has("fire"):
		return true
	for id in HAZARDS:
		if grid.has_state(p, id) and not likes.has(id):
			return true
	return false

## The material and every state on a cell, the words likes and dislikes are written in.
func cell_tags(p: Vector2i) -> Array:
	var out: Array = [grid.get_material(p)]
	out.append_array(grid.states_at(p))
	return out

## Each world step a monster standing on what it hates gets hurt, on what it likes gets healed.
func _likes_dislikes() -> void:
	for a in actors:
		if not a.alive() or not grid.units.has(a) or (a.likes.is_empty() and a.dislikes.is_empty()):
			continue
		var hurt := 0
		var heal := 0
		for k in cell_tags(a.pos):
			hurt += int(a.dislikes.get(k, 0))
			heal += int(a.likes.get(k, 0))
		if hurt > 0:
			a.hp = maxi(0, a.hp - hurt)
			_log("dislike", "%s 싫어하는 칸 %d" % [a.name, hurt], {"uid": a.uid, "cells": [a.pos], "amount": hurt})
		elif heal > 0 and a.hp < a.max_hp:
			a.hp = mini(a.max_hp, a.hp + heal)
			_log("like", "%s 좋아하는 칸 +%d" % [a.name, heal], {"uid": a.uid, "cells": [a.pos], "amount": heal})

## 분열: a monster that splits, brought to half hp, breaks into two halves side by side (once each).
func _splits() -> void:
	for a in actors.duplicate():
		if not a.splits or a.split_done or not a.alive() or not grid.units.has(a) or a.hp * 2 > a.max_hp or a.hp < 2:
			continue
		a.split_done = true
		var spot := Vector2i(-1, -1)
		for n in grid.neighbors4(a.pos):
			if grid.passable(n) and grid.unit_at(n) == null and not grid.mat_def(n).get("lethal", false):
				spot = n
				break
		if spot == Vector2i(-1, -1):
			continue
		var c := Actor.from_def(catalog.actors[a.def_id], ctx.next_uid)
		ctx.next_uid += 1
		c.team = a.team
		c.controller = a.controller if a.controller == "ai" else "ai"
		c.split_done = true
		c.max_hp = maxi(1, a.max_hp / 2)
		a.max_hp = c.max_hp
		c.hp = a.hp / 2
		a.hp -= c.hp
		c.facing = a.facing
		c.next_at = tick + TPS
		grid.place_unit(c, spot)
		actors.append(c)
		_log("split", "%s 분열" % a.name, {"uid": c.uid, "from": a.uid, "cells": [a.pos, spot]})

## The cell an enemy steps to when its target is out of reach (its own cell if it cannot move).
## A real path search around walls and bodies. How it treats fire and curses on the way depends
## on its temper: reckless ones walk straight through, careful ones go around and wait when there
## is no other way, stubborn ones take a short cut through harm when the way round is long. A
## careful enemy shut in long enough (STUCK_LIMIT seconds) loses patience and breaks out.
const HAZARD_COST := {"reckless": 1, "careful": 8, "stubborn": 4}
const STUCK_LIMIT := 3

func ai_step_cell(a: Actor, target: Vector2i, reach := 1, card := {}, off_line := false) -> Vector2i:
	if a.rooted():
		return a.pos
	var temper := a.temper
	if temper == "careful" and a.stuck >= STUCK_LIMIT:
		temper = "stubborn"
	var hz := int(HAZARD_COST.get(temper, 8))
	var free := func(p: Vector2i) -> bool:
		return grid.passable(p) and not grid.mat_def(p).get("lethal", false) and (grid.unit_at(p) == null or grid.unit_at(p) == a)
	# cheapest path (hazards cost extra) to any cell within reach of the target
	var cost := {a.pos: 0}
	var first := {a.pos: a.pos}
	var open: Array = [a.pos]
	var best := a.pos
	var best_cost := 1 << 30
	var best_d := dist(a.pos, target)
	while not open.is_empty():
		var bi := 0
		for i in open.size():
			if cost[open[i]] < cost[open[bi]]:
				bi = i
		var c: Vector2i = open[bi]
		open.remove_at(bi)
		if cost[c] > 30:
			break
		var ok := in_reach(card, c, target) if not card.is_empty() else dist(c, target) <= reach
		# off_line: a spot off the target's row and column counts as nearer (it will not walk your line)
		var cc: int = cost[c] + (3 if off_line and (c.x == target.x or c.y == target.y) else 0)
		if ok and c != a.pos and cc < best_cost:
			best_cost = cc
			best = c
		for n in grid.neighbors4(c):
			if not free.call(n):
				continue
			var nc: int = cost[c] + (maxi(hz, HAZARD_COST["careful"]) if _hates(n, a) else (hz if hazard(n, a) else 1))
			if not cost.has(n) or nc < cost[n]:
				cost[n] = nc
				first[n] = n if c == a.pos else first[c]
				open.append(n)
	if best != a.pos:
		var step: Vector2i = first[best]
		# a careful one would rather wait a moment than step into fire
		if not (temper == "careful" and hazard(step, a) and not hazard(a.pos, a)):
			return step
	# no way in reach: at least get closer without stepping into harm
	var fallback := a.pos
	for n in grid.neighbors4(a.pos):
		if free.call(n) and (temper != "careful" or not hazard(n, a)) and dist(n, target) < best_d:
			fallback = n
			best_d = dist(n, target)
	if fallback == a.pos and hazard(a.pos, a):
		for n in grid.neighbors4(a.pos):
			if free.call(n) and not hazard(n, a):
				return n
	return fallback

var _intent_cache := {}
var _intent_key := ""

## What an idle enemy will do next, for the view: {kind: "move", to, at} or {kind: "attack", at}.
## The path search behind it is costly and the view asks every frame, so answers are kept until
## anything in the battle happens (a new second, a log line, anyone moving).
func ai_intent(a: Actor) -> Dictionary:
	var key := "%d|%d|%d" % [tick, log.size(), frames.size()]
	for u in grid.units:
		key += "|%d,%d,%d" % [u.pos.x, u.pos.y, u.hp]
	if key != _intent_key:
		_intent_key = key
		_intent_cache = {}
	if not _intent_cache.has(a.uid):
		_intent_cache[a.uid] = _ai_intent(a)
	return _intent_cache[a.uid]

func _ai_intent(a: Actor) -> Dictionary:
	if a.controller != "ai" or not a.alive() or not grid.units.has(a) or _busy(a):
		return {}
	var choice := EnemyAI.choose(a, self)
	if choice.is_empty():
		return {}
	var card := Effects.card_def(choice["card_id"], catalog)
	var tgt: Dictionary = card.get("target", {})
	var shape: String = tgt.get("shape", "cell")
	var at := maxi(a.next_at, tick + 1)
	if _wants_out(a):
		var out := ai_step_cell(a, choice["aim"], int(tgt.get("range", 1)), card)
		if out != a.pos and not hazard(out, a):
			return {"kind": "move", "to": out, "at": at}
	if shape != "self" and shape != "all" and shape != "around" and not in_reach(card, a.pos, choice["aim"]):
		var plan := move_plan(a, choice["foe"], choice["aim"], card)
		if plan["to"] != a.pos:
			return {"kind": "move", "to": plan["to"], "at": at}
		return {}
	# in reach: the blow it will start at `at`, where it would land if nobody moves
	var has_damage: bool = card.get("parts", []).any(func(p): return p.get("op", "") == "damage")
	if not has_damage:
		return {}
	var cells: Array = Targeting.cells(shape, a.pos, choice["aim"], int(tgt.get("size", 0))) if int(card.get("safe", 0)) == 0 else []
	var secs := maxi(1, action_secs(int(card.get("time", 1)), a)) if card.get("telegraph", false) else 0
	return {"kind": "attack", "at": at, "fire_at": at + secs * TPS, "cells": cells, "card_id": choice["card_id"],
		"actor_uid": a.uid, "aim": choice["aim"], "pending": true}

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
	_splits()
	_cleanup()
	if human() != belt_owner and human() != null:
		# body swap: the body the player left becomes an AI that needs a moment to get its bearings
		if belt_owner != null and belt_owner.controller == "ai":
			belt_owner.next_at = maxi(belt_owner.next_at, tick + 2 * TPS)
		_rebuild_belt()
	_check_end()

func _check_end() -> bool:
	if phase == "won" or phase == "lost":
		return true
	if human() == null:
		phase = "lost"
		return true
	var foes := actors.filter(func(a): return a.alive() and a.team == 1 and grid.units.has(a))
	if foes.is_empty() and not stays_open:
		phase = "won"
		return true
	return false

func _log(t: String, msg: String, data: Dictionary) -> void:
	log.append({"t": t, "msg": msg, "data": data, "at": tick})

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
	tmp.now = tick
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
