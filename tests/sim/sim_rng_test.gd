extends TestCase

func run() -> void:
	var a := SimRng.new(42)
	var b := SimRng.new(42)
	var c := SimRng.new(43)
	var sa := []; var sb := []; var sc := []
	for i in 10:
		sa.append(a.next_int(100)); sb.append(b.next_int(100)); sc.append(c.next_int(100))
	assert_eq(sa, sb, "same seed same sequence")
	assert_true(sa != sc, "different seed differs")
	var x := [1,2,3,4,5,6,7,8]; var y := x.duplicate()
	SimRng.new(7).shuffle(x); SimRng.new(7).shuffle(y)
	assert_eq(x, y, "shuffle reproducible")
	var f: float = SimRng.new(1).next_float()
	assert_true(f >= 0.0 and f < 1.0, "float in range")
