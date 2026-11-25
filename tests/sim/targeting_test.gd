extends TestCase

func run() -> void:
	var o := Vector2i(0, 0)
	var circ := Targeting.cells("circle", o, Vector2i(0, 0), 1)
	assert_eq(circ.size(), 4, "corner circle r1 clipped to 4 cells")
	assert_eq(Targeting.cells("circle", o, Vector2i(4, 3), 1).size(), 9, "inner circle r1 = 3x3")
	var line := Targeting.cells("line", Vector2i(1, 3), Vector2i(6, 3), 3)
	assert_eq(line, [Vector2i(2, 3), Vector2i(3, 3), Vector2i(4, 3)], "line goes toward aim")
	assert_eq(Targeting.cells("line", Vector2i(7, 3), Vector2i(8, 3), 5).size(), 1, "line clipped at edge")
	assert_eq(Targeting.cells("self", Vector2i(2, 2), Vector2i(5, 5), 0), [Vector2i(2, 2)], "self")
	assert_eq(Targeting.cells("cell", Vector2i(2, 2), Vector2i(5, 5), 0), [Vector2i(5, 5)], "cell")
	assert_eq(Targeting.cells("cross", Vector2i(0, 0), Vector2i(4, 3), 1).size(), 5, "cross r1")
	assert_eq(Targeting.cells("all", o, o, 0).size(), 63, "all")
	var cone := Targeting.cells("cone", Vector2i(1, 3), Vector2i(5, 3), 2)
	assert_eq(cone.size(), 4, "cone depth 2 = 1 + 3")
	assert_true(cone.has(Vector2i(3, 2)) and cone.has(Vector2i(3, 4)), "cone widens")
