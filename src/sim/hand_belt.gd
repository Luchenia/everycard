class_name HandBelt
extends RefCounted
## The hand. Two modes:
## - "relaxed" (default): cards stay until used. At turn end, empty slots receive floor(2 x speed)
##   draws (speed = time_scale of the player's cell). Heavy cards take two slots.
## - "lifespan": each card has its own remaining life that drops by the speed each turn end;
##   burnt-out cards leave and every empty slot refills. Heavy cards live longer.

const BASE_LIFE := 3
const HEAVY_BONUS := 2
const HOLD_BONUS := 2

var catalog: Catalog
var rng: SimRng
var slots: Array = []      # each: null or {card_id, life}
var draw_pile: Array = []
var discard: Array = []
var _hold := false
var reverse_next := false  # "reverse" meta effect: lifespan restores 1 life / relaxed draws 1 more
var mode := "relaxed"
var _bonus_draws := 0
var per_round := 2   # relaxed: draws per round at normal speed (scaled by the speed)

func _init(deck: Array, r: SimRng, cat: Catalog, size := 5, shuffle_deck := true, hand_mode := "relaxed") -> void:
	mode = hand_mode
	catalog = cat
	rng = r
	draw_pile = deck.duplicate()
	if shuffle_deck:
		rng.shuffle(draw_pile)
	slots.resize(size)
	slots.fill(null)
	_fill()

func _has_pair() -> bool:
	for k in slots.size() - 1:
		if slots[k] == null and slots[k + 1] == null:
			return true
	return false

func _heavy(id: String) -> bool:
	return int(Effects.card_def(id, catalog).get("weight", 1)) > 1

func life_for(id: String) -> float:
	var w := int(Effects.card_def(id, catalog).get("weight", 1))
	return float(BASE_LIFE + (HEAVY_BONUS if w > 1 else 0))

func preview() -> String:
	if draw_pile.is_empty():
		return ""
	return draw_pile[0]

func _draw() -> String:
	if draw_pile.is_empty():
		if discard.is_empty():
			return ""
		draw_pile = discard.duplicate()
		discard.clear()
		rng.shuffle(draw_pile)
	return draw_pile.pop_front()

## Draws into empty slots, at most max_draws cards (-1 = no limit). In relaxed mode a heavy
## card needs two adjacent empty slots; if there is no room it waits on top of the draw pile.
func _fill(max_draws := -1) -> void:
	var drawn := 0
	var skipped := 0
	var i := 0
	while i < slots.size():
		if max_draws >= 0 and drawn >= max_draws:
			return
		if slots[i] != null:
			i += 1
			continue
		var id := preview() if not draw_pile.is_empty() else ""
		if id == "":
			id = _draw()
			if id == "":
				return
			draw_pile.push_front(id)
		if mode == "relaxed" and _heavy(id):
			if not _has_pair():
				# no room for a two-slot card: send it to the bottom and try the next card
				skipped += 1
				if skipped > draw_pile.size():
					return
				draw_pile.push_back(draw_pile.pop_front())
				continue
			if i + 1 >= slots.size() or slots[i + 1] != null:
				i += 1
				continue
			_draw()
			slots[i] = {"card_id": id, "life": life_for(id)}
			slots[i + 1] = {"card_id": id, "tail": true}
			drawn += 1
			i += 2
			continue
		_draw()
		slots[i] = {"card_id": id, "life": life_for(id)}
		drawn += 1
		i += 1

## Removes the card in a slot (it goes to the discard pile) and returns its id.
func take(slot: int) -> String:
	if slot < 0 or slot >= slots.size() or slots[slot] == null:
		return ""
	if slots[slot].get("tail", false):
		slot -= 1
	var id: String = slots[slot]["card_id"]
	slots[slot] = null
	if slot + 1 < slots.size() and slots[slot + 1] != null and slots[slot + 1].get("tail", false):
		slots[slot + 1] = null
	discard.append(id)
	return id

