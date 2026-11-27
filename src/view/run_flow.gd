class_name RunFlow
extends RefCounted
## A run is one floor of rooms (Dungeon). Each room is a board: fights seal their doors until the
## room is cleared, but the door you came in by stays open, so you can always flee (the monsters
## stay, with the wounds you gave them). Chests, the shop and the spring are cells you step on.
## The player keeps their deck, hp, gold and body (a body swap carries over).

const START_BODY := "walker"
const THEME_POOL := {
	"stone": ["wall", "wall", "crystal", "water"],
	"frost": ["ice", "ice", "water", "wall"],
	"ember": ["wall", "wall", "crystal", "fire"],
	"marsh": ["swamp", "swamp", "water", "water"],
	"crystal": ["crystal", "crystal", "crystal", "metal"],
}
const THEME_STATE := {"frost": "cold", "ember": "heat", "marsh": "damp", "crystal": "mana"}
const THEME_NAME := {"stone": "돌방", "frost": "서리 방", "ember": "잿불 방", "marsh": "늪 방", "crystal": "수정 방"}
const KIND_NAME := {"start": "", "fight": "", "boss": "보스", "chest": "보물 상자", "shop": "상점", "spring": "샘"}
const FEATURE := {"chest": "chest", "shop": "stall", "spring": "spring"}
const PRICE := {"basic": 30, "common": 40, "rare": 70, "legendary": 120}
const HEAL_PRICE := 25
const HEAL_AMOUNT := 15

var catalog: Catalog
var seed_value: int
var rng: SimRng
var phase := "battle"   # battle (in a room) | reward | shop | game_over | victory
var battle: Battle
var dungeon: Dungeon
var at := Vector2i.ZERO        # room the player is in
var came_from := Vector2i.ZERO # direction the player walked in (ZERO in the start room)
var body_def := START_BODY
var deck: Array = []
var hp := -1
var gold := 0
var rewards: Array = []
var shop_stock: Dictionary = {}   # room -> [{id, price, sold}]
var exit_dir := Vector2i.ZERO     # set when the player steps on an open door; the screen slides over
var _last_pos := Vector2i(-1, -1)
var index := 0                    # rooms cleared (kept for old HUD code)

func _init(cat: Catalog, s: int) -> void:
	catalog = cat
	seed_value = s
	rng = SimRng.new(s)
	deck = Array(catalog.actors[START_BODY]["deck"]).duplicate()
	dungeon = Dungeon.new(s)
	at = dungeon.start
	_enter(Vector2i.ZERO)

func room() -> Dictionary:
	return dungeon.rooms[at]

static func size() -> Vector2i:
	return Vector2i(Grid.W, Grid.H)

static func door_cell(d: Vector2i, w: int, h: int) -> Vector2i:
	match d:
		Vector2i.UP: return Vector2i(w / 2, 0)
		Vector2i.DOWN: return Vector2i(w / 2, h - 1)
		Vector2i.LEFT: return Vector2i(0, h / 2)
		_: return Vector2i(w - 1, h / 2)

## True while nothing in the room is fighting: walking is quick and needs no planning.
func calm() -> bool:
	return battle != null and not battle.actors.any(func(a): return a.alive() and a.team == 1 and battle.grid.units.has(a))

func _door_open(d: Vector2i) -> bool:
	return room()["cleared"] or d == -came_from

