extends TestCase

var c: Catalog

func fresh() -> Grid:
	return Grid.new(c)

func unit(mass := 1.0, hp := 30) -> Actor:
	return Actor.from_def({"id": "u", "hp": hp, "mass": mass, "deck": []}, 1)

func run() -> void:
	c = Catalog.load_dir("res://data")
	var rng := SimRng.new(1)
	# (a) states wear off after their seconds and do not spread
	var g := fresh(); var log := []
	var mid := Vector2i(4, 3)
	g.add_state(mid, "echo")   # 2 seconds
	g.add_state(Vector2i(0, 0), "curse")
	EnvironmentStep.run(g, c, rng, log)
	assert_true(not g.has_state(mid, "echo"), "echo gone after 2s")
	assert_true(not g.has_state(Vector2i(5, 3), "echo"), "states do not spread")
	assert_true(g.has_state(Vector2i(0, 0), "curse"), "curse still there")
	# (b) heat boils water into steam, which leaves damp air
	g = fresh(); log = []
	g.set_material(mid, "water"); g.add_state(mid, "heat")
	EnvironmentStep.run(g, c, rng, log)
	assert_eq(g.get_material(mid), "steam", "water -> steam")
	assert_true(g.has_state(mid, "damp"), "steam leaves damp")
	# cold freezes water; heat on oil lights it; damp puts fire out
	g = fresh(); log = []
	g.set_material(mid, "water"); g.add_state(mid, "cold")
	g.set_material(Vector2i(1, 1), "oil"); g.add_state(Vector2i(1, 1), "heat")
	g.set_material(Vector2i(7, 5), "fire"); g.add_state(Vector2i(7, 5), "damp")
	EnvironmentStep.run(g, c, rng, log)
	assert_eq(g.get_material(mid), "ice", "water + cold -> ice")
	assert_eq(g.get_material(Vector2i(1, 1)), "fire", "oil + heat -> fire")
	assert_eq(g.get_material(Vector2i(7, 5)), "steam", "fire + damp -> steam")
	# a wet unit in cold air freezes
	g = fresh(); log = []
	var fz := unit()
	g.place_unit(fz, mid); fz.add_status("wet", 3); g.add_state(mid, "cold")
	EnvironmentStep.run(g, c, rng, log, false)
	assert_true(fz.has_status("frozen"), "wet + cold -> frozen")
	# collapse breaks walls
	g = fresh(); log = []
	g.set_material(mid, "wall"); g.add_state(mid, "crush"); g.add_state(mid, "crush", -1.0, Vector2i.ZERO, true)
	EnvironmentStep.run(g, c, rng, log)
	assert_eq(g.get_material(mid), "none", "collapse breaks the wall")
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
	g.add_state(Vector2i(2, 3), "pull", -1.0, Vector2i.RIGHT)
	for x in range(2, 5):
		g.add_state(Vector2i(x, 3), "slick")
	EnvironmentStep.run(g, c, rng, log)
	assert_eq(u.pos, Vector2i(4, 3), "stopped before wall")
	assert_true(u.hp < 30, "collision damage")
	# heavy unit not moved by weak force
	g = fresh(); log = []
	var heavy := unit(5.0)
	g.place_unit(heavy, Vector2i(2, 3))
	g.add_state(Vector2i(2, 3), "pull", -1.0, Vector2i.RIGHT)
	EnvironmentStep.run(g, c, rng, log)
	assert_eq(heavy.pos, Vector2i(2, 3), "heavy unit stays")
	# (e) pushed into void dies
	g = fresh(); log = []
	var v := unit()
	g.place_unit(v, Vector2i(2, 3))
	g.set_material(Vector2i(3, 3), "void")
	g.add_state(Vector2i(2, 3), "pull", -1.0, Vector2i.RIGHT)
	EnvironmentStep.run(g, c, rng, log)
	assert_eq(v.hp, 0, "fell into void")
	# boss into void: 30% damage, stays at previous cell
	g = fresh(); log = []
	var b := Actor.from_def({"id": "b", "hp": 100, "mass": 1, "is_boss": true, "deck": []}, 2)
	g.place_unit(b, Vector2i(2, 3))
	g.set_material(Vector2i(3, 3), "void")
	g.add_state(Vector2i(2, 3), "pull", -1.0, Vector2i.RIGHT)
	EnvironmentStep.run(g, c, rng, log)
	assert_eq(b.hp, 70, "boss loses 30%")
	assert_eq(b.pos, Vector2i(2, 3), "boss stays on edge")
	# (f) stopped time holds other states in the cell, but itself runs out
	g = fresh(); log = []
	g.add_state(mid, "echo"); g.add_state(mid, "stopped")
	EnvironmentStep.run(g, c, rng, log)
	assert_true(g.has_state(mid, "echo"), "stopped cell keeps its echo")
	EnvironmentStep.run(g, c, rng, log)
	assert_true(not g.has_state(mid, "stopped"), "stopped time ends after 4s")
	# water + charge shocks unit standing there; statuses tick
	g = fresh(); log = []
	var w := unit()
	g.place_unit(w, mid); g.set_material(mid, "water"); g.add_state(mid, "charged")
	EnvironmentStep.run(g, c, rng, log)
	assert_true(w.hp < 30, "shocked in water")
	assert_true(w.has_status("wet"), "wet from water")
	# I3: fire spreads one cell per step in every direction (no scan-order bias)
	var gl := fresh(); var ll := []
	for x in range(0, 9):
		gl.set_material(Vector2i(x, 0), "oil")
	gl.set_material(Vector2i(4, 0), "fire")
	EnvironmentStep.run(gl, c, rng, ll)
	assert_eq(gl.get_material(Vector2i(6, 0)), "oil", "rightward spread limited to 1 cell")
	assert_eq(gl.get_material(Vector2i(5, 0)), "fire", "right neighbor caught")
	assert_eq(gl.get_material(Vector2i(3, 0)), "fire", "left neighbor caught")
	assert_eq(gl.get_material(Vector2i(2, 0)), "oil", "leftward spread limited to 1 cell")
