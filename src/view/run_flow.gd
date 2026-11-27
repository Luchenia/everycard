class_name RunFlow
extends RefCounted
## A run is a row of battles, one after another, with a 1-of-3 card reward after each and the
## boss last. (The floor of connected rooms was tried and set aside: the battles are the game.)
## Each battle is fought on its own arena with a theme that lays a few materials and lasting cell
## states. The player keeps their deck, hp and body (a body swap carries over).

const START_BODY := "walker"
const FIGHTS := [
	{"enemies": ["slime", "slime"], "theme": "stone"},
	{"enemies": ["ember_imp", "slime"], "theme": "marsh"},
	{"enemies": ["iron_golem"], "theme": "frost"},
	{"enemies": ["ember_imp", "iron_golem"], "theme": "ember"},
	{"enemies": ["slime", "ember_imp", "slime"], "theme": "crystal"},
	{"enemies": ["boss_tide_warden"], "theme": "stone", "boss": true},
]
const THEME_POOL := {
	"stone": ["wall", "wall", "crystal", "water"],
	"frost": ["ice", "ice", "water", "wall"],
	"ember": ["wall", "wall", "crystal", "fire"],
	"marsh": ["swamp", "swamp", "water", "water"],
	"crystal": ["crystal", "crystal", "crystal", "metal"],
}
const THEME_STATE := {"frost": "cold", "ember": "heat", "marsh": "damp", "crystal": "mana"}
const PRICE := {"basic": 30, "common": 40, "rare": 70, "legendary": 120}
const HEAL_PRICE := 25
const HEAL_AMOUNT := 15

var catalog: Catalog
var seed_value: int
var rng: SimRng
var phase := "battle"   # battle | reward | shop | game_over | victory
var battle: Battle
var index := 0          # which battle of FIGHTS
var body_def := START_BODY
var deck: Array = []
var hp := -1
var gold := 0
var rewards: Array = []
var shop_stock: Dictionary = {}
var exit_dir := Vector2i.ZERO   # kept for the screen: a run of battles never walks out through a door
var _cleared := false

func _init(cat: Catalog, s: int) -> void:
	catalog = cat
	seed_value = s
	rng = SimRng.new(s)
	deck = Array(catalog.actors[START_BODY]["deck"]).duplicate()
	start_battle(0)

func fight() -> Dictionary:
	return FIGHTS[index]

static func size() -> Vector2i:
	return Vector2i(Grid.W, Grid.H)

## True while nothing on the board is fighting.
func calm() -> bool:
	return battle != null and not battle.actors.any(func(a): return a.alive() and a.team == 1 and battle.grid.units.has(a))

## Starts battle i of the run: the player on the left, the monsters on the right, the arena's theme
## scattered between.
func start_battle(i: int) -> void:
	index = clampi(i, 0, FIGHTS.size() - 1)
	_cleared = false
	var f: Dictionary = fight()
	var w := int(catalog.config.get("grid_w", 15))
	var h := int(catalog.config.get("grid_h", 9))
	var mid := Vector2i(w / 2, h / 2)
	var player := Vector2i(2, mid.y)
	var reserved := {player: true}
	var enemy_pos := []
	var offs := [0, -2, 2, -4, 4]
	var foes: Array = f["enemies"]
	for k in foes.size():
		var p := Vector2i(w - 3, clampi(mid.y + offs[k % offs.size()], 1, h - 2))
		enemy_pos.append([p.x, p.y])
		reserved[p] = true
	var lr := SimRng.new(seed_value * 1000 + index * 37)
	var pool: Array = THEME_POOL.get(f["theme"], THEME_POOL["stone"])
	var mats := []
	for k in 10:
		var p := Vector2i(1 + lr.next_int(w - 2), 1 + lr.next_int(h - 2))
		if reserved.has(p) or p.distance_to(player) < 2.0:
			continue
		mats.append([p.x, p.y, pool[lr.next_int(pool.size())]])
		reserved[p] = true
	var states := []
	if THEME_STATE.has(f["theme"]):
		for k in 7:
			var p := Vector2i(lr.next_int(w), lr.next_int(h))
			if not reserved.has(p):
				states.append([p.x, p.y, THEME_STATE[f["theme"]], 9999])
	var lay := {"player_pos": [player.x, player.y], "enemy_pos": enemy_pos, "materials": mats, "states": states}
	battle = Battle.new(catalog, seed_value * 100 + index, body_def, foes, lay)
	battle.stays_open = true
	var me := battle.human()
	me.deck = deck.duplicate()
	if hp > 0:
		me.hp = mini(hp, me.max_hp)
	battle._rebuild_belt()
	exit_dir = Vector2i.ZERO
	phase = "battle"

## Call after every command; moves the run forward (battle won, death).
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
	if not _cleared and calm():
		_cleared = true
		gold += 10 + rng.next_int(11)
		if fight().get("boss", false) or index >= FIGHTS.size() - 1:
			phase = "victory"
			return
		rewards = _pick_rewards(_reward_pool(), 3)
		phase = "reward"

## Takes reward i (-1 skips it) and starts the next battle.
func choose_reward(i: int) -> void:
	if phase != "reward":
		return
	if i >= 0 and i < rewards.size():
		_gain(rewards[i])
	rewards = []
	start_battle(index + 1)

func _gain(id: String) -> void:
	deck.append(id)
	var me := battle.human()
	if me != null:
		me.deck.append(id)
		battle._rebuild_belt()

# ---- shop ---------------------------------------------------------------------------------------

func _stock() -> void:
	var at := index
	if shop_stock.has(at):
		return
	var items := []
	for id in _pick_rewards(_reward_pool(), 4):
		items.append({"id": id, "price": int(PRICE.get(catalog.cards[id].get("rarity", "common"), 40)), "sold": false})
	shop_stock[at] = items

func stock() -> Array:
	return shop_stock.get(index, [])

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
