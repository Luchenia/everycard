class_name Catalog
extends RefCounted
## All game data loaded from res://data. Variables/materials/cards/actors keyed by id.

var variables: Dictionary = {}
var materials: Dictionary = {}
var reactions: Array = []
var cards: Dictionary = {}
var actors: Dictionary = {}
var power: Dictionary = {}
var config: Dictionary = {}   # data/battle.json: clock and board tunables
var keywords: Dictionary = {}   # data/keywords.json: hover explanations for [keyword]s, cell/status -> keyword

static func load_dir(path: String) -> Catalog:
	var c := Catalog.new()
	c.variables = _index(_read(path + "/variables.json", []))
	c.materials = _index(_read(path + "/materials.json", []))
	c.reactions = _read(path + "/reactions.json", [])
	c.power = _read(path + "/power_scores.json", {})
	c.config = _read(path + "/battle.json", {})
	c.keywords = _read(path + "/keywords.json", {})
	for sub in ["cards", "actors"]:
		var target: Dictionary = c.cards if sub == "cards" else c.actors
		var d := DirAccess.open(path + "/" + sub)
		if d == null:
			continue
		var files := Array(d.get_files())
		files.sort()
		for f in files:
			if f.ends_with(".json"):
				var data = _read(path + "/" + sub + "/" + f, null)
				for item in (data if data is Array else [data]):
					if item is Dictionary and item.has("id"):
						target[item["id"]] = item
	return c

static func _read(file: String, fallback):
	if not FileAccess.file_exists(file):
		return fallback
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(file))
	return fallback if parsed == null else parsed

static func _index(arr) -> Dictionary:
	var out := {}
	for item in arr:
		out[item["id"]] = item
	return out

## Returns human-readable errors; empty means valid.
func validate() -> Array[String]:
	var errs: Array[String] = []
	for r in reactions:
		for cond in r.get("when", []):
			if cond.has("var") and not variables.has(cond["var"]):
				errs.append("reaction %s: unknown var %s" % [r["id"], cond["var"]])
			for key in ["material", "neighbor_material"]:
				if cond.has(key) and not materials.has(cond[key]):
					errs.append("reaction %s: unknown material %s" % [r["id"], cond[key]])
		for act in r.get("then", []):
			if act.has("add_var") and not variables.has(act["add_var"]):
				errs.append("reaction %s: unknown var %s" % [r["id"], act["add_var"]])
			if act.has("set_material") and not materials.has(act["set_material"]):
				errs.append("reaction %s: unknown material %s" % [r["id"], act["set_material"]])
	return errs
