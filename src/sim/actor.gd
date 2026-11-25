class_name Actor
extends RefCounted
## One actor = body (stats, base ability) + deck + controller. Players and enemies are both Actors.

const REFILL_DECK := ["strike", "guard", "step"]

var uid := 0
var def_id := ""
var name := ""
var hp := 1
var max_hp := 1
var mass := 1.0
var armor := 0
var resist: Dictionary = {}
var statuses: Dictionary = {}   # status id -> remaining turns
var team := 1
var controller := "ai"
var is_boss := false
var summoner := false
var base_ability := "step1"
var deck: Array = []
var pattern: Array = []
var pattern_index := 0
var next_at := 0   # battle second at which an AI actor acts next
var pos := Vector2i(-1, -1)

static func from_def(def: Dictionary, new_uid: int) -> Actor:
	var a := Actor.new()
	a.uid = new_uid
	a.def_id = def.get("id", "")
	a.name = def.get("name", a.def_id)
	a.max_hp = int(def.get("hp", 10))
	a.hp = a.max_hp
	a.mass = float(def.get("mass", 1))
	a.armor = int(def.get("armor", 0))
	a.resist = def.get("resist", {}).duplicate()
	a.is_boss = bool(def.get("is_boss", false))
	a.summoner = bool(def.get("summoner", false))
	a.base_ability = def.get("base_ability", "step1")
	a.deck = Array(def.get("deck", [])).duplicate()
	a.pattern = Array(def.get("pattern", [])).duplicate()
	return a

func alive() -> bool:
	return hp > 0

func has_status(id: String) -> bool:
	return statuses.get(id, 0) > 0

func add_status(id: String, turns: int) -> void:
	statuses[id] = max(statuses.get(id, 0), turns)

## Applies resistance (fraction blocked) and, for physical damage, armor. Returns damage dealt.
func take_damage(amount: int, kind: String) -> int:
	var dmg := float(amount) * (1.0 - clampf(float(resist.get(kind, 0.0)), 0.0, 1.0))
	if kind == "physical":
		dmg -= armor
	if has_status("guard"):
		dmg *= 0.5
	var dealt: int = max(0, int(round(dmg)))
	hp = max(0, hp - dealt)
	return dealt

func heal(amount: int) -> void:
	hp = min(max_hp, hp + amount)

## Swaps who controls which body (and their teams). Bodies keep their decks. Bosses refuse.
static func swap_bodies(a: Actor, b: Actor) -> bool:
	if a == null or b == null or a == b or a.is_boss or b.is_boss:
		return false
	var c := a.controller
	a.controller = b.controller
	b.controller = c
	var t := a.team
	a.team = b.team
	b.team = t
	for x in [a, b]:
		if x.deck.is_empty():
			x.deck = REFILL_DECK.duplicate()
	return true