func _burn(i: int) -> void:
	discard.append(slots[i]["card_id"])
	slots[i] = null

func end_turn(speed: float) -> void:
	if mode == "relaxed":
		var n := int(floor(clampf(speed, 0.0, 2.0) * per_round + 0.0001)) + _bonus_draws + (1 if reverse_next else 0)
		_bonus_draws = 0
		reverse_next = false
		_fill(n)
		return
	var decay := clampf(speed, 0.0, 2.0)
	if _hold:
		decay = 0.0
		_hold = false
	if reverse_next:
		decay = -1.0
		reverse_next = false
	for i in slots.size():
		if slots[i] == null:
			continue
		slots[i]["life"] = minf(slots[i]["life"] - decay, life_for(slots[i]["card_id"]) + HOLD_BONUS)
		if slots[i]["life"] <= 0.001:
			_burn(i)
	_fill()

## hold() freezes every card's life this turn; hold(slot) extends one card's life instead.
func hold(slot := -1) -> void:
	if mode == "relaxed":
		_bonus_draws += 1
		return
	if slot >= 0 and slot < slots.size() and slots[slot] != null:
		slots[slot]["life"] += HOLD_BONUS
	else:
		_hold = true

## Lifespan: burns the card closest to burning out and refills. Relaxed: discards the given
## card (or the first one) and draws one replacement now.
func flush(slot := -1) -> void:
	if mode == "relaxed":
		if slot < 0 or slot >= slots.size() or slots[slot] == null:
			slot = slots.find_custom(func(x): return x != null)
		if slot >= 0:
			take(slot)
		_fill(1)
		return
	var best := -1
	for i in slots.size():
		if slots[i] != null and (best < 0 or slots[i]["life"] < slots[best]["life"]):
			best = i
	if best >= 0:
		_burn(best)
	_fill()

## Index of the card that will burn first (for the UI), or -1. Always -1 in relaxed mode.
func next_to_burn() -> int:
	if mode == "relaxed":
		return -1
	var best := -1
	for i in slots.size():
		if slots[i] != null and (best < 0 or slots[i]["life"] < slots[best]["life"]):
			best = i
	return best

## Card ids in hand, left to right (a heavy card once).
func _entries() -> Array:
	var out: Array = []
	for s in slots:
		if s != null and not s.get("tail", false):
			out.append(s)
	return out

## The card a roll in this direction would discard ("" if the hand is empty).
## dir > 0 rolls right (rightmost card leaves), dir < 0 rolls left (leftmost leaves).
func end_card(dir: int) -> String:
	var e := _entries()
	if e.is_empty():
		return ""
	return e[-1]["card_id"] if dir > 0 else e[0]["card_id"]

## Wheel roll: the end card on the `dir` side is discarded, the rest slide toward it and a new
## card enters on the opposite end. Returns the discarded id ("" if the hand was empty).
func roll(dir: int) -> String:
	var e := _entries()
	var dropped := ""
	if not e.is_empty():
		var out: Dictionary = e.pop_back() if dir > 0 else e.pop_front()
		dropped = out["card_id"]
		discard.append(dropped)
	var used := 0
	for x in e:
		used += 2 if (mode == "relaxed" and _heavy(x["card_id"])) else 1
	var tries := draw_pile.size() + discard.size() + 1
	while tries > 0:
		tries -= 1
		var id := _draw()
		if id == "":
			break
		var w := 2 if (mode == "relaxed" and _heavy(id)) else 1
		if used + w > slots.size():
			draw_pile.push_back(id)
			continue
		var entry := {"card_id": id, "life": life_for(id)}
		if dir > 0:
			e.push_front(entry)
		else:
			e.push_back(entry)
		break
	slots.fill(null)
	var i := 0
	for x in e:
		slots[i] = x
		if mode == "relaxed" and _heavy(x["card_id"]) and i + 1 < slots.size():
			slots[i + 1] = {"card_id": x["card_id"], "tail": true}
			i += 1
		i += 1
	return dropped
