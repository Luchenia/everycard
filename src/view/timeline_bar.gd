class_name TimelineBar
extends Control
## The next seconds of the shared clock, drawn as a track: enemy blows (red, with who), when each
## enemy moves next, when the hand refills, how far the selected card (and its exhaustion) reach,
## and borrowed time while 불릿타임 is running.

const SECS := 12
var battle: Battle
var font: Font
var span_secs := 0
var span_exhaust := 0
var span_world := -1.0   # world seconds the picked action takes ([가속] cell, 불릿타임); -1: span_secs
var real := 0.0

func _process(d: float) -> void:
	real += d
	queue_redraw()

func _draw() -> void:
	if battle == null:
		return
	var S := 2.0
	var w := (size.x - 40) / SECS
	var x0 := 36.0
	var y := size.y - 14.0
	# hourglass = now
	var hg := Vector2(16, y)
	draw_colored_polygon(PackedVector2Array([hg + Vector2(-8, -12), hg + Vector2(8, -12), hg + Vector2(0, 0)]), Color("#e8c070"))
	draw_colored_polygon(PackedVector2Array([hg + Vector2(-8, 12), hg + Vector2(8, 12), hg + Vector2(0, 0)]), Color("#b08840"))
	draw_rect(Rect2(hg + Vector2(-9, -14), Vector2(18, 3)), Art.INK)
	draw_rect(Rect2(hg + Vector2(-9, 11), Vector2(18, 3)), Art.INK)
	# track
	var track := Rect2(x0, y - 6, w * SECS, 12)
	draw_rect(track.grow(2), Art.INK)
	draw_rect(track, Color("#2a2733"))
	if battle.borrowing():
		var bl := battle.borrow_left
		for i in bl:
			draw_rect(Rect2(x0 + i * w + 2, y - 5, w - 4, 10), Color(0.62, 0.42, 1.0, 0.85 - 0.04 * i))
		var debt := int(ceil(battle.borrow_used * 1.5))
		for i in mini(debt, SECS):
			draw_rect(Rect2(x0 + i * w + 2, y + 8, w - 4, 3), Color(0.6, 0.6, 0.7, 0.6))
	elif span_secs > 0 or span_exhaust > 0:
		var wr := battle.world_rate()   # 불릿타임: the player's seconds cover a third of the world's
		var sw := span_world if span_world >= 0.0 else span_secs * wr
		draw_rect(Rect2(x0, y - 5, minf(sw, SECS) * w, 10), Color(Art.GOLD, 0.8))
		for i in mini(span_exhaust, SECS - span_secs):
			var r := Rect2(x0 + (sw + i * wr) * w, y - 5, w * wr, 10)
			draw_rect(r, Color(0.5, 0.5, 0.58, 0.6))
			draw_line(r.position + Vector2(2, 10), r.position + Vector2(10, 0), Color(0.2, 0.2, 0.25, 0.8), 2)
	for i in SECS + 1:
		var x := x0 + i * w
		draw_rect(Rect2(x - 1, y - 6, 2, 12 if i % 5 == 0 else 4), Color(1, 1, 1, 0.25))
		if i > 0 and i % 5 == 0:
			draw_string(font, Vector2(x - 3, y + 17), "%d" % i, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.4))
	# hand refill: a little card
	var dr := battle.next_draw_at() - battle.now
	if dr > 0.0 and dr <= SECS:
		var xc := x0 + dr * w
		draw_rect(Rect2(xc - 5, y - 22, 10, 14), Art.INK)
		draw_rect(Rect2(xc - 4, y - 21, 8, 12), Color("#9cc8f0"))
	# enemies' next moves
	for a in battle.actors:
		if a.controller != "ai" or not a.alive() or not battle.grid.units.has(a) or battle._busy(a):
			continue
		var d: float = battle.secs_until(a.next_at)
		if d > 0.0 and d <= SECS:
			_face(a, Vector2(x0 + d * w, y - 9), 0.45)
	# enemy blows
	for t in battle.telegraphs:
		var d2: float = battle.secs_until(int(t["fire_at"]))
		if d2 < 0 or d2 > SECS:
			continue
		var xt := x0 + d2 * w
		var hot := d2 <= 1.0
		var pulse := 0.5 + 0.5 * sin(real * (9.0 if hot else 4.0))
		var col := Art.DANGER if hot else Color("#ff8a3a")
		var dia := PackedVector2Array([Vector2(xt, y - 10), Vector2(xt + 9, y), Vector2(xt, y + 10), Vector2(xt - 9, y)])
		draw_colored_polygon(dia, Art.INK)
		draw_colored_polygon(PackedVector2Array([Vector2(xt, y - 7), Vector2(xt + 6, y), Vector2(xt, y + 7), Vector2(xt - 6, y)]), Color(col, 0.7 + 0.3 * pulse))
		var a2: Actor = battle._actor(t["actor_uid"])
		if a2:
			_face(a2, Vector2(xt, y - 11), 1.0)

func _face(a: Actor, at: Vector2, alpha: float) -> void:
	var st := Art.unit(Art.unit_id(a))
	if st.is_empty():
		return
	var src := Art.frame_src(st, 0)
	var k := minf(1.0, 14.0 / src.size.y)   # stays inside the bar: the bar sits at the top of the window
	var sz := src.size * k
	draw_texture_rect_region(st["tex"], Rect2(at - Vector2(sz.x / 2, sz.y), sz), src, Color(1, 1, 1, alpha))
