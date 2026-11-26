class_name Effects
extends RefCounted
## Executes card effect parts against the battle state. Cards are data: {target, parts}.

## Parts a cardified enemy's state adds to its card ("foe:<actor>|<tag>,<tag>").
const STATE_TAG_PARTS := {
	"burning": [{"op": "material", "id": "fire"}],
	"wet": [{"op": "var", "id": "humidity", "mode": "add", "value": 0.5}],
	"shocked": [{"op": "var", "id": "charge", "mode": "add", "value": 5}],
	"poisoned": [{"op": "var", "id": "toxicity", "mode": "add", "value": 4}],
	"guard": [{"op": "status", "id": "guard", "turns": 3, "shape": "self"}],
}

class BattleContext extends RefCounted:
	var grid: Grid
	var catalog: Catalog
	var rng: SimRng
	var log: Array = []
	var actors: Array = []
	var pending: Array = []      # {mode: "delay"|"sustain", ticks, part, user, aim, cells}
	var on_meta: Callable = Callable()
	var on_deck_add: Callable = Callable()   # (actor, card_id) -> void, lets Battle put gained cards into the hand
	var next_uid := 1000
	var now := 0   # battle clock (seconds), kept in step by Battle
	var timers: Array = []   # 시한폭탄: {at, part, user, aim, cells}
	var bonus := 0           # 빈틈 노리기 bonus for the card being applied
	var coat: Dictionary = {}  # 독 바르기 coating for the card being applied

## Card definition by id, including generated "foe:<actor>" (cardified enemy) and "summon:<actor>" cards.
static func card_def(id: String, catalog: Catalog) -> Dictionary:
	if id.begins_with("summon:"):
		var aid := id.substr(7)
		var nm: String = catalog.actors.get(aid, {}).get("name", aid)
		return {"id": id, "name": "소환: " + nm, "time": 3, "weight": 1, "rarity": "common",
			"target": {"shape": "cell", "range": 2, "size": 0}, "parts": [{"op": "summon", "def_id": aid}]}
	if id.begins_with("foe:"):
		var spec := id.substr(4).split("|")
		var fid := spec[0]
		var tags: Array = Array(spec[1].split(",")) if spec.size() > 1 else []
		var adef: Dictionary = catalog.actors.get(fid, {})
		var sig: Dictionary = catalog.cards.get(adef.get("signature", ""), {})
		if sig.is_empty():
			return {}
		var parts: Array = sig.get("parts", []).duplicate(true) + Array(adef.get("trait", [])).duplicate(true)
		for t in tags:
			if STATE_TAG_PARTS.has(t):
				parts += STATE_TAG_PARTS[t].duplicate(true)
			elif t == "summon":
				parts = [{"op": "summon", "def_id": fid}]
		return {"id": id, "name": adef.get("name", fid) + " 카드", "time": int(sig.get("time", 2)) + 1, "weight": 1,
			"rarity": "rare", "target": sig.get("target", {}).duplicate(), "parts": parts,
			"desc": "%s의 %s와 성질" % [adef.get("name", fid), sig.get("name", "")]}
	return catalog.cards.get(id, {})

## cells_override: fixed cells for parts without their own shape (a telegraph hits exactly the
## cells it showed, e.g. a safe-zone attack).
static func is_attack(card: Dictionary) -> bool:
	for part in card.get("parts", []):
		if part.get("op", "") in ["damage", "beam", "shadow_dash"]:
			return true
	return false

static func apply(card: Dictionary, user, aim: Vector2i, ctx: BattleContext, cells_override: Array = []) -> void:
	var tgt: Dictionary = card.get("target", {})
	var attack := is_attack(card)
	ctx.bonus = 0
	ctx.coat = {}
	if attack and user != null:
		ctx.bonus = user.next_bonus
		user.next_bonus = 0
		if not user.coat.is_empty():
			ctx.coat = user.coat
			user.coat = user.coat.duplicate()
			user.coat["charges"] = int(user.coat.get("charges", 1)) - 1
			if user.coat["charges"] <= 0:
				user.coat = {}
	_apply_parts(card, user, aim, ctx, cells_override)
	ctx.bonus = 0
	ctx.coat = {}

