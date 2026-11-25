class_name TimelineBar
extends Control
## Top bar: the next seconds of the shared clock. Shows when telegraphs fire, when each enemy acts
## next, when the hand refills, and how long the selected card (plus exhaustion) would take.

var battle: Battle
var font: Font
var span_secs := 0      # selected card: seconds of wind-up
var span_exhaust := 0   # selected card: seconds of exhaustion after it

func _draw() -> void:
	if battle == null:
		return
	var n := maxi(battle.round_time(), 10)
	var w := size.x / n
	draw_rect(Rect2(Vector2.ZERO, size), Color("#1d2029"))
	if span_secs > 0 or span_exhaust > 0:
		draw_rect(Rect2(0, 0, minf(span_secs, n) * w, size.y), Color(0.35, 0.6, 1, 0.35))
		draw_rect(Rect2(span_secs * w, 0, minf(span_exhaust, n - span_secs) * w, size.y), Color(0.6, 0.6, 0.6, 0.35))
	for i in n + 1:
		var x := i * w
		draw_line(Vector2(x, 0), Vector2(x, size.y), Color(1, 1, 1, 0.12), 1)
		if i > 0:
			draw_string(font, Vector2(x - 18, size.y - 4), "+%d" % i, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.35))
	var draw_at := battle.next_draw_at() - battle.now
	if draw_at <= n:
		var xd := draw_at * w
		draw_line(Vector2(xd - 1, 0), Vector2(xd - 1, size.y), Color(0.4, 0.7, 1), 2)
		draw_string(font, Vector2(xd - 34, 12), "카드+", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.5, 0.8, 1))
	for a in battle.actors:
		if a.controller != "ai" or not a.alive() or not battle.grid.units.has(a):
			continue
		var d: int = a.next_at - battle.now
		if d >= 1 and d <= n and not battle._busy(a):
			var xa := d * w
			draw_colored_polygon(PackedVector2Array([Vector2(xa - 5, 2), Vector2(xa + 5, 2), Vector2(xa, 10)]), Color(1, 0.4, 0.4))
			draw_string(font, Vector2(xa + 6, 11), a.name.substr(0, 2), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 0.6, 0.6))
	for t in battle.telegraphs:
		var d2: int = int(t["fire_at"]) - battle.now
		if d2 < 0 or d2 > n:
			continue
		var xt := d2 * w
		var a2: Actor = battle._actor(t["actor_uid"])
		draw_circle(Vector2(xt, size.y * 0.55), 8, Color(1, 0.5, 0.1))
		draw_string(font, Vector2(xt - 3, size.y * 0.55 + 5), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.BLACK)
		var label: String = Effects.card_def(t["card_id"], battle.catalog).get("name", "")
		draw_string(font, Vector2(xt + 10, size.y * 0.55 + 5), ("%s " % a2.name.substr(0, 2) if a2 else "") + label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 0.7, 0.4))
	draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.25), false, 1)
