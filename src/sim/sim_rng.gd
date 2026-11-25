class_name SimRng
extends RefCounted
## The only randomness source in the simulation. Same seed -> same sequence.

var _rng := RandomNumberGenerator.new()

func _init(seed_value: int) -> void:
	_rng.seed = seed_value
	_rng.state = seed_value

## Integer in [0, n). n <= 0 returns 0.
func next_int(n: int) -> int:
	if n <= 0:
		return 0
	return int(_rng.randi() % n)

func next_float() -> float:
	return _rng.randf()

## In-place Fisher-Yates using next_int.
func shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := next_int(i + 1)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