func _enter(from_dir: Vector2i) -> void:
	came_from = from_dir
	var r := room()
	r["visited"] = true
	var w := int(catalog.config.get("grid_w", 15))
	var h := int(catalog.config.get("grid_h", 9))
	var mid := Vector2i(w / 2, h / 2)
	var player := mid if from_dir == Vector2i.ZERO else door_cell(-from_dir, w, h) + from_dir
	var reserved := {player: true, mid: true}
	var mats := []
	for d in dungeon.doors(at):
		var dc := door_cell(d, w, h)
		mats.append([dc.x, dc.y, "door" if _door_open(d) else "door_sealed"])
		reserved[dc] = true
		reserved[dc - d] = true
	# monsters wait on the far side from the door the player came through
	var foes: Array = r["enemies"].filter(func(e): return int(e["hp"]) != 0)
	var enemy_pos := []
	var far: Vector2i = mid + from_dir * (mid.x - 2 if from_dir.x != 0 else mid.y - 1)
	if from_dir == Vector2i.ZERO:
		far = Vector2i(w - 3, mid.y)
	var side := Vector2i(from_dir.y, from_dir.x) if from_dir != Vector2i.ZERO else Vector2i(0, 1)
	var offs := [0, -2, 2, -4, 4]
	for i in foes.size():
		var p: Vector2i = far + side * offs[i % offs.size()]
		p = Vector2i(clampi(p.x, 1, w - 2), clampi(p.y, 1, h - 2))
		enemy_pos.append([p.x, p.y])
		reserved[p] = true
	if FEATURE.has(r["kind"]):
		var f: String = FEATURE[r["kind"]]
		if r["used"] and f != "stall":
			f = {"chest": "chest_open", "spring": "spring_dry"}[f]
		mats.append([mid.x, mid.y, f])
	# the room's own look: a few materials and lasting cell states from its theme
	var lr := SimRng.new(seed_value * 1000 + at.y * 31 + at.x)
	var pool: Array = THEME_POOL.get(r["theme"], THEME_POOL["stone"])
	for k in 10:
		var p := Vector2i(1 + lr.next_int(w - 2), 1 + lr.next_int(h - 2))
		if reserved.has(p) or p.distance_to(player) < 2.0:
			continue
		mats.append([p.x, p.y, pool[lr.next_int(pool.size())]])
		reserved[p] = true
	var states := []
	if THEME_STATE.has(r["theme"]):
		for k in 7:
			var p := Vector2i(lr.next_int(w), lr.next_int(h))
			if not reserved.has(p):
				states.append([p.x, p.y, THEME_STATE[r["theme"]], 9999])
	var lay := {"player_pos": [player.x, player.y], "enemy_pos": enemy_pos, "materials": mats, "states": states}
	battle = Battle.new(catalog, seed_value * 100 + dungeon.rooms.size() * at.y + at.x + index * 7, body_def,
		foes.map(func(e): return e["def"]), lay)
	battle.stays_open = true
	var me := battle.human()
	me.deck = deck.duplicate()
	if hp > 0:
		me.hp = mini(hp, me.max_hp)
	var j := 0
	for a in battle.actors:
		if a.team == 1:
			if j < foes.size() and int(foes[j]["hp"]) > 0:
				a.hp = mini(int(foes[j]["hp"]), a.max_hp)
			j += 1
	battle._rebuild_belt()
	_last_pos = player
	exit_dir = Vector2i.ZERO
	phase = "battle"

## Walk through the door in direction d (after the screen's slide). Leaving a fight early keeps
## the monsters and their wounds in that room.
func go(d: Vector2i) -> void:
	var r := room()
	if not r["cleared"]:
		var left := []
		for a in battle.actors:
			if a.team == 1 and a.alive() and battle.grid.units.has(a):
				left.append({"def": a.def_id, "hp": a.hp, "max": a.max_hp, "split": a.split_done})
		r["enemies"] = left
	at += d
	_enter(d)

