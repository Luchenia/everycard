extends SceneTree
## Plays a fight for a few waits with the real screen and samples where each monster is drawn on
## every rendered frame: a step must go from its start cell to its end cell without going back.
## tools/run.sh --headless --script res://tools/check_hop.gd

var screen
var frame := 0
var acts := 0
var last := {}      # uid -> drawn pos last frame
var target := {}    # uid -> glide end cell when the glide started
var back := 0
var samples := 0
var trace := []

func _initialize() -> void:
	screen = load("res://scenes/battle.tscn").instantiate()
	root.add_child(screen)

func _process(_d: float) -> bool:
	frame += 1
	if frame == 2:
		screen.debug_enter("fight")
		return false
	if frame < 4:
		return false
	var b = screen.flow.battle
	if not screen._replaying() and frame > 5:
		if acts >= 12 or b.phase != "player":
			print("hop check: samples=%d back=%d acts=%d" % [samples, back, acts])
			for t in trace.slice(0, 12):
				print(t)
			return true
		acts += 1
		b.cmd_wait(1)
		screen._after()
		return false
	for a in b.actors:
		if a.team != 1 or not b.grid.units.has(a):
			continue
		var p: Vector2 = screen.board._pos_of(a)
		samples += 1
		if last.has(a.uid) and not a.glide.is_empty():
			var to := Vector2(a.glide[1])
			var d0: float = Vector2(last[a.uid]).distance_to(to)
			var d1: float = p.distance_to(to)
			if d1 > d0 + 0.02 and d0 < 2.5:
				back += 1
				trace.append("frame %d uid %d %s -> %s (to %s) t=%.2f" % [frame, a.uid, last[a.uid], p, to, screen.board.sim_time()])
		last[a.uid] = p
	return false
