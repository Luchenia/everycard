class_name HandBelt
extends RefCounted
## The flowing hand: a row of slots that slides left each turn. Leftmost card falls off
## (heavy cards need 2 flows), gaps close, and empty slots refill from the draw pile.

var catalog: Catalog
var rng: SimRng
var slots: Array = []      # each: null or {card_id, age}
var draw_pile: Array = []
var discard: Array = []
var _hold := false
var reverse_next := false

func _init(deck: Array, r: SimRng, cat: Catalog, size := 5, shuffle_deck := true) -> void:
	catalog = cat
	rng = r
	draw_pile = deck.duplicate()
	if shuffle_deck:
		rng.shuffle(draw_pile)
	slots.resize(size)
	slots.fill(null)
	_fill()

func _weight(id: String) -> int:
	return int(Effects.card_def(id, catalog).get("weight", 1))

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

func _compact() -> void:
	var cards := slots.filter(func(s): return s != null)
	for i in slots.size():
		slots[i] = cards[i] if i < cards.size() else null

func _fill() -> void:
	_compact()
	for i in slots.size():
		if slots[i] == null:
			var id := _draw()
			if id == "":
				return
			slots[i] = {"card_id": id, "age": 0}

## Removes the card in a slot (it goes to the discard pile) and returns its id.
func take(slot: int) -> String:
	if slot < 0 or slot >= slots.size() or slots[slot] == null:
		return ""
	var id: String = slots[slot]["card_id"]
	slots[slot] = null
	discard.append(id)
	return id

## Puts a card back in a slot (used when a play is rejected after take).
func put_back(slot: int, id: String) -> void:
	discard.erase(id)
	slots[slot] = {"card_id": id, "age": 0}

func _flow_once(force: bool) -> void:
	var i := slots.size() - 1 if reverse_next else 0
	var s = slots[i]
	if s == null:
		slots.remove_at(i)
		slots.insert(i if reverse_next else slots.size(), null)
		return
	s["age"] += 1
	if force or s["age"] >= _weight(s["card_id"]):
		discard.append(s["card_id"])
		slots[i] = null

func end_turn(speed: float) -> void:
	var steps: int = clampi(int(round(speed)), 0, 2)
	if _hold:
		steps = 0
		_hold = false
	for k in steps:
		_flow_once(false)
		_compact()
	reverse_next = false
	_fill()

func hold() -> void:
	_hold = true

func flush() -> void:
	_flow_once(true)
	_fill()
