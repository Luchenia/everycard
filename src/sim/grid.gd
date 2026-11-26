class_name Grid
extends RefCounted
## Battlefield state: per-cell variable values, per-cell material, unit positions.
## Units are any object with a `pos: Vector2i` field (Actor in practice).

static var W := 9   # set from data/battle.json by Battle
static var H := 7

var catalog: Catalog
var values: Dictionary = {}   # var id -> Array (scalar float or Vector2), index = y * W + x
var material: Array = []      # material id per cell
var units: Array = []         # units on the grid
var shatter_queue: Array = []  # crystal cells broken by the environment; Battle throws their shards

func _init(cat: Catalog) -> void:
	catalog = cat
	for id in catalog.variables:
		var arr := []
		arr.resize(W * H)
		arr.fill(_default(id))
		values[id] = arr
	material.resize(W * H)
	material.fill("none")

func _default(id: String):
	var d = catalog.variables[id]["default"]
	if catalog.variables[id]["kind"] == "vector":
		return Vector2(d[0], d[1])
	return float(d)

func default_of(id: String):
	return _default(id)

func idx(p: Vector2i) -> int:
	return p.y * W + p.x

func in_bounds(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < W and p.y < H

func get_var(p: Vector2i, id: String):
	return values[id][idx(p)]

func set_var(p: Vector2i, id: String, v) -> void:
	if not in_bounds(p) or not values.has(id):
		return
	var def: Dictionary = catalog.variables[id]
	if def["kind"] == "vector":
		var vec: Vector2 = v
		values[id][idx(p)] = vec.limit_length(float(def["max"]))
	else:
		values[id][idx(p)] = clampf(float(v), float(def["min"]), float(def["max"]))

func add_var(p: Vector2i, id: String, delta) -> void:
	if not in_bounds(p) or not values.has(id):
		return
	set_var(p, id, get_var(p, id) + delta)

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

## Snapshot of cell values, materials and unit positions (not unit stats).
func duplicate_state() -> Dictionary:
	var vals := {}
	for id in values:
		vals[id] = values[id].duplicate()
	var pos := []
	for u in units:
		pos.append([u, u.pos])
	return {"values": vals, "material": material.duplicate(), "units": pos}

func restore_state(d: Dictionary) -> void:
	for id in d["values"]:
		values[id] = d["values"][id].duplicate()
	material = d["material"].duplicate()
	units = []
	for pair in d["units"]:
		pair[0].pos = pair[1]
		units.append(pair[0])
