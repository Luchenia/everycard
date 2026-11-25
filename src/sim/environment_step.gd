class_name EnvironmentStep
extends RefCounted
## One world update: statuses tick, reactions (capped) on the state cards just made, forces move units, then spread/recover.

const CHAIN_CAP := 8
const MAX_SLIDE := 9
const STATUS_DOT := {"burning": [3, "fire"], "poisoned": [2, "toxic"]}

## tick_statuses: statuses (and their damage over time) advance once per round, so Battle passes
## false for the step between the player's and the enemy's turn.
static func run(grid: Grid, catalog: Catalog, rng: SimRng, log: Array, tick_statuses := true) -> void:
	if tick_statuses:
		_tick_statuses(grid, log)
	var mat_before: Array = grid.material.duplicate()
	for p in grid.all_cells():
		if _ts(grid, p) > 0.0:
			_react_cell(grid, catalog, p, log, mat_before)
	_enter_effects(grid, log)
	_forces(grid, log)
	_spread_and_recover(grid, catalog)

static func _ts(grid: Grid, p: Vector2i) -> float:
	return float(grid.get_var(p, "time_scale")) if grid.values.has("time_scale") else 1.0

static func _tick_statuses(grid: Grid, log: Array) -> void:
	for u in grid.units:
		if not u.alive():
			continue
		for s in STATUS_DOT:
			if u.has_status(s):
				var d: int = u.take_damage(STATUS_DOT[s][0], STATUS_DOT[s][1])
				log.append({"t": "status_damage", "msg": "%s %s %d" % [u.name, s, d], "data": {"uid": u.uid, "status": s, "amount": d}})
		for s in u.statuses.keys():
			u.statuses[s] -= 1
			if u.statuses[s] <= 0:
				u.statuses.erase(s)

static func _spread_and_recover(grid: Grid, catalog: Catalog) -> void:
	var before := {}
	for id in grid.values:
		before[id] = grid.values[id].duplicate()
	for id in grid.values:
		var def: Dictionary = catalog.variables[id]
		var spread := float(def.get("spread", 0))
		var recover := float(def.get("recover", 0))
		var dflt = grid.default_of(id)
		for p in grid.all_cells():
			var i := grid.idx(p)
			var ts := float(before["time_scale"][i]) if before.has("time_scale") else 1.0
			if id == "time_scale":
				# time itself always drifts back toward normal, even when frozen
				grid.set_var(p, id, before[id][i] + (dflt - before[id][i]) * recover)
				continue
			if ts <= 0.0:
				continue
			var v = before[id][i]
			if spread > 0.0:
				var nbs := grid.neighbors4(p)
				var acc = v * 0
				for n in nbs:
					var k := spread
					if def.get("spread_by_conductivity", false):
						k *= minf(float(grid.catalog.materials[grid.material[i]]["conductivity"]), float(grid.catalog.materials[grid.material[grid.idx(n)]]["conductivity"]))
					acc += (before[id][grid.idx(n)] - v) * k / 4.0
				v += acc * minf(ts, 2.0)
			v += (dflt - v) * minf(recover * ts, 1.0)
			grid.set_var(p, id, v)

static func _cond_ok(grid: Grid, p: Vector2i, cond: Dictionary, mat_snapshot: Array = []) -> bool:
	if cond.has("material"):
		return grid.get_material(p) == cond["material"]
	if cond.has("neighbor_material"):
		# neighbours are read from the start-of-step snapshot so spread has no scan-order bias
		for n in grid.neighbors4(p):
			var m: String = mat_snapshot[grid.idx(n)] if not mat_snapshot.is_empty() else grid.get_material(n)
			if m == cond["neighbor_material"]:
				return true
		return false
	if cond.has("var"):
		var v = grid.get_var(p, cond["var"])
		if v is Vector2:
			v = v.length()
		var x := float(cond.get("value", 0))
		match cond.get("op", ">="):
			"<": return v < x
			">=": return v >= x
			"==": return is_equal_approx(v, x)
			"!=": return not is_equal_approx(v, x)
	if cond.has("status"):
		var u = grid.unit_at(p)
		return u != null and u.has_status(cond["status"])
	return false

static func cond_all(grid: Grid, p: Vector2i, conds: Array, mat_snapshot: Array = []) -> bool:
	for cond in conds:
		if not _cond_ok(grid, p, cond, mat_snapshot):
			return false
	return true

