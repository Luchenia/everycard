extends SceneTree
## Rolls the card ring many times and checks every card turns one step with the rest (no card
## cutting across). tools/run.sh --headless --script res://tools/check_ring.gd

var screen
var frame := 0
var bad := 0
var steps := 0

func _initialize() -> void:
	screen = load("res://scenes/battle.tscn").instantiate()
	root.add_child(screen)

func _ts() -> Array:
	return screen.ring_tokens.map(func(t): return float(t["t"]))

func _process(_d: float) -> bool:
	frame += 1
	if frame == 2:
		screen.debug_enter("fight")
		for a in screen.flow.battle.actors:
			if a.team == 1:
				a.next_at = 99999
	if frame > 5 and frame < 200:
		var before: Array = _ts()
		var dir := 1 if (frame / 7) % 2 == 0 else -1
		screen._roll(dir)
		var after: Array = _ts()
		steps += 1
		var ms: Array = screen.ring_tokens.map(func(t): return float(t.get("moved", 0.0)))
		if ms.max() - ms.min() > 0.01:
			bad += 1
			if bad < 4:
				print("step ", steps, " moves ", ms)
	if frame == 200:
		print("ring check: steps=", steps, " bad=", bad)
		return true
	return false