## One blow from `user` to `u`: card bonus, back attack, poison coating, crystal shards.
static func hit(ctx: BattleContext, user, u, amount: int, kind: String, label := "피해") -> int:
	var amt := amount + ctx.bonus
	var back := false
	if user != null and u != user and "backstab" in user.passives and u.team != user.team:
		var rel: Vector2i = user.pos - u.pos
		if rel.x * u.facing.x + rel.y * u.facing.y < 0:
			amt += Actor.BACKSTAB_BONUS
			back = true
	var d: int = u.take_damage(amt, kind)
	_log(ctx, "damage", "%s %s %d" % [u.name, label, d], {"uid": u.uid, "amount": d, "back": back})
	if back:
		_log(ctx, "backstab", "급소 찌르기", {"uid": u.uid, "cells": [u.pos]})
	if not ctx.coat.is_empty() and d > 0 and u.alive():
		u.add_status(ctx.coat.get("status", "poisoned"), int(ctx.coat.get("turns", 3)))
		_log(ctx, "status", "%s %s" % [u.name, ctx.coat.get("status", "poisoned")], {"uid": u.uid, "status": ctx.coat.get("status", "poisoned")})
	if u.shattered:
		u.shattered = false
		shatter(ctx, u.pos, u)
	return d

static func _apply_parts(card: Dictionary, user, aim: Vector2i, ctx: BattleContext, cells_override: Array = []) -> void:
	var tgt: Dictionary = card.get("target", {})
	for part in card.get("parts", []):
		var shape: String = part.get("shape", tgt.get("shape", "cell"))
		var size: int = int(part.get("size", tgt.get("size", 0)))
		var cells: Array = Targeting.cells(shape, user.pos, aim, size)
		if not cells_override.is_empty() and not part.has("shape"):
			cells = cells_override
		apply_part(part, user, aim, cells, ctx)

static func _deck_add(ctx: BattleContext, actor, card_id: String) -> void:
	actor.deck.append(card_id)
	if ctx.on_deck_add.is_valid():
		ctx.on_deck_add.call(actor, card_id)

static func _log(ctx: BattleContext, t: String, msg: String, data := {}) -> void:
	ctx.log.append({"t": t, "msg": msg, "data": data})

static func _units_in(ctx: BattleContext, cells: Array) -> Array:
	var out := []
	for p in cells:
		var u = ctx.grid.unit_at(p)
		if u != null and u.alive():
			out.append(u)
	return out

static func _vec_value(v, cell: Vector2i, user, aim: Vector2i) -> Vector2:
	if v is Array:
		return Vector2(v[0], v[1])
	if v is Dictionary:
		var s := float(v.get("strength", 1))
		match v.get("dir", "along"):
			"toward_aim":
				var d := Vector2(aim - cell)
				if d == Vector2.ZERO:
					return Vector2.ZERO
				return Vector2(Targeting.dir_to(cell, aim)) * s
			"away_aim":
				if cell == aim:
					return Vector2.ZERO
				return Vector2(Targeting.dir_to(aim, cell)) * s
			_:
				return Vector2(Targeting.dir_to(user.pos, aim)) * s
	return Vector2.ZERO

