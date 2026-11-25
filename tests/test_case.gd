class_name TestCase
extends RefCounted
## Base for tests/sim/*_test.gd. Override run().

var checks := 0
var failures := 0
var current := ""

func run() -> void:
	pass

func assert_true(cond: bool, label: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		printerr("  FAIL [%s] %s" % [current, label])

func assert_eq(a, b, label: String) -> void:
	checks += 1
	if typeof(a) != typeof(b) and not ((a is int or a is float) and (b is int or b is float)):
		failures += 1
		printerr("  FAIL [%s] %s: %s != %s" % [current, label, str(a), str(b)])
	elif a != b:
		failures += 1
		printerr("  FAIL [%s] %s: %s != %s" % [current, label, str(a), str(b)])
