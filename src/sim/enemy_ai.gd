class_name EnemyAI
extends RefCounted
## Picks the next card from an AI actor's pattern and aims at the nearest actor of another team.
## Does not advance the pattern: Battle does that only when the card is actually used.

static func nearest_foe(actor: Actor, battle) -> Actor:
	var best: Actor = null
	var best_d := 1 << 30
	for a in battle.actors:
		if a == actor or not a.alive() or a.team == actor.team or not battle.grid.units.has(a):
			continue
		if battle.grid.mat_def(a.pos).get("blocks_sight", false):
			continue   # 연막: cannot be singled out
		var d := absi(a.pos.x - actor.pos.x) + absi(a.pos.y - actor.pos.y)
		if d < best_d:
			best_d = d
			best = a
	return best

## Returns {card_id, aim, foe} or {} when there is nothing to do.
static func choose(actor: Actor, battle) -> Dictionary:
	var seq: Array = actor.pattern if not actor.pattern.is_empty() else actor.deck
	if seq.is_empty():
		return {}
	var foe := nearest_foe(actor, battle)
	if foe == null:
		return {}
	var trick := _trick(actor, foe, battle)
	if not trick.is_empty():
		return trick
	var card_id: String = seq[actor.pattern_index % seq.size()]
	var card := Effects.card_def(card_id, battle.catalog)
	var shape: String = card.get("target", {}).get("shape", "cell")
	var aim: Vector2i = actor.pos if shape == "self" else foe.pos
	return {"card_id": card_id, "aim": aim, "foe": foe}

## A monster's own move for the moment (its "tricks"): the golem rushes down a clear straight
## lane, the boss sends its wave along one. Each has a cooldown, so it stays a surprise.
static func _trick(actor: Actor, foe: Actor, battle) -> Dictionary:
	for t in actor.tricks:
		var id: String = t["card"]
		if battle.tick < int(actor.trick_ready.get(id, 0)):
			continue
		match t.get("when", ""):
			"aligned":
				var d: Vector2i = foe.pos - actor.pos
				if d.x != 0 and d.y != 0:
					continue
				var n := absi(d.x) + absi(d.y)
				if n < int(t.get("min", 1)) or n > int(t.get("max", 6)):
					continue
				var step := Vector2i(signi(d.x), signi(d.y))
				var clear := true
				for i in range(1, n):
					var p: Vector2i = actor.pos + step * i
					if not battle.grid.passable(p) or battle.grid.unit_at(p) != null:
						clear = false
						break
				if not clear:
					continue
				var card := Effects.card_def(id, battle.catalog)
				var aim: Vector2i = actor.pos + step if int(card.get("target", {}).get("range", 1)) <= 1 else foe.pos
				return {"card_id": id, "aim": aim, "foe": foe, "trick": true, "cd": int(t.get("cd", 6))}
	return {}