## Call after every command; moves the run forward (room cleared, chest, shop, door, death).
func update() -> void:
	if phase != "battle":
		return
	if battle.phase == "lost" or battle.human() == null:
		phase = "game_over"
		return
	var me := battle.human()
	body_def = me.def_id
	deck = me.deck.duplicate()
	hp = me.hp
	var r := room()
	if not r["cleared"] and calm():
		r["cleared"] = true
		r["enemies"] = []
		index += 1
		_open_doors()
		gold += 10 + rng.next_int(11)
		if r["kind"] == "boss":
			phase = "victory"
			return
		rewards = _pick_rewards(_reward_pool(), 3)
		phase = "reward"
		return
	var arrived := me.pos != _last_pos
	_last_pos = me.pos
	if not arrived:
		return
	var m := battle.grid.get_material(me.pos)
	match m:
		"chest":
			r["used"] = true
			battle.grid.set_material(me.pos, "chest_open")
			gold += 15 + rng.next_int(11)
			rewards = _pick_rewards(_reward_pool(), 3)
			phase = "reward"
		"spring":
			r["used"] = true
			battle.grid.set_material(me.pos, "spring_dry")
			me.hp = mini(me.max_hp, me.hp + int(me.max_hp * 0.3))
			hp = me.hp
		"stall":
			_stock()
			phase = "shop"
		"door":
			for d in dungeon.doors(at):
				if door_cell(d, Grid.W, Grid.H) == me.pos:
					exit_dir = d

func _open_doors() -> void:
	for d in dungeon.doors(at):
		var dc := door_cell(d, Grid.W, Grid.H)
		if battle.grid.get_material(dc) == "door_sealed":
			battle.grid.set_material(dc, "door")

func choose_reward(i: int) -> void:
	if phase != "reward":
		return
	if i >= 0 and i < rewards.size():
		_gain(rewards[i])
	rewards = []
	phase = "battle"

func _gain(id: String) -> void:
	deck.append(id)
	var me := battle.human()
	if me != null:
		me.deck.append(id)
		battle._rebuild_belt()

# ---- shop ---------------------------------------------------------------------------------------

func _stock() -> void:
	if shop_stock.has(at):
		return
	var items := []
	for id in _pick_rewards(_reward_pool(), 4):
		items.append({"id": id, "price": int(PRICE.get(catalog.cards[id].get("rarity", "common"), 40)), "sold": false})
	shop_stock[at] = items

func stock() -> Array:
	return shop_stock.get(at, [])

func buy(i: int) -> bool:
	var items := stock()
	if phase != "shop" or i < 0 or i >= items.size() or items[i]["sold"] or gold < int(items[i]["price"]):
		return false
	gold -= int(items[i]["price"])
	items[i]["sold"] = true
	_gain(items[i]["id"])
	return true

func buy_heal() -> bool:
	var me := battle.human()
	if phase != "shop" or gold < HEAL_PRICE or me == null or me.hp >= me.max_hp:
		return false
	gold -= HEAL_PRICE
	me.hp = mini(me.max_hp, me.hp + HEAL_AMOUNT)
	hp = me.hp
	return true

func leave_shop() -> void:
	if phase == "shop":
		phase = "battle"

# ---- card rewards -------------------------------------------------------------------------------

## Reward cards: the player-card list, limited to the pools of the body being played
## (도적: wanderer + common; 점화, 서릿발 ... are kept for a mage-type character).
func _reward_pool() -> Array:
	var allowed: Array = catalog.actors.get(body_def, {}).get("pools", [])
	var pool := []
	for id in catalog.player_cards:
		if not catalog.cards.has(id):
			continue
		if allowed.is_empty() or catalog.cards[id].get("pool", "common") in allowed:
			pool.append(id)
	pool.sort()
	return pool

const RARITY_WEIGHT := {"basic": 10.0, "common": 10.0, "rare": 4.0, "legendary": 1.0}

## Draws n different cards, rarer ones less often; a card's own "drop_weight" scales it further
## (판 뒤집기 is a legendary that should feel extremely rare).
func _pick_rewards(pool: Array, n: int) -> Array:
	var left := pool.duplicate()
	var out := []
	while out.size() < n and not left.is_empty():
		var total := 0.0
		for id in left:
			total += _weight(id)
		var r := rng.next_float() * total
		var pick: String = left[left.size() - 1]
		for id in left:
			r -= _weight(id)
			if r <= 0.0:
				pick = id
				break
		out.append(pick)
		left.erase(pick)
	return out

func _weight(id: String) -> float:
	var c: Dictionary = catalog.cards.get(id, {})
	return float(RARITY_WEIGHT.get(c.get("rarity", "common"), 10.0)) * float(c.get("drop_weight", 1.0))
