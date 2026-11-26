class_name Grid
extends RefCounted
## Battlefield state: per-cell states (on/off), per-cell material, unit positions.
## Units are any object with a `pos: Vector2i` field (Actor in practice).

static var W := 9   # set from data/battle.json by Battle
static var H := 7

var catalog: Catalog
var cell_states: Array = []   # per cell: state id -> {"left": seconds, "dir": Vector2i}; index = y * W + x
var material: Array = []      # material id per cell
var units: Array = []         # units on the grid
var shatter_queue: Array = []  # crystal cells broken by the environment; Battle throws their shards
var trap_queue: Array = []     # units that stepped on a trap; Battle springs them

func _init(cat: Catalog) -> void:
	catalog = cat
	cell_states.resize(W * H)
	for i in W * H:
		cell_states[i] = {}
	material.resize(W * H)
	material.fill("none")

func idx(p: Vector2i) -> int:
	return p.y * W + p.x

func in_bounds(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < W and p.y < H

## Cell states are on or off: [열기], [돌풍 →], [멈춘 시간]... Each lasts a few seconds.
func has_state(p: Vector2i, id: String) -> bool:
	return in_bounds(p) and cell_states[idx(p)].has(id)

func states_at(p: Vector2i) -> Array:
	return cell_states[idx(p)].keys() if in_bounds(p) else []

func state_dir(p: Vector2i, id: String) -> Vector2i:
	return cell_states[idx(p)][id]["dir"] if has_state(p, id) else Vector2i.ZERO

## Puts a state on a cell (refreshing its time). Opposite states cancel out instead
## ([열기] on [냉기] leaves neither). With stack, a state laid on itself grows into its
## stronger form ([열기] again -> [업화]).
func add_state(p: Vector2i, id: String, secs := -1.0, dir := Vector2i.ZERO, stack := false) -> void:
	if not in_bounds(p) or not catalog.states.has(id):
		return
	var def: Dictionary = catalog.states[id]
	var st: Dictionary = cell_states[idx(p)]
	for o in def.get("opposes", []):
		if st.has(o):
			st.erase(o)
			if def.has("time"):
				continue   # time states replace each other
			return
	if stack and st.has(id) and def.has("upgrade"):
		st.erase(id)
		id = def["upgrade"]
		def = catalog.states[id]
	var t := secs if secs > 0.0 else float(def.get("secs", 4))
	if st.has(id):
		st[id]["left"] = maxf(float(st[id]["left"]), t)
		if dir != Vector2i.ZERO:
			st[id]["dir"] = dir
	else:
		st[id] = {"left": t, "dir": dir}

func clear_state(p: Vector2i, id: String) -> void:
	if in_bounds(p):
		cell_states[idx(p)].erase(id)

## How fast time runs in a cell: [멈춘 시간] 0, [느림] or 늪 0.5, [가속] 1.5, otherwise 1.
func time_scale(p: Vector2i) -> float:
	if not in_bounds(p):
		return 1.0
	var st: Dictionary = cell_states[idx(p)]
	for id in st:
		var def: Dictionary = catalog.states.get(id, {})
		if def.has("time"):
			return float(def["time"])
	if material[idx(p)] == "swamp":
		return 0.5
	return 1.0

func get_material(p: Vector2i) -> String:
	return material[idx(p)]

func set_material(p: Vector2i, id: String) -> void:
	if in_bounds(p):
		material[idx(p)] = id

func mat_def(p: Vector2i) -> Dictionary:
	return catalog.materials.get(get_material(p), {})

func passable(p: Vector2i) -> bool:
	return in_bounds(p) and mat_def(p).get("passable", true)

func unit_at(p: Vector2i):
	for u in units:
		if u.pos == p:
			return u
	return null

func place_unit(u, p: Vector2i) -> bool:
	if not passable(p) or unit_at(p) != null:
		return false
	u.pos = p
	if not units.has(u):
		units.append(u)
	return true

func move_unit(u, p: Vector2i) -> bool:
	if not passable(p):
		return false
	var other = unit_at(p)
	if other != null and other != u:
		return false
	u.pos = p
	if mat_def(p).has("trap"):
		trap_queue.append(u)
	return true

func remove_unit(u) -> void:
	units.erase(u)

func neighbors4(p: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		if in_bounds(p + d):
			out.append(p + d)
	return out

func all_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in H:
		for x in W:
			out.append(Vector2i(x, y))
	return out

## Snapshot of cell states, materials and unit positions (not unit stats).
func duplicate_state() -> Dictionary:
	var pos := []
	for u in units:
		pos.append([u, u.pos])
	return {"states": cell_states.duplicate(true), "material": material.duplicate(), "units": pos}

func restore_state(d: Dictionary) -> void:
	cell_states = d["states"].duplicate(true)
	material = d["material"].duplicate()
	units = []
	for pair in d["units"]:
		pair[0].pos = pair[1]
		units.append(pair[0])
