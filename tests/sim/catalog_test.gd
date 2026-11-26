extends TestCase

func run() -> void:
	var c := Catalog.load_dir("res://data")
	assert_eq(c.states.size(), 17, "17 cell states")
	assert_eq(c.materials.size(), 22, "22 materials")
	assert_true(c.reactions.size() >= 9, "reactions loaded")
	var errs := c.validate()
	assert_true(errs.is_empty(), "real catalog valid: " + str(errs))
	assert_true(c.states["heat"].has("upgrade"), "heat has a stronger form")
	# broken catalog: reaction references unknown state
	var bad := Catalog.new()
	bad.states = c.states
	bad.materials = c.materials
	bad.reactions = [{"id": "bogus", "when": [{"state": "nope_var"}], "then": []}]
	var berrs := bad.validate()
	assert_eq(berrs.size(), 1, "one error for unknown state")
	assert_true(berrs.size() == 1 and "nope_var" in berrs[0], "error names the id")
