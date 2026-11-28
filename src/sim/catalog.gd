class_name Catalog
extends RefCounted
## All game data loaded from res://data. States/materials/cards/actors keyed by id.

var states: Dictionary = {}     # data/states.json: on/off cell states ([열기], [돌풍]...)
var materials: Dictionary = {}
var reactions: Array = []
var cards: Dictionary = {}
var actors: Dictionary = {}
var power: Dictionary = {}
var config: Dictionary = {}   # data/battle.json: clock and board tunables
var player_cards: Array = []   # data/player_cards.json: cards players can be offered
var keywords: Dictionary = {}   # data/keywords.json: hover explanations for [keyword]s, cell/status -> keyword

static func load_dir(path: String) -> Catalog:
	var c := Catalog.new()
	c.states = _index(_read(path + "/states.json", []))
	c.materials = _index(_read(path + "/materials.json", []))
	c.reactions = _read(path + "/reactions.json", [])
	c.power = _read(path + "/power_scores.json", {})
	c.config = _read(path + "/battle.json", {})
	c.keywords = _read(path + "/keywords.json", {})
	c.player_cards = _read(path + "/player_cards.json", [])
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
			if cond.has("state") and not states.has(cond["state"]):
				errs.append("reaction %s: unknown state %s" % [r["id"], cond["state"]])
			for key in ["material", "neighbor_material"]:
				if cond.has(key) and not materials.has(cond[key]):
					errs.append("reaction %s: unknown material %s" % [r["id"], cond[key]])
		for act in r.get("then", []):
			for key in ["add_state", "clear_state"]:
				if act.has(key) and not states.has(act[key]):
					errs.append("reaction %s: unknown state %s" % [r["id"], act[key]])
			if act.has("set_material") and not materials.has(act["set_material"]):
				errs.append("reaction %s: unknown material %s" % [r["id"], act["set_material"]])
	return errs
