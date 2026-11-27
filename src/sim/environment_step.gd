class_name EnvironmentStep
extends RefCounted
## One world update: statuses tick, reactions (capped) where states and materials meet, forces move
## units, then cell states run down their seconds.

const CHAIN_CAP := 8
const MAX_SLIDE := 9
const REACTION_NAME := {"gas_explodes": "가스 폭발", "blaze_burns": "업화", "crystal_shatters": "메아리에 수정 깨짐",
	"collapse_crushes": "붕괴", "water_shocks": "물에 감전", "curse_hurts": "저주"}
const STATUS_NAME := {"burning": "화상", "poisoned": "중독"}
const STATUS_DOT := {"burning": [3, "fire"], "poisoned": [2, "toxic"]}

## tick_statuses: statuses (and their damage over time) advance once per round, so Battle passes
## false for the step between the player's and the enemy's turn.
static func run(grid: Grid, catalog: Catalog, rng: SimRng, log: Array, tick_statuses := true, secs := 2.0) -> void:
	if tick_statuses:
		_tick_statuses(grid, log)
	flow_charge(grid)
	var mat_before: Array = grid.material.duplicate()
	for p in grid.all_cells():
		if _ts(grid, p) > 0.0:
			_react_cell(grid, catalog, p, log, mat_before)
	_enter_effects(grid, log)
	_forces(grid, log)
	_run_down(grid, catalog, secs)

static func _ts(grid: Grid, p: Vector2i) -> float:
	return grid.time_scale(p)

static func _tick_statuses(grid: Grid, log: Array) -> void:
	for u in grid.units:
		if not u.alive():
			continue
		for s in STATUS_DOT:
			if u.has_status(s):
				var d: int = u.take_damage(STATUS_DOT[s][0], STATUS_DOT[s][1])
				log.append({"t": "status_damage", "msg": "%s → %s  %d" % [STATUS_NAME.get(s, s), u.name, d], "data": {"uid": u.uid, "status": s, "amount": d}})
		for s in u.statuses.keys():
			u.statuses[s] -= 1
			if u.statuses[s] <= 0:
				u.statuses.erase(s)

## States wear off after their seconds. Time states always run down (stopped time ends);
## anything else in a cell runs at that cell's time speed, so it lingers in stopped time.
static func _run_down(grid: Grid, catalog: Catalog, secs: float) -> void:
	for p in grid.all_cells():
		var st: Dictionary = grid.cell_states[grid.idx(p)]
		if st.is_empty():
			continue
		var ts := grid.time_scale(p)
		for id in st.keys():
			var timeish: bool = catalog.states.get(id, {}).has("time")
			st[id]["left"] = float(st[id]["left"]) - secs * (1.0 if timeish else ts)
			if float(st[id]["left"]) <= 0.0:
				st.erase(id)

## [전기] runs at once through every touching cell of water, swamp, metal or [습기].
static func flow_charge(grid: Grid) -> void:
	var todo: Array = []
	for p in grid.all_cells():
		if grid.has_state(p, "charged"):
			todo.append(p)
	while not todo.is_empty():
		var p: Vector2i = todo.pop_back()
		var left := float(grid.cell_states[grid.idx(p)]["charged"]["left"])
		for n in grid.neighbors4(p):
			if grid.has_state(n, "charged") or not conducts(grid, n):
				continue
			grid.add_state(n, "charged", left)
			todo.append(n)

static func conducts(grid: Grid, p: Vector2i) -> bool:
	return grid.get_material(p) in ["water", "swamp", "metal"] or grid.has_state(p, "damp")

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
	if cond.has("state"):
		return grid.has_state(p, cond["state"])
	if cond.has("no_state"):
		return not grid.has_state(p, cond["no_state"])
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
		elif act.has("add_state"):
			grid.add_state(p, act["add_state"])
		elif act.has("clear_state"):
			grid.clear_state(p, act["clear_state"])
		elif act.has("status_to_units"):
			var u = grid.unit_at(p)
			if u != null:
				u.add_status(act["status_to_units"], int(act.get("turns", 1)))
		elif act.has("damage_units"):
			var u2 = grid.unit_at(p)
			if u2 != null:
				var d: int = u2.take_damage(int(act["damage_units"]), act.get("kind", "physical"))
				log.append({"t": "damage", "msg": "칸 반응(%s) → %s  %d" % [REACTION_NAME.get(r["id"], r["id"]), u2.name, d], "data": {"uid": u2.uid, "amount": d, "source": r["id"]}})

static func _enter_effects(grid: Grid, log: Array) -> void:
	for u in grid.units:
		var st = grid.mat_def(u.pos).get("status_on_enter", "")
		if st != "":
			u.add_status(st, 2)

static func friction_at(grid: Grid, p: Vector2i) -> float:
	var md := grid.mat_def(p)
	if md.has("friction_override"):
		return float(md["friction_override"])
	return 0.2 if grid.has_state(p, "slick") else 1.0

## The push on a unit in this cell: [돌풍], [중력] and [짓누름] each shove along their direction.
static func force_at(grid: Grid, p: Vector2i) -> Vector2:
	var f := Vector2.ZERO
	if not grid.in_bounds(p):
		return f
	var st: Dictionary = grid.cell_states[grid.idx(p)]
	for id in st:
		var push := float(grid.catalog.states.get(id, {}).get("push", 0))
		if push > 0.0:
			f += Vector2(st[id]["dir"]) * push
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
			if grid.get_material(nxt) == "crystal":
				# slamming into a crystal breaks it
				grid.set_material(nxt, "none")
				grid.shatter_queue.append(nxt)
			var d: int = u.take_damage(dmg, "physical")
			var hitwhat: String = grid.unit_at(nxt).name if grid.unit_at(nxt) != null else "벽"
			log.append({"t": "collision", "msg": "밀려 부딪힘(%s) → %s  %d" % [hitwhat, u.name, d], "data": {"uid": u.uid, "amount": d}})
			var other = grid.unit_at(nxt)
			if other != null:
				var od: int = other.take_damage(max(1, dmg / 2), "physical")
				log.append({"t": "collision", "msg": "%s가 부딪혀 옴 → %s  %d" % [u.name, other.name, od], "data": {"uid": other.uid, "amount": od}})
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
