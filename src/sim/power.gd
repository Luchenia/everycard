class_name Power
extends RefCounted
## Card power = sum(part score x area multiplier x duration multiplier) - time cost credit.
## All coefficients live in data/power_scores.json so the server can share them.

static func budget(rarity: String, catalog: Catalog) -> float:
	return float(catalog.power.get("budgets", {}).get(rarity, 0))

static func area_cells(shape: String, size: int) -> int:
	match shape:
		"line": return max(size, 1)
		"circle": return (2 * size + 1) * (2 * size + 1)
		"cross": return 4 * size + 1
		"cone": return max(size, 1) * max(size, 1)
		"all": return Grid.W * Grid.H
	return 1

const AREA_OPS := ["var", "material", "damage", "status", "push", "heal"]

static func part_score(part: Dictionary, catalog: Catalog) -> float:
	var pw: Dictionary = catalog.power
	var ops: Dictionary = pw.get("ops", {})
	var op: String = part.get("op", "")
	var o: Dictionary = ops.get(op, {})
	match op:
		"damage", "heal": return float(part.get("amount", 0)) * float(o.get("per_amount", 1))
		"beam": return float(part.get("damage", 0)) * float(o.get("per_damage", 1))
		"push": return float(part.get("dist", 1)) * float(o.get("per_dist", 1))
		"belt": return float(part.get("amount", 1)) * float(o.get("per_amount", 1))
		"time_budget": return absf(float(part.get("delta", 0))) * float(o.get("per_delta", 1))
		"delay", "if": return part_score(part.get("part", {}), catalog) * float(o.get("inner_factor", 1))
		"material": return float(pw.get("material_scores", {}).get(part.get("id", ""), 2))
		"status":
			return float(pw.get("status_scores", {}).get(part.get("id", ""), 3)) * maxf(1.0, float(part.get("turns", 1))) * float(pw.get("status_turn_factor", 0.6))
		"var":
			var w := float(pw.get("var_weights", {}).get(part.get("id", ""), 1))
			var v = part.get("value", 0)
			var mag := 0.0
			if v is Dictionary:
				mag = float(v.get("strength", 1))
			elif v is Array:
				mag = Vector2(v[0], v[1]).length()
			else:
				mag = absf(float(v))
				var dflt = catalog.variables.get(part.get("id", ""), {}).get("default", 0)
				if part.get("mode", "add") == "set" and not (dflt is Array):
					mag = absf(float(v) - float(dflt))
				elif part.get("mode", "add") == "mul":
					mag = absf(float(v) - 1.0) * 10.0
			return w * mag
	return float(o.get("flat", 0))

static func score(card: Dictionary, catalog: Catalog) -> float:
	var pw: Dictionary = catalog.power
	var tgt: Dictionary = card.get("target", {})
	var total := 0.0
	for part in card.get("parts", []):
		var s := part_score(part, catalog)
		if part.get("op", "") in AREA_OPS:
			var shape: String = part.get("shape", tgt.get("shape", "cell"))
			var size: int = int(part.get("size", tgt.get("size", 0)))
			s *= pow(float(area_cells(shape, size)), float(pw.get("area_exponent", 0.6)))
		if part.get("op", "") != "status":   # status duration is already in part_score
			s *= 1.0 + float(part.get("turns", 0)) * float(pw.get("turns_factor", 1))
		total += s
	return total - float(card.get("time", 0)) * float(pw.get("time_credit", 2.5)) - float(card.get("exhaust", 0)) * float(pw.get("exhaust_credit", 3.0))

static func check(card: Dictionary, catalog: Catalog) -> Dictionary:
	var s := score(card, catalog)
	var b := budget(card.get("rarity", "common"), catalog)
	return {"ok": s <= b, "score": s, "budget": b}
