extends TestCase

var c: Catalog

func fresh() -> Grid:
	return Grid.new(c)

func unit(mass := 1.0, hp := 30) -> Actor:
	return Actor.from_def({"id": "u", "hp": hp, "mass": mass, "deck": []}, 1)

func run() -> void:
	c = Catalog.load_dir("res://data")
	var rng := SimRng.new(1)
	# (a) heat spreads
	var g := fresh(); var log := []
	var mid := Vector2i(4, 3)
	g.set_var(mid, "temperature", 200)
	EnvironmentStep.run(g, c, rng, log)
	assert_true(g.get_var(Vector2i(5, 3), "temperature") > 20.0, "neighbor warmed")
	assert_true(g.get_var(mid, "temperature") < 200.0, "center cooled")
	assert_eq(g.get_var(Vector2i(0, 0), "temperature"), 20.0, "far cell unchanged")
	# (b) water boils into steam and raises pressure
	g = fresh(); log = []
	g.set_material(mid, "water"); g.set_var(mid, "temperature", 150)
	EnvironmentStep.run(g, c, rng, log)
	assert_eq(g.get_material(mid), "steam", "water -> steam")
	assert_true(g.get_var(mid, "pressure") > 1.5, "pressure rose")
	# oil next to fire with oxygen high explodes
	g = fresh(); log = []
	g.set_material(Vector2i(3, 3), "fire"); g.set_material(mid, "oil"); g.set_var(mid, "oxygen", 2)
	EnvironmentStep.run(g, c, rng, log)
	assert_eq(g.get_material(mid), "fire", "oil -> fire")
	assert_true(log.any(func(e): return e["t"] == "reaction" and e["data"]["id"] == "oil_explodes_near_fire"), "explosion logged")
	# (c) cyclic reactions stop at cap
	var cyc := Catalog.load_dir("res://data")
	cyc.reactions = [
		{"id": "a", "when": [{"material": "none"}], "then": [{"set_material": "oil"}]},
		{"id": "b", "when": [{"material": "oil"}], "then": [{"set_material": "none"}]}]
	g = Grid.new(cyc); log = []
	var p0 := Vector2i(0, 0)
	for p in g.all_cells():
		if p != p0:
			g.set_material(p, "wall")
	EnvironmentStep.run(g, cyc, rng, log)
	var caps := log.filter(func(e): return e["t"] == "chain_cap")
	assert_eq(caps.size(), 1, "one chain_cap log")
	var applied := log.filter(func(e): return e["t"] == "reaction")
	assert_eq(applied.size(), EnvironmentStep.CHAIN_CAP, "exactly cap reactions on that cell")
	# (d) gravity slides unit on frictionless floor into wall
	g = fresh(); log = []
	var u := unit()
	g.place_unit(u, Vector2i(2, 3))
	g.set_material(Vector2i(5, 3), "wall")
	g.set_var(Vector2i(2, 3), "gravity", Vector2(3, 0))
	for x in range(2, 5):
		g.set_var(Vector2i(x, 3), "friction", 0)
	EnvironmentStep.run(g, c, rng, log)
	assert_eq(u.pos, Vector2i(4, 3), "stopped before wall")
	assert_true(u.hp < 30, "collision damage")
	# heavy unit not moved by weak force
	g = fresh(); log = []
	var heavy := unit(5.0)
	g.place_unit(heavy, Vector2i(2, 3))
	g.set_var(Vector2i(2, 3), "gravity", Vector2(3, 0))
	EnvironmentStep.run(g, c, rng, log)
	assert_eq(heavy.pos, Vector2i(2, 3), "heavy unit stays")
	# (e) pushed into void dies
	g = fresh(); log = []
	var v := unit()
	g.place_unit(v, Vector2i(2, 3))
	g.set_material(Vector2i(3, 3), "void")
	g.set_var(Vector2i(2, 3), "gravity", Vector2(2, 0))
	EnvironmentStep.run(g, c, rng, log)
	assert_eq(v.hp, 0, "fell into void")
	# boss into void: 30% damage, stays at previous cell
	g = fresh(); log = []
	var b := Actor.from_def({"id": "b", "hp": 100, "mass": 1, "is_boss": true, "deck": []}, 2)
	g.place_unit(b, Vector2i(2, 3))
	g.set_material(Vector2i(3, 3), "void")
	g.set_var(Vector2i(2, 3), "gravity", Vector2(2, 0))
	EnvironmentStep.run(g, c, rng, log)
	assert_eq(b.hp, 70, "boss loses 30%")
	assert_eq(b.pos, Vector2i(2, 3), "boss stays on edge")
	# (f) time_scale 0 freezes the cell
	g = fresh(); log = []
	g.set_var(mid, "temperature", 200); g.set_var(mid, "time_scale", 0)
	EnvironmentStep.run(g, c, rng, log)
	assert_eq(g.get_var(mid, "temperature"), 200.0, "frozen cell keeps temperature")
	assert_true(g.get_var(mid, "time_scale") > 0.0, "time_scale itself recovers")
	# water + charge shocks unit standing there; statuses tick
	g = fresh(); log = []
	var w := unit()
	g.place_unit(w, mid); g.set_material(mid, "water"); g.set_var(mid, "charge", 6)
	EnvironmentStep.run(g, c, rng, log)
	assert_true(w.hp < 30, "shocked in water")
	assert_true(w.has_status("wet"), "wet from water")
