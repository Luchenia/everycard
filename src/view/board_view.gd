class_name BoardView
extends Control
## Draws the grid: materials, variable overlays, units, enemy telegraphs and the card preview.

const AREA := Vector2(648, 504)   # board area; the cell size follows the grid size
const MAT_COLORS := {
	"none": Color("#2b2f3a"), "water": Color("#2d5f9e"), "ice": Color("#a9d8f0"), "steam": Color("#8c97a6"),
	"oil": Color("#3b2f1e"), "fire": Color("#e0631b"), "gas_flammable": Color("#6f8f2a"), "smoke": Color("#55555c"),
	"wall": Color("#6b6257"), "metal": Color("#b9c2cc"), "crystal": Color("#b48ce6"), "void": Color("#05040a"),
}

var battle: Battle
var hover := Vector2i(-1, -1)
var preview: Dictionary = {}
var font: Font
var CELL := 72

func _ready() -> void:
	fit()

func fit() -> void:
	CELL = int(minf(AREA.x / Grid.W, AREA.y / Grid.H))
	custom_minimum_size = Vector2(Grid.W * CELL, Grid.H * CELL)
	size = custom_minimum_size
	mouse_filter = Control.MOUSE_FILTER_PASS

func cell_at(local: Vector2) -> Vector2i:
	var p := Vector2i(int(floor(local.x / CELL)), int(floor(local.y / CELL)))
	return p if p.x >= 0 and p.y >= 0 and p.x < Grid.W and p.y < Grid.H else Vector2i(-1, -1)

func _rect(p: Vector2i, inset := 0.0) -> Rect2:
	return Rect2(Vector2(p) * CELL + Vector2(inset, inset), Vector2(CELL - inset * 2, CELL - inset * 2))

func _draw() -> void:
	if battle == null:
		return
	var g := battle.grid
	for p in g.all_cells():
		var r := _rect(p)
		draw_rect(r, MAT_COLORS.get(g.get_material(p), Color.MAGENTA))
		var t := float(g.get_var(p, "temperature"))
		if t > 40.0:
			draw_rect(r, Color(1, 0.2, 0.1, clampf((t - 40.0) / 260.0, 0.0, 0.6)))
		elif t < 5.0:
			draw_rect(r, Color(0.3, 0.6, 1, clampf((5.0 - t) / 100.0, 0.0, 0.6)))
		var ts := float(g.get_var(p, "time_scale"))
		if absf(ts - 1.0) > 0.05:
			draw_arc(r.get_center(), CELL * 0.38, 0, TAU * clampf(ts / 2.0, 0.05, 1.0), 24, Color(0.85, 0.85, 0.9, 0.7), 3)
		var ch := float(g.get_var(p, "charge"))
		if ch > 0.5:
			for k in int(min(ch, 6)):
				draw_circle(r.position + Vector2(8 + k * 9, CELL - 8), 3, Color(1, 0.95, 0.2))
		var force := EnvironmentStep.force_at(g, p)
		if force.length() > 0.4:
			var c := r.get_center()
			var tip := c + force.normalized() * minf(CELL * 0.45, 10 + force.length() * 6)
			draw_line(c, tip, Color(0.9, 1, 0.9, 0.8), 2)
			draw_circle(tip, 3, Color(0.9, 1, 0.9, 0.8))
		var pr := float(g.get_var(p, "pressure"))
		if pr > 2.0:
			draw_string(font, r.position + Vector2(4, 14), "P%.0f" % pr, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
		draw_rect(r, Color(0, 0, 0, 0.35), false, 1)
	for t in battle.telegraphs:
		var left: int = int(t["fire_at"]) - battle.now
		var hot := Color(1, 0.25, 0.1) if left <= 1 else Color(1, 0.55, 0.1)
		for p in t["cells"]:
			draw_rect(_rect(p, 3), Color(hot, 0.18))
			draw_rect(_rect(p, 3), hot, false, 3)
			draw_string(font, _rect(p).position + Vector2(CELL - 30, 18), "%d초" % left, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, hot)
	for u in g.units:
		var r2 := _rect(u.pos, 10)
		var col := Color("#4aa3ff") if u.controller == "human" else (Color("#58d26b") if u.team == 0 else Color("#ff5a5a"))
		draw_circle(r2.get_center(), CELL * 0.3, col)
		if u.is_boss:
			draw_arc(r2.get_center(), CELL * 0.34, 0, TAU, 24, Color.GOLD, 3)
		draw_string(font, r2.position + Vector2(2, 20), u.name.substr(0, 2), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.BLACK)
		draw_string(font, _rect(u.pos).position + Vector2(4, CELL - 4), "%d" % u.hp, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
		var sx := 4.0
		for s in u.statuses:
			draw_string(font, _rect(u.pos).position + Vector2(CELL - 12 - sx, 14), s.substr(0, 1).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.YELLOW)
			sx += 10
	if not preview.is_empty():
		for p in preview.get("cells", []):
			draw_rect(_rect(p, 1), Color(1, 1, 1, 0.9), false, 2)
		for uid in preview.get("damage_by_uid", {}):
			for u in battle.actors:
				if u.uid == uid and g.units.has(u):
					draw_string(font, _rect(u.pos).position + Vector2(CELL - 30, CELL - 6), "-%d" % preview["damage_by_uid"][uid], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 0.3, 0.3))
	if hover.x >= 0:
		draw_rect(_rect(hover), Color(1, 1, 1, 0.5), false, 2)
