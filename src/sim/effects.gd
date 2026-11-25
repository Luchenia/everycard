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
static func apply(card: Dictionary, user, aim: Vector2i, ctx: BattleContext, cells_override: Array = []) -> void:
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
				if not md.get("passable", true) and g.unit_at(p) != null:
					continue
				g.set_material(p, part["id"])
		"damage":
			var hit := _units_in(ctx, cells)
			if hit.is_empty():
				_log(ctx, "no_target", "대상 없음")
			for u in hit:
				var amt := int(round(float(part["amount"]) * float(g.get_var(u.pos, "mana_density"))))
				var d: int = u.take_damage(amt, part.get("kind", "physical"))
				_log(ctx, "damage", "%s %d 피해" % [u.name, d], {"uid": u.uid, "amount": d})
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
			_beam(part, user, aim, ctx)
		"delay":
			ctx.pending.append({"mode": "delay", "ticks": int(part.get("ticks", 1)), "part": part["part"], "user": user, "aim": aim, "cells": cells.duplicate()})
		"if":
			if EnvironmentStep.cond_all(g, aim, part.get("cond", [])):
				apply_part(part["part"], user, aim, cells, ctx)
			else:
				_log(ctx, "condition_false", "조건 불충족")
		"belt", "time_budget":
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

static func _beam(part: Dictionary, user, aim: Vector2i, ctx: BattleContext) -> void:
	var g := ctx.grid
	var d := Targeting.dir_to(user.pos, aim)
	var p: Vector2i = user.pos
	var reflected := false
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
		if not g.passable(nxt):
			if g.mat_def(nxt).get("reflective", false) and not reflected:
				d = -d
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
		if u != null and u != user and u.alive():
			var dealt: int = u.take_damage(int(part["damage"]), part.get("kind", "energy"))
			_log(ctx, "damage", "%s 광선 %d" % [u.name, dealt], {"uid": u.uid, "amount": dealt})
			break
		if g.mat_def(p).get("reflective", false) and not reflected:
			d = -d
			reflected = true
	_log(ctx, "beam", "광선", {"path": path})

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
