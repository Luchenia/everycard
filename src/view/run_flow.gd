class_name RunFlow
extends RefCounted
## Prototype run: three fixed battles with a 1-of-3 card reward between them.
## The player keeps their deck, hp and body (a body swap carries over).

const BATTLES := [["slime", "slime"], ["ember_imp", "iron_golem"], ["boss_tide_warden"]]
const START_BODY := "walker"

var catalog: Catalog
var seed_value: int
var rng: SimRng
var index := 0
var phase := "battle"   # battle | reward | game_over | victory
var battle: Battle
var body_def := START_BODY
var deck: Array = []
var hp := -1
var rewards: Array = []

func _init(cat: Catalog, s: int) -> void:
	catalog = cat
	seed_value = s
	rng = SimRng.new(s)
	deck = Array(catalog.actors[START_BODY]["deck"]).duplicate()
	_start_battle()

func _start_battle() -> void:
	battle = Battle.new(catalog, seed_value * 100 + index, body_def, BATTLES[index], {})
	var h := battle.human()
	h.deck = deck.duplicate()
	if hp > 0:
		h.hp = mini(hp, h.max_hp)
	battle._rebuild_belt()
	phase = "battle"

## Reward cards: the player-card list, limited to the pools of the body being played
## (방랑자: wanderer + common; 점화, 서릿발 ... are kept for a mage-type character).
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

## Call after every battle command; moves the run forward when a battle ends.
func update() -> void:
	if phase != "battle":
		return
	if battle.phase == "lost":
		phase = "game_over"
	elif battle.phase == "won":
		var h := battle.human()
		body_def = h.def_id
		deck = h.deck.duplicate()
		hp = h.hp
		if index >= BATTLES.size() - 1:
			phase = "victory"
			return
		rewards = _pick_rewards(_reward_pool(), 3)
		phase = "reward"

func choose_reward(i: int) -> void:
	if phase != "reward" or i < 0 or i >= rewards.size():
		return
	deck.append(rewards[i])
	rewards = []
	index += 1
	_start_battle()
