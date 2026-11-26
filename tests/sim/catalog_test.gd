extends TestCase

func run() -> void:
	var c := Catalog.load_dir("res://data")
	assert_eq(c.variables.size(), 15, "15 variables")
	assert_eq(c.materials.size(), 15, "15 materials")
	assert_true(c.reactions.size() >= 9, "reactions loaded")
	var errs := c.validate()
	assert_true(errs.is_empty(), "real catalog valid: " + str(errs))
	assert_eq(c.variables["temperature"]["default"], 20, "temperature default")
	# broken catalog: reaction references unknown variable
	var bad := Catalog.new()
	bad.variables = c.variables
	bad.materials = c.materials
	bad.reactions = [{"id": "bogus", "when": [{"var": "nope_var", "op": ">=", "value": 1}], "then": []}]
	var berrs := bad.validate()
	assert_eq(berrs.size(), 1, "one error for unknown var")
	assert_true(berrs.size() == 1 and "nope_var" in berrs[0], "error names the id")