static func apply_part(part: Dictionary, user, aim: Vector2i, cells: Array, ctx: BattleContext) -> void:
	var g := ctx.grid
	match part.get("op", ""):
		"var":
			var id: String = part["id"]
			var vector: bool = ctx.catalog.variables.get(id, {}).get("kind", "") == "vector"
			for p in cells:
				var val = _vec_value(part["value"], p, user, aim) if vector else float(part["value"])
				match part.get("mode", "add"):
					"add": g.add_var(p, id, val)
					"set": g.set_var(p, id, val)
					"mul": g.set_var(p, id, g.get_var(p, id) * (val if not vector else 1.0))
			if int(part.get("turns", 0)) > 0:
				var again := part.duplicate()
				again.erase("turns")
				ctx.pending.append({"mode": "sustain", "ticks": int(part["turns"]), "part": again, "user": user, "aim": aim, "cells": cells.duplicate()})
		"material":
			for p in cells:
				var md: Dictionary = ctx.catalog.materials.get(part["id"], {})
				if (not md.get("passable", true) or md.has("trap")) and g.unit_at(p) != null:
					continue
				g.set_material(p, part["id"])
		"damage":
			var hit := _units_in(ctx, cells)
			if hit.is_empty():
				_log(ctx, "no_target", "대상 없음")
			for u in hit:
				var amt := int(round(float(part["amount"]) * float(g.get_var(u.pos, "mana_density"))))
				for k in maxi(1, int(part.get("hits", 1))):
					if u.alive():
						hit(ctx, user, u, amt, part.get("kind", "physical"))
			# physical blows and projectiles break crystals standing in the area
			if part.get("kind", "physical") in ["physical", "true"]:
				for p in cells:
					if g.in_bounds(p) and g.get_material(p) == "crystal":
						g.set_material(p, "none")
						shatter(ctx, p, null)
		"heal":
			for u in _units_in(ctx, cells):
				u.heal(int(part["amount"]))
				_log(ctx, "heal", "%s 회복 %d" % [u.name, int(part["amount"])], {"uid": u.uid})
		"status":
			var hs := _units_in(ctx, cells)
			if hs.is_empty():
				_log(ctx, "no_target", "대상 없음")
			for u in hs:
				u.add_status(part["id"], int(part.get("turns", 1)))
				_log(ctx, "status", "%s %s" % [u.name, part["id"]], {"uid": u.uid, "status": part["id"]})
		"push":
			var pushed := _units_in(ctx, cells)
			if pushed.is_empty():
				_log(ctx, "no_target", "대상 없음")
			for u in pushed:
				if u == user and part.get("dir", "away") in ["away", "toward"]:
					continue
				var d2 := Vector2i.ZERO
				match part.get("dir", "away"):
					"away": d2 = Targeting.dir_to(user.pos, u.pos)
					"toward": d2 = -Targeting.dir_to(user.pos, u.pos)
					"up": d2 = Vector2i.UP
					"down": d2 = Vector2i.DOWN
					"left": d2 = Vector2i.LEFT
					"right": d2 = Vector2i.RIGHT
				EnvironmentStep.push_unit(g, u, d2, int(part.get("dist", 1)), ctx.log)
		"teleport":
			if g.passable(aim) and g.unit_at(aim) == null:
				g.move_unit(user, aim)
				_log(ctx, "teleport", "%s 이동" % user.name, {"uid": user.uid, "to": aim})
				if g.mat_def(aim).get("lethal", false) and not user.is_boss:
					user.hp = 0
					_log(ctx, "void", "%s 공허로 추락" % user.name, {"uid": user.uid})
			else:
				_log(ctx, "no_target", "이동할 수 없는 칸")
		"beam":
			var d0 := Targeting.dir_to(user.pos, aim)
			if int(part.get("spread", 1)) >= 3:
				# 단검 세례: straight ahead and the two diagonals beside it
				var side := Vector2i(d0.y, d0.x)
				for dd in [d0, d0 + side, d0 - side]:
					_beam(part, user, aim, ctx, dd)
			else:
				_beam(part, user, aim, ctx)
		"behind":
			# 그림자 밟기: step into the cell at the target's back
			var t2 = g.unit_at(aim)
			if t2 == null or t2 == user:
				_log(ctx, "no_target", "대상 없음")
				return
			var spot: Vector2i = aim - t2.facing
			if not (g.in_bounds(spot) and g.passable(spot) and (g.unit_at(spot) == null or g.unit_at(spot) == user)):
				_log(ctx, "no_target", "뒤에 설 자리가 없음")
				return
			var from0: Vector2i = user.pos
			g.move_unit(user, spot)
			user.facing = t2.facing
			_log(ctx, "teleport", "%s 그림자 밟기" % user.name, {"uid": user.uid, "to": spot, "from": from0, "cells": [from0, spot]})
		"shadow_dash":
			# 그림자 걸음: run straight through foes, cutting each and leaving [그림자] on them
			var d3 := Targeting.dir_to(user.pos, aim)
			var last: Vector2i = user.pos
			var crossed := [user.pos]
			for i in range(1, int(part.get("dist", 4)) + 1):
				var c3: Vector2i = user.pos + d3 * i
				if not g.in_bounds(c3) or not g.passable(c3):
					break
				crossed.append(c3)
				var o = g.unit_at(c3)
				if o == null:
					last = c3
				elif o.team != user.team and o.alive():
					hit(ctx, user, o, int(part.get("amount", 4)), "physical")
					o.add_status("shadowed", int(part.get("shadow_turns", 3)))
					_log(ctx, "status", "%s 그림자" % o.name, {"uid": o.uid, "status": "shadowed"})
			if last != user.pos:
				g.move_unit(user, last)
			user.facing = d3
			_log(ctx, "dash", "%s 그림자 걸음" % user.name, {"uid": user.uid, "to": user.pos, "cells": crossed})
		"timer":
			# 시한폭탄: goes off `secs` seconds later on the cells around the aim
			var around := Targeting.cells("circle", aim, aim, int(part.get("size", 1)))
			ctx.timers.append({"at": ctx.now + int(part.get("secs", 3)), "part": part["part"], "user": user, "aim": aim, "cells": around})
			_log(ctx, "timer_set", "시한폭탄 설치", {"cell": aim, "cells": around, "at": ctx.now + int(part.get("secs", 3))})
		"empower":
			user.next_bonus += int(part.get("amount", 0))
			_log(ctx, "empower", "%s 다음 공격 +%d" % [user.name, user.next_bonus], {"uid": user.uid})
		"coat":
			user.coat = {"status": part.get("status", "poisoned"), "turns": int(part.get("status_turns", 3)), "charges": int(part.get("charges", 2))}
			_log(ctx, "coat", "%s 독 바름" % user.name, {"uid": user.uid})
		"interrupt":
			# 기습: the target's announced attack is cancelled
			var v4 = g.unit_at(aim)
			if v4 != null and ctx.on_meta.is_valid():
				ctx.on_meta.call({"op": "interrupt", "uid": v4.uid}, user)
		"delay_actor":
			var v5 = g.unit_at(aim)
			if v5 != null and v5 != user and ctx.on_meta.is_valid():
				ctx.on_meta.call({"op": "delay_actor", "uid": v5.uid, "secs": int(part.get("secs", 2))}, user)
		"clone":
			if ctx.on_meta.is_valid():
				ctx.on_meta.call({"op": "clone", "aim": aim, "secs": int(part.get("secs", 8))}, user)
		"shield":
			user.shield += int(part.get("amount", 0))
			user.shield_until = ctx.now + int(part.get("secs", 6))
			_log(ctx, "shield", "%s 보호막 %d" % [user.name, user.shield], {"uid": user.uid, "amount": user.shield})
		"dash":
			# runs toward the aim one cell at a time (diagonals allowed), stopping before anything in the way
			var steps := 0
			while user.pos != aim and steps < 9:
				var d := Vector2i(signi(aim.x - user.pos.x), signi(aim.y - user.pos.y))
				var nxt: Vector2i = user.pos + d
				if not g.passable(nxt) or g.unit_at(nxt) != null:
					break
				g.move_unit(user, nxt)
				steps += 1
				if g.mat_def(nxt).get("lethal", false) and not user.is_boss:
					user.hp = 0
					_log(ctx, "void", "%s 공허로 추락" % user.name, {"uid": user.uid})
					break
			if steps == 0:
				_log(ctx, "no_target", "막혀서 돌진 못 함")
			else:
				_log(ctx, "dash", "%s 돌진 %d칸" % [user.name, steps], {"uid": user.uid, "to": user.pos})
		"discount":
			user.discount += int(part.get("amount", 0))
			_log(ctx, "discount", "%s 다음 행동 %d초 단축" % [user.name, user.discount], {"uid": user.uid})
		"encase":
			# 결정: a unit on the cell is encased (rooted, shatters on hit for extra damage); an empty cell grows a crystal
			for p in cells:
				var u = g.unit_at(p)
				if u != null:
					u.add_status("crystal", int(part.get("turns", 3)))
					_log(ctx, "status", "%s 결정에 갇힘" % u.name, {"uid": u.uid, "status": "crystal"})
				elif g.passable(p):
					g.set_material(p, "crystal")
		"delay":
			ctx.pending.append({"mode": "delay", "ticks": int(part.get("ticks", 1)), "part": part["part"], "user": user, "aim": aim, "cells": cells.duplicate()})
		"if":
			if EnvironmentStep.cond_all(g, aim, part.get("cond", [])):
				apply_part(part["part"], user, aim, cells, ctx)
			else:
				_log(ctx, "condition_false", "조건 불충족")
		"belt", "time_budget", "borrow":
			if ctx.on_meta.is_valid():
				ctx.on_meta.call(part, user)
		"swap_bodies":
			var t = g.unit_at(aim)
			if t != null and Actor.swap_bodies(user, t):
				_log(ctx, "swap", "%s ↔ %s 몸 바꾸기" % [user.name, t.name], {"a": user.uid, "b": t.uid})
			else:
				_log(ctx, "swap_refused", "몸 바꾸기 실패")
		"steal_card":
			var v = g.unit_at(aim)
			if v != null and v != user and not v.deck.is_empty():
				var i := ctx.rng.next_int(v.deck.size())
				var cid: String = v.deck[i]
				v.deck.remove_at(i)
				_deck_add(ctx, user, cid)
				_log(ctx, "steal", "%s의 %s 훔침" % [v.name, cid], {"card": cid})
			else:
				_log(ctx, "no_target", "훔칠 카드 없음")
		"plant_card":
			var v2 = g.unit_at(aim)
			if v2 != null:
				_deck_add(ctx, v2, part["card_id"])
				_log(ctx, "plant", "%s 덱에 %s" % [v2.name, part["card_id"]], {"card": part["card_id"]})
		"cardify":
			var v3 = g.unit_at(aim)
			if v3 != null and v3 != user and not v3.is_boss and v3.hp <= int(v3.max_hp * 0.3):
				g.remove_unit(v3)
				v3.hp = 0
				var tags: Array = []
				for st in STATE_TAG_PARTS:
					if v3.has_status(st):
						tags.append(st)
				if user.summoner:
					tags = ["summon"]
				_deck_add(ctx, user, "foe:" + v3.def_id + ("|" + ",".join(tags) if not tags.is_empty() else ""))
				_log(ctx, "cardify", "%s 카드가 됨" % v3.name, {"uid": v3.uid})
			else:
				_log(ctx, "cardify_failed", "카드화 실패")
		"summon":
			var def: Dictionary = ctx.catalog.actors.get(part["def_id"], {})
			if def.is_empty():
				return
			var spot := aim
			if not (g.passable(spot) and g.unit_at(spot) == null):
				spot = Vector2i(-1, -1)
				for n in g.neighbors4(aim):
					if g.passable(n) and g.unit_at(n) == null:
						spot = n
						break
			if spot == Vector2i(-1, -1):
				_log(ctx, "no_target", "소환할 자리 없음")
				return
			var a := Actor.from_def(def, ctx.next_uid)
			ctx.next_uid += 1
			a.team = user.team
			a.controller = "ai"
			g.place_unit(a, spot)
			ctx.actors.append(a)
			_log(ctx, "summon", "%s 소환" % a.name, {"uid": a.uid})

