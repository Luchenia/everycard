class_name Dungeon
extends RefCounted
## One floor of rooms on a small grid. Rooms touch through doors (up to four: up, down, left,
## right). The start room is empty, the boss room is the farthest dead end, and the floor holds a
## shop, a chest room and a spring; the rest are fights that get harder further from the start.
## Each room has a theme that lays its own materials and lasting cell states.

const SIZE := 7
const DIRS := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
const THEMES := ["stone", "frost", "ember", "marsh", "crystal"]
## Enemy groups by how far the room is from the start (in rooms).
const NEAR := [["slime"], ["slime", "slime"], ["ember_imp"]]
const MID := [["ember_imp", "slime"], ["iron_golem"], ["slime", "slime", "ember_imp"]]
const FAR := [["ember_imp", "iron_golem"], ["iron_golem", "slime", "slime"]]
const BOSS := ["boss_tide_warden"]

var rooms: Dictionary = {}   # Vector2i -> {kind, theme, depth, enemies: [{def, hp}], cleared, visited, used}
var start := Vector2i(3, 3)
var boss_at := Vector2i(-1, -1)
var rng: SimRng

func _init(seed_value: int, count := 10) -> void:
	rng = SimRng.new(seed_value)
	_grow(count)
	_assign()

func _grow(count: int) -> void:
	rooms[start] = _room("start", 0)
	var tries := 0
	while rooms.size() < count and tries < 500:
		tries += 1
		var keys := rooms.keys()
		var from: Vector2i = keys[rng.next_int(keys.size())]
		var to: Vector2i = from + DIRS[rng.next_int(4)]
		if rooms.has(to) or to.x < 0 or to.y < 0 or to.x >= SIZE or to.y >= SIZE:
			continue
		# keep the floor stringy, not a blob: a new room may touch only the room it grows from
		var touching := 0
		for d in DIRS:
			if rooms.has(to + d):
				touching += 1
		if touching > 1:
			continue
		rooms[to] = _room("fight", rooms[from]["depth"] + 1)

func _room(kind: String, depth: int) -> Dictionary:
	return {"kind": kind, "theme": "stone", "depth": depth, "enemies": [], "cleared": kind != "fight",
		"visited": false, "used": false}

func _assign() -> void:
	# boss: the farthest dead end
	var best := start
	for p in rooms:
		if doors(p).size() == 1 and p != start and rooms[p]["depth"] >= rooms[best]["depth"]:
			best = p
	boss_at = best
	rooms[best]["kind"] = "boss"
	rooms[best]["cleared"] = false
	var others: Array = rooms.keys().filter(func(p): return p != start and p != best)
	others.sort_custom(func(a, b): return a.y * SIZE + a.x < b.y * SIZE + b.x)
	# specials on dead ends first (rooms you walk into on purpose), then anywhere
	var ends: Array = others.filter(func(p): return doors(p).size() == 1)
	var mids: Array = others.filter(func(p): return doors(p).size() > 1)
	_shuffle(ends)
	_shuffle(mids)
	var order: Array = ends + mids
	for kind in ["chest", "shop", "spring"]:
		if order.is_empty():
			break
		var p: Vector2i = order.pop_front()
		rooms[p]["kind"] = kind
		rooms[p]["cleared"] = true
	for p in rooms:
		var r: Dictionary = rooms[p]
		r["theme"] = "stone" if p == start else THEMES[rng.next_int(THEMES.size())]
		if r["kind"] == "fight":
			var d: int = r["depth"]
			var pool: Array = NEAR if d <= 1 else (MID if d <= 3 else FAR)
			r["enemies"] = (pool[rng.next_int(pool.size())] as Array).map(func(id): return {"def": id, "hp": -1})
		elif r["kind"] == "boss":
			r["enemies"] = BOSS.map(func(id): return {"def": id, "hp": -1})
	rooms[start]["visited"] = true

func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.next_int(i + 1)
		var t = a[i]
		a[i] = a[j]
		a[j] = t

## Directions that lead to another room.
func doors(p: Vector2i) -> Array:
	return DIRS.filter(func(d): return rooms.has(p + d))

## Rooms the player knows about: visited ones and the ones next to them.
func seen(p: Vector2i) -> bool:
	if not rooms.has(p):
		return false
	if rooms[p]["visited"]:
		return true
	for d in DIRS:
		if rooms.has(p + d) and rooms[p + d]["visited"]:
			return true
	return false
