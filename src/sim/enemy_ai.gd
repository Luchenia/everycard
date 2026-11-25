class_name EnemyAI
extends RefCounted
## Picks the next card from an AI actor's pattern and aims at the nearest actor of another team.

static func nearest_foe(actor: Actor, battle) -> Actor:
	var best: Actor = null
	var best_d := 1 << 30
	for a in battle.actors:
		if a == actor or not a.alive() or a.team == actor.team or not battle.grid.units.has(a):
			continue
		var d := absi(a.pos.x - actor.pos.x) + absi(a.pos.y - actor.pos.y)
		if d < best_d:
			best_d = d
			best = a
	return best

## Returns {card_id, aim} or {} when there is nothing to do.
static func choose(actor: Actor, battle) -> Dictionary:
	var seq: Array = actor.pattern if not actor.pattern.is_empty() else actor.deck
	if seq.is_empty():
		return {}
	var foe := nearest_foe(actor, battle)
	if foe == null:
		return {}
	var card_id: String = seq[actor.pattern_index % seq.size()]
	actor.pattern_index += 1
	var card := Effects.card_def(card_id, battle.catalog)
	var shape: String = card.get("target", {}).get("shape", "cell")
	var aim: Vector2i = actor.pos if shape == "self" else foe.pos
	return {"card_id": card_id, "aim": aim}