static func _react_cell(grid: Grid, catalog: Catalog, p: Vector2i, log: Array, mat_before: Array = []) -> void:
	var fired_once := {}
	var applied := 0
	var again := true
	while again:
		again = false
		for r in catalog.reactions:
			var changes_material := false
			for act in r.get("then", []):
				if act.has("set_material"):
					changes_material = true
			if not changes_material and fired_once.has(r["id"]):
				continue
			if not cond_all(grid, p, r.get("when", []), mat_before):
				continue
			if applied >= CHAIN_CAP:
				log.append({"t": "chain_cap", "msg": "연쇄 상한 %s" % str(p), "data": {"cell": p}})
				return
			var before_mat := grid.get_material(p)
			_apply_actions(grid, p, r, log)
			applied += 1
			fired_once[r["id"]] = true
			log.append({"t": "reaction", "msg": r["id"], "data": {"id": r["id"], "cell": p}})
			if grid.get_material(p) != before_mat:
				again = true
				break

static func _apply_actions(grid: Grid, p: Vector2i, r: Dictionary, log: Array) -> void:
	for act in r.get("then", []):
		if act.has("set_material"):
			grid.set_material(p, act["set_material"])
		elif act.has("add_var"):
			grid.add_var(p, act["add_var"], act["value"])
		elif act.has("status_to_units"):
			var u = grid.unit_at(p)
			if u != null:
				u.add_status(act["status_to_units"], int(act.get("turns", 1)))
		elif act.has("damage_units"):
			var u2 = grid.unit_at(p)
			if u2 != null:
				var d: int = u2.take_damage(int(act["damage_units"]), act.get("kind", "physical"))
				log.append({"t": "damage", "msg": "%s %d" % [u2.name, d], "data": {"uid": u2.uid, "amount": d, "source": r["id"]}})

static func _enter_effects(grid: Grid, log: Array) -> void:
	for u in grid.units:
		var st = grid.mat_def(u.pos).get("status_on_enter", "")
		if st != "":
			u.add_status(st, 2)

static func friction_at(grid: Grid, p: Vector2i) -> float:
	var md := grid.mat_def(p)
	if md.has("friction_override"):
		return float(md["friction_override"])
	return float(grid.get_var(p, "friction"))

static func force_at(grid: Grid, p: Vector2i) -> Vector2:
	var f: Vector2 = grid.get_var(p, "gravity") + grid.get_var(p, "wind")
	var here := float(grid.get_var(p, "pressure"))
	for n in grid.neighbors4(p):
		var diff := here - float(grid.get_var(n, "pressure"))
		if diff > 0:
			f += Vector2(n - p) * diff * 0.5
	return f

static func _forces(grid: Grid, log: Array) -> void:
	for u in grid.units.duplicate():
		if not u.alive() or _ts(grid, u.pos) <= 0.0:
			continue
		var f := force_at(grid, u.pos)
		if f.length() < u.mass or f.length() < 0.01:
			continue
		var dir := Vector2i(signi(int(round(f.x))), 0) if absf(f.x) >= absf(f.y) else Vector2i(0, signi(int(round(f.y))))
		var dist: int = clampi(int(f.length() / u.mass), 1, 3)
		push_unit(grid, u, dir, dist, log)

## Moves u up to dist cells along dir (sliding further on low friction). Handles walls, units, void.
static func push_unit(grid: Grid, u, dir: Vector2i, dist: int, log: Array) -> void:
	if dir == Vector2i.ZERO or dist <= 0:
		return
	var moved := 0
	while true:
		var keep_going := moved < dist or (friction_at(grid, u.pos) < 0.5 and moved < MAX_SLIDE)
		if not keep_going:
			break
		var nxt: Vector2i = u.pos + dir
		if not grid.in_bounds(nxt):
			break
		if not grid.passable(nxt) or (grid.unit_at(nxt) != null and grid.unit_at(nxt) != u):
			var dmg: int = max(1, int(round(u.mass * max(1, dist - moved))))
			var d: int = u.take_damage(dmg, "physical")
			log.append({"t": "collision", "msg": "%s 충돌 %d" % [u.name, d], "data": {"uid": u.uid, "amount": d}})
			var other = grid.unit_at(nxt)
			if other != null:
				other.take_damage(max(1, dmg / 2), "physical")
			return
		if grid.mat_def(nxt).get("lethal", false):
			if u.is_boss:
				var bd: int = int(round(u.max_hp * 0.3))
				u.hp = max(0, u.hp - bd)
				log.append({"t": "void", "msg": "%s 공허 가장자리 %d" % [u.name, bd], "data": {"uid": u.uid, "amount": bd}})
			else:
				u.hp = 0
				grid.move_unit(u, nxt)
				log.append({"t": "void", "msg": "%s 공허로 추락" % u.name, "data": {"uid": u.uid}})
			return
		grid.move_unit(u, nxt)
		moved += 1
	if moved > 0:
		log.append({"t": "moved", "msg": "%s 밀려남 %d" % [u.name, moved], "data": {"uid": u.uid, "to": u.pos}})