## A crystal (a cell, or a crystallized unit) breaks: shards hit every unit around it.
static func shatter(ctx: BattleContext, at: Vector2i, source) -> void:
	_log(ctx, "shatter", "결정이 깨짐", {"cell": at, "cells": [at]})
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var n := at + Vector2i(dx, dy)
			if not ctx.grid.in_bounds(n):
				continue
			var u = ctx.grid.unit_at(n)
			if u == null or u == source or not u.alive():
				continue
			var d: int = u.take_damage(Actor.SHARD_DAMAGE, "physical")
			_log(ctx, "damage", "%s 파편 %d" % [u.name, d], {"uid": u.uid, "amount": d})
			if u.shattered:
				u.shattered = false
				shatter(ctx, u.pos, u)

## Light and magic hitting crystal turn left or right at random.
static func _deflect(ctx: BattleContext, d: Vector2i) -> Vector2i:
	var turn := Vector2i(d.y, d.x) if ctx.rng.next_int(2) == 0 else Vector2i(-d.y, -d.x)
	return turn

static func _crystal_at(g: Grid, p: Vector2i) -> bool:
	if g.get_material(p) == "crystal":
		return true
	var u = g.unit_at(p)
	return u != null and u.has_status("crystal")

static func _beam(part: Dictionary, user, aim: Vector2i, ctx: BattleContext, dir_override := Vector2i.ZERO) -> void:
	var g := ctx.grid
	var d := Targeting.dir_to(user.pos, aim) if dir_override == Vector2i.ZERO else dir_override
	var p: Vector2i = user.pos
	var reflected := false
	var deflects := 0
	var bends: Array = []   # crystal cells where light turned
	var length := int(part.get("length", 6))
	var path: Array = []
	for i in length:
		var nxt := p + d
		var grav: Vector2 = g.get_var(p, "gravity") if g.in_bounds(p) else Vector2.ZERO
		var perp := Vector2(d.y, d.x)
		var bend := grav.dot(perp)
		if absf(bend) >= 1.0:
			var shifted := nxt + Vector2i(perp) * signi(int(round(bend)))
			if g.in_bounds(shifted):
				nxt = shifted
		if not g.in_bounds(nxt):
			break
		var solid: bool = part.get("kind", "energy") in ["physical", "true"]
		if solid and g.get_material(nxt) == "crystal":
			# thrown weapons and arrows break a crystal and stop there
			g.set_material(nxt, "none")
			path.append(nxt)
			shatter(ctx, nxt, null)
			break
		if not solid and _crystal_at(g, nxt) and deflects < 3:
			d = _deflect(ctx, d)
			deflects += 1
			path.append(nxt)
			bends.append(nxt)
			_log(ctx, "deflect", "빛이 결정에 꺾임", {"cell": nxt, "cells": [nxt]})
			continue
		if not g.passable(nxt):
			if g.mat_def(nxt).get("reflective", false):
				d = -d
				path.append(nxt)
				reflected = true
				continue
			break
		if float(g.get_var(nxt, "time_scale")) <= 0.0:
			_log(ctx, "beam_frozen", "광선이 멈춘 시간에 갇힘", {"cell": nxt})
			ctx.pending.append({"mode": "delay", "ticks": 1, "part": {"op": "damage", "amount": part["damage"], "kind": part.get("kind", "energy")}, "user": user, "aim": nxt, "cells": [nxt]})
			break
		p = nxt
		path.append(p)
		var u = g.unit_at(p)
		if u != null and (u != user or reflected or deflects > 0) and u.alive():
			hit(ctx, user, u, int(part["damage"]), part.get("kind", "energy"), "광선")
			break
		if g.mat_def(p).get("reflective", false):
			d = -d
			reflected = true
	_log(ctx, "beam", "광선", {"path": path, "from": user.pos, "bends": bends, "kind": part.get("kind", "energy")})

## Call after every environment step. Sustained effects re-apply each call; their remaining
## turns (and delays) only count down when count_down is true (once per round in Battle).
static func tick_pending(ctx: BattleContext, count_down := true) -> void:
	var keep: Array = []
	for e in ctx.pending:
		if not count_down:
			if e["mode"] == "sustain":
				apply_part(e["part"], e["user"], e["aim"], e["cells"], ctx)
			keep.append(e)
			continue
		e["ticks"] -= 1
		if e["mode"] == "sustain":
			apply_part(e["part"], e["user"], e["aim"], e["cells"], ctx)
			if e["ticks"] > 0:
				keep.append(e)
		else:
			if e["ticks"] <= 0:
				apply_part(e["part"], e["user"], e["aim"], e["cells"], ctx)
			else:
				keep.append(e)
	ctx.pending = keep
