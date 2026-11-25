class_name HandBelt
extends RefCounted
## Lifespan hand: each card in hand has its own remaining life. At turn end every life drops by
## the turn speed (the time_scale of the player's cell); burnt-out cards go to the discard pile and
## their slots refill from the draw pile in place. Heavy cards live longer.

const BASE_LIFE := 3
const HEAVY_BONUS := 2
const HOLD_BONUS := 2

var catalog: Catalog
var rng: SimRng
var slots: Array = []      # each: null or {card_id, life}
var draw_pile: Array = []
var discard: Array = []
var _hold := false
var reverse_next := false  # set by "reverse" meta effects: next turn end restores 1 life instead of decaying

func _init(deck: Array, r: SimRng, cat: Catalog, size := 5, shuffle_deck := true) -> void:
	catalog = cat
	rng = r
	draw_pile = deck.duplicate()
	if shuffle_deck:
		rng.shuffle(draw_pile)
	slots.resize(size)
	slots.fill(null)
	_fill()

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

func _fill() -> void:
	for i in slots.size():
		if slots[i] == null:
			var id := _draw()
			if id == "":
				return
			slots[i] = {"card_id": id, "life": life_for(id)}

## Removes the card in a slot (it goes to the discard pile) and returns its id.
func take(slot: int) -> String:
	if slot < 0 or slot >= slots.size() or slots[slot] == null:
		return ""
	var id: String = slots[slot]["card_id"]
	slots[slot] = null
	discard.append(id)
	return id

func _burn(i: int) -> void:
	discard.append(slots[i]["card_id"])
	slots[i] = null

func end_turn(speed: float) -> void:
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
	if slot >= 0 and slot < slots.size() and slots[slot] != null:
		slots[slot]["life"] += HOLD_BONUS
	else:
		_hold = true

## Burns the card closest to burning out right away and refills its slot.
func flush() -> void:
	var best := -1
	for i in slots.size():
		if slots[i] != null and (best < 0 or slots[i]["life"] < slots[best]["life"]):
			best = i
	if best >= 0:
		_burn(best)
	_fill()

## Index of the card that will burn first (for the UI), or -1.
func next_to_burn() -> int:
	var best := -1
	for i in slots.size():
		if slots[i] != null and (best < 0 or slots[i]["life"] < slots[best]["life"]):
			best = i
	return best
