class_name BoardView
extends Control
## The dungeon room: floor and walls, ground states (one connected surface per kind), effects,
## units with their hp right under them, enemy attack warnings (always on top of effects), aiming
## and the bullet-time look while the player thinks.
##
## Layers, back to front: floor (this node) -> liquids (shader) -> top layer: cell auras, y-sorted
## effects and units, warnings, hp bars, aiming, damage numbers, bullet-time veil.

const LIQ := {"water": 1, "oil": 2, "swamp": 3, "ice": 4}
const C := Art.CELL
const S := Art.S

var battle: Battle
var font: Font
var hover := Vector2i(-1, -1)
var preview: Dictionary = {}
var range_cells: Array = []      # cells the selected card can reach
var aiming := false              # a card is selected: tall effects go see-through so cells stay readable
var shown_pos: Dictionary = {}   # uid -> Vector2 (cell coords, fractional while replaying)
var shown_hp: Dictionary = {}    # uid -> hp at the replayed second
var shown_now := -1
var replaying := false

var origin := Vector2(C, C * 2)  # top-left of cell (0,0) inside this control
var clock := 0.0                 # effect time: crawls while paused (bullet time), runs during replay
var real := 0.0
var liquid: ColorRect
var top: Control
var _state_img: Image
var _state_tex: ImageTexture
var _floor: PackedInt32Array = PackedInt32Array()
var _wall: PackedInt32Array = PackedInt32Array()
var _floor_for: Battle
var popups: Array = []           # {p: Vector2 local, text, col, t0}
var flashes: Dictionary = {}     # uid -> real time of last hit
var _last_hp: Dictionary = {}
var shake_until := 0.0
var fizzle: Dictionary = {}      # {cell, t0}: an out-of-range click
var bursts: Array = []           # {cells, col, t0, beam_from}: a card or a blow landing
var lunges: Dictionary = {}      # uid -> {t0, dir}: attacker leaning into its blow
var beams: Array = []            # {from, path, bends, t0}
var oneshots: Array = []         # {fx, ground (local), t0, flip}: slash / hit bursts
var cell_events: Dictionary = {} # cell -> {kind, t0}: fire lighting up / going out, ice breaking
var _prev_mat: Dictionary = {}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	liquid = ColorRect.new()
	liquid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load("res://src/view/liquid.gdshader")
	liquid.material = mat
	add_child(liquid)
	top = Control.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.draw.connect(_draw_top)
	add_child(top)
	fit()

func fit() -> void:
	size = Vector2((Grid.W + 2) * C, (Grid.H + 3) * C)
	custom_minimum_size = size
	if liquid:
		liquid.position = origin
		liquid.size = Vector2(Grid.W, Grid.H) * C
		top.size = size
		(liquid.material as ShaderMaterial).set_shader_parameter("grid", Vector2(Grid.W, Grid.H))
	_state_img = Image.create(Grid.W, Grid.H, false, Image.FORMAT_RGBA8)
	_state_tex = ImageTexture.create_from_image(_state_img)

func _process(delta: float) -> void:
	real += delta
	var speed := 1.0 if replaying else (0.0 if battle != null and battle.borrowing() else 0.14)
	clock += delta * speed
	if battle != null:
		_update_liquids()
		_track_hits()
		_track_cells()
	queue_redraw()
	if top:
		top.queue_redraw()

func cell_at(local: Vector2) -> Vector2i:
	var q := (local - origin) / C
	var p := Vector2i(int(floor(q.x)), int(floor(q.y)))
	return p if p.x >= 0 and p.y >= 0 and p.x < Grid.W and p.y < Grid.H else Vector2i(-1, -1)

func cell_rect(p: Vector2i, inset := 0.0) -> Rect2:
	return Rect2(origin + Vector2(p) * C + Vector2(inset, inset), Vector2(C - inset * 2, C - inset * 2))

## Ground point of a cell: centre x, 12 art px below the cell top (where sprite anchors sit).
func feet(cp: Vector2) -> Vector2:
	return origin + (cp + Vector2(0.5, 0.0)) * C + Vector2(0, 12 * S)

## A crystal (cell or crystallized unit) breaking: the one-shot sheet, centred on the cell, above units.
func shatter(p: Vector2i) -> void:
	var st := Art.fx("crystal_shatter")
	var life: float = (st["n"] / st["fps"]) if not st.is_empty() else 0.8
	oneshots.append({"fx": "crystal_shatter", "ground": cell_rect(p).get_center(), "t0": real, "flip": false, "life": life})

## A beam's real path (bounces off mirrors, turns at crystal gems): glow plus core, fading out.
func beam(from: Vector2i, path: Array, bends: Array, kind := "energy") -> void:
	beams.append({"from": from, "path": path, "bends": bends, "t0": real, "kind": kind})

func shake(secs := 0.25) -> void:
	shake_until = real + secs

func burst(cells: Array, col: Color, beam_from := Vector2i(-1, -1)) -> void:
	bursts.append({"cells": cells, "col": col, "t0": real, "from": beam_from})

## An attacker leans toward its target and a slash arc plays; the target cells get a hit burst.
func attack(uid: int, cells: Array) -> void:
	var a: Actor = battle._actor(uid)
	if a == null or cells.is_empty():
		return
	var c := Vector2.ZERO
	for p in cells:
		c += Vector2(p)
	c /= cells.size()
	var d := (c - Vector2(a.pos))
	var dir := d.normalized() if d.length() > 0.01 else Vector2.RIGHT
	lunges[uid] = {"t0": real, "dir": dir}
	if d.length() <= 1.6:
		oneshots.append({"fx": "slash", "ground": feet(Vector2(a.pos)) - Vector2(0, 6 * S), "t0": real, "flip": dir.x < 0})
	for p in cells:
		if battle.grid.unit_at(p) != null:
			oneshots.append({"fx": "hit", "ground": feet(Vector2(p)) - Vector2(0, 8 * S), "t0": real + 0.08, "flip": false})

func _track_cells() -> void:
	var g := battle.grid
	for p in g.all_cells():
		var m := g.get_material(p)
		var was: String = _prev_mat.get(p, m)
		if was != m:
			if m == "fire":
				cell_events[p] = {"kind": "fire_ignite", "t0": real}
			elif was == "fire":
				cell_events[p] = {"kind": "fire_out", "t0": real}
			elif was == "ice":
				cell_events[p] = {"kind": "ice_shatter", "t0": real}
		_prev_mat[p] = m

func out_of_range_click(p: Vector2i) -> void:
	fizzle = {"cell": p, "t0": real}
	shake(0.22)

# ---- floor --------------------------------------------------------------------------------------

func _build_floor() -> void:
	_floor_for = battle
	var rnd := RandomNumberGenerator.new()
	rnd.seed = hash(battle.rng.get_state()) if battle.rng else 1
	var blobs := []
	for i in rnd.randi_range(3, 6):
		blobs.append([rnd.randf_range(0, Grid.W), rnd.randf_range(0, Grid.H), rnd.randf_range(1.2, 2.6)])
	_floor.resize(Grid.W * Grid.H)
	for y in Grid.H:
		for x in Grid.W:
			var inblob := false
			for b in blobs:
				if pow(x - b[0], 2) + pow(y - b[1], 2) < b[2] * b[2]:
					inblob = true
			var r := rnd.randf()
			var t := 0
			if inblob and r < 0.75: t = 8 + rnd.randi_range(0, 3)
			elif r < 0.88: t = rnd.randi_range(0, 3)
			elif r < 0.95: t = 4 + rnd.randi_range(0, 3)
			else: t = 12 + rnd.randi_range(0, 3)
			_floor[y * Grid.W + x] = t
	_wall.resize((Grid.W + 2) * (Grid.H + 3))
	for i in _wall.size():
		_wall[i] = rnd.randi_range(0, 3) if rnd.randf() < 0.8 else rnd.randi_range(4, 15)

func _tile(tex: Texture2D, idx: int, at: Vector2, mod := Color.WHITE) -> void:
	if idx >= 8 and idx < 12 and tex.get_width() >= 16 * Art.T:
		# dark patches are blended half-way toward the plain stone
		draw_texture_rect_region(tex, Rect2(at, Vector2(C, C)), Rect2((idx - 8) * Art.T, 0, Art.T, Art.T), mod)
		draw_texture_rect_region(tex, Rect2(at, Vector2(C, C)), Rect2(idx * Art.T, 0, Art.T, Art.T), Color(mod, 0.5))
		return
	draw_texture_rect_region(tex, Rect2(at, Vector2(C, C)), Rect2(idx * Art.T, 0, Art.T, Art.T), mod)

func _draw() -> void:
	if battle == null:
		return
	if _floor_for != battle or _floor.size() != Grid.W * Grid.H:
		_build_floor()
	var off := _shake_off()
	var stone := Art.tex("floor/stone_floor.png")
	var wall := Art.tex("floor/stone_wall_top.png")
	var face := Art.tex("floor/stone_wall_face.png")
	draw_rect(Rect2(Vector2.ZERO, size), Color("#0a090d"))
	var W := Grid.W
	var H := Grid.H
	# walls: top row, faces, sides, bottom
	for x in range(-1, W + 1):
		_tile(wall, _wall[(x + 1)], origin + off + Vector2(x * C, -2 * C))
	if face:
		for x in range(0, W, 2):
			var fw := mini(2, W - x)
			var flipx := (x / 2) % 2 == 1
			var dst := Rect2(origin + off + Vector2(x * C, -C), Vector2(fw * C, C))
			if flipx:
				dst = Rect2(dst.position + Vector2(fw * C, 0), Vector2(-fw * C, C))
			draw_texture_rect_region(face, dst, Rect2(0, 0, fw * Art.T, Art.T))
	for y in range(-1, H + 1):
		_tile(wall, _wall[(y + 2) * (W + 2)], origin + off + Vector2(-C, y * C))
		_tile(wall, _wall[(y + 2) * (W + 2) + W + 1], origin + off + Vector2(W * C, y * C))
	for x in range(0, W):
		_tile(wall, _wall[(H + 2) * (W + 2) + x + 1], origin + off + Vector2(x * C, H * C), Color(0.85, 0.85, 0.9))
	# floor
	var g := battle.grid
	for p in g.all_cells():
		var at := origin + off + Vector2(p) * C
		var m := g.get_material(p)
		if m == "void":
			draw_rect(Rect2(at, Vector2(C, C)), Color("#040307"))
			draw_rect(Rect2(at, Vector2(C, 4 * S)), Color("#1b1824"))
			continue
		_tile(stone, _floor[p.y * W + p.x], at)
		var temp := float(g.get_var(p, "temperature"))
		if m == "fire":
			var fl := 0.5 + 0.5 * sin(clock * 6.0 + p.x * 2.1 + p.y)
			draw_rect(Rect2(at, Vector2(C, C)), Color(0.47, 0.12, 0.04, 0.3 + 0.1 * fl))
			draw_rect(Rect2(at + Vector2(1, 1), Vector2(C - 2, C - 2)), Color(1.0, 0.47, 0.16, 0.45 + 0.15 * fl), false, S)
		elif temp > 70.0:
			draw_rect(Rect2(at, Vector2(C, C)), Color(1, 0.35, 0.1, clampf((temp - 70.0) / 400.0, 0.0, 0.3)))
		elif temp < -5.0 and m != "ice":
			draw_rect(Rect2(at, Vector2(C, C)), Color(0.6, 0.85, 1.0, clampf((-5.0 - temp) / 150.0, 0.0, 0.35)))
	# shadow cast by the back wall
	draw_rect(Rect2(origin + off, Vector2(W * C, 6 * S)), Color(0, 0, 0, 0.27))
	draw_rect(Rect2(origin + off, Vector2(3 * S, H * C)), Color(0, 0, 0, 0.18))

func _shake_off() -> Vector2:
	if real >= shake_until:
		return Vector2.ZERO
	var k := (shake_until - real) / 0.25
	return Vector2(sin(real * 90.0) * 5.0 * k, cos(real * 70.0) * 2.0 * k).round()

func _update_liquids() -> void:
	if _state_img == null or _state_img.get_width() != Grid.W or _state_img.get_height() != Grid.H:
		fit()
	var g := battle.grid
	for p in g.all_cells():
		var code: int = LIQ.get(g.get_material(p), 0)
		_state_img.set_pixel(p.x, p.y, Color8(code, 0, 0, 255))
	_state_tex.update(_state_img)
	var mat := liquid.material as ShaderMaterial
	mat.set_shader_parameter("state", _state_tex)
	mat.set_shader_parameter("t", clock * 3.0)
	liquid.position = origin + _shake_off()

# ---- hits and numbers ---------------------------------------------------------------------------

func _hp_of(u: Actor) -> int:
	return int(shown_hp.get(u.uid, u.hp)) if replaying else u.hp

func _pos_of(u: Actor) -> Vector2:
	return shown_pos.get(u.uid, Vector2(u.pos)) if replaying else Vector2(u.pos)

var _track_for: Battle

func _track_hits() -> void:
	if _track_for != battle:
		_track_for = battle
		reset_tracking()
		_prev_mat.clear()
		cell_events.clear()
	for u in battle.actors:
		var hp := _hp_of(u)
		if _last_hp.has(u.uid) and hp < int(_last_hp[u.uid]):
			popups.append({"p": feet(_pos_of(u)) - Vector2(0, 30 * S), "text": "%d" % (int(_last_hp[u.uid]) - hp),
				"col": Color("#ff5a4a"), "t0": real})
			flashes[u.uid] = real
		elif _last_hp.has(u.uid) and hp > int(_last_hp[u.uid]):
			popups.append({"p": feet(_pos_of(u)) - Vector2(0, 30 * S), "text": "+%d" % (hp - int(_last_hp[u.uid])),
				"col": Color("#7ee08a"), "t0": real})
		_last_hp[u.uid] = hp
	popups = popups.filter(func(q): return real - q["t0"] < 1.0)

func reset_tracking() -> void:
	_last_hp.clear()
	popups.clear()

# ---- top layer ----------------------------------------------------------------------------------

func _draw_top() -> void:
	if battle == null:
		return
	var g := battle.grid
	var off := _shake_off()
	var tl := top
	# cell auras (inside their cells)
	for p in g.all_cells():
		_aura(tl, p, off)
	# reach of the selected card
	for p in range_cells:
		var r := cell_rect(p, 2 * S)
		r.position += off
		tl.draw_rect(r, Color(1, 0.95, 0.75, 0.10))
		_corners(tl, r, Color(1, 0.95, 0.75, 0.55), 3 * S)
	if not preview.is_empty():
		for p in preview.get("cells", []):
			var r2 := cell_rect(p, S)
			r2.position += off
			tl.draw_rect(r2, Color(Art.GOLD, 0.22))
			tl.draw_rect(r2, Color(Art.GOLD, 0.9), false, S)
	# y-sorted effects and units
	var items := []
	for p in g.all_cells():
		var m := g.get_material(p)
		if m == "fire" or m == "crystal" or m == "metal":
			var over := m == "crystal" and g.unit_at(p) != null
			items.append({"y": float(p.y) + (0.97 if over else 0.75), "fx": ("mirror" if m == "metal" else m), "p": p})
		elif m == "wall":
			items.append({"y": float(p.y) + 0.95, "block": m, "p": p})
	for u in battle.actors:
		if replaying and not shown_pos.has(u.uid):
			continue
		if not replaying and not g.units.has(u):
			continue
		items.append({"y": _pos_of(u).y + 0.95, "unit": u})
	items.sort_custom(func(a, b): return a["y"] < b["y"])
	# afterimages of attackers sit under everything standing, so they never hide a unit
	for t in battle.telegraphs:
		_ghost(tl, t, off)
	for it in items:
		if it.has("fx"):
			_fx(tl, it["fx"], it["p"], off)
		elif it.has("block"):
			_block(tl, it["block"], it["p"], off)
		else:
			_unit(tl, it["unit"], off)
	# one-shot effects: slashes, hit bursts, fire going out, ice breaking
	oneshots = oneshots.filter(func(q): return real - float(q["t0"]) < float(q.get("life", 0.8)))
	for q in oneshots:
		var k: float = real - float(q["t0"])
		if k < 0.0:
			continue
		var st := Art.fx(q["fx"])
		if not st.is_empty() and k * st["fps"] < st["n"]:
			_sprite(tl, st, q["ground"] + off, Art.frame_at(st, k), Color.WHITE, q["flip"])
	for p in cell_events.keys():
		var ev: Dictionary = cell_events[p]
		var k2: float = real - float(ev["t0"])
		if k2 > 0.8:
			cell_events.erase(p)
			continue
		if ev["kind"] == "fire_out" or ev["kind"] == "ice_shatter":
			var st2 := Art.fx(ev["kind"])
			if not st2.is_empty() and k2 * st2["fps"] < st2["n"]:
				_sprite(tl, st2, feet(Vector2(p)) + off, Art.frame_at(st2, k2))
	# beams: 3 px glow with a 1 px core; light turns at the gem itself (7 art px above the cell centre)
	beams = beams.filter(func(q): return real - q["t0"] < 0.5)
	for q in beams:
		var k3: float = (real - float(q["t0"])) / 0.5
		var pts := PackedVector2Array([cell_rect(q["from"]).get_center() + off])
		for c3 in q["path"]:
			var pt := cell_rect(c3).get_center() + off
			if c3 in q["bends"]:
				pt.y -= 7 * S
			pts.append(pt)
		if pts.size() >= 2 and q.get("kind", "energy") == "physical":
			# a thrown blade: a short steel streak running along the path
			var total := 0.0
			for i3 in pts.size() - 1:
				total += pts[i3].distance_to(pts[i3 + 1])
			var head := minf(1.0, k3 * 2.2) * total
			var run := 0.0
			for i3 in pts.size() - 1:
				var seg := pts[i3].distance_to(pts[i3 + 1])
				if run + seg >= head:
					var hp3 := pts[i3].lerp(pts[i3 + 1], (head - run) / maxf(seg, 0.01))
					var dir3 := (pts[i3 + 1] - pts[i3]).normalized()
					tl.draw_line(hp3 - dir3 * 14 * S, hp3, Color(0.8, 0.85, 0.95, 0.35 * (1.0 - k3)), 2 * S)
					tl.draw_line(hp3 - dir3 * 4 * S, hp3, Color(0.95, 0.97, 1.0, 1.0 - k3 * 0.5), S)
					break
				run += seg
		elif pts.size() >= 2:
			tl.draw_polyline(pts, Color(1.0, 0.95, 0.7, 0.45 * (1.0 - k3)), 3 * S)
			tl.draw_polyline(pts, Color(1, 1, 1, 1.0 - k3), S)
		for b3 in q["bends"]:
			var gp := cell_rect(b3).get_center() + off - Vector2(0, 7 * S)
			tl.draw_circle(gp, (3 - 2 * k3) * S, Color(1, 1, 1, 1.0 - k3))
			tl.draw_arc(gp, (2 + 9 * k3) * S, 0, TAU, 20, Color(0.85, 0.75, 1.0, 1.0 - k3), S)
	# cards and blows landing: a bright flash on the struck cells
	bursts = bursts.filter(func(q): return real - q["t0"] < 0.45)
	for q in bursts:
		var k: float = (real - float(q["t0"])) / 0.45
		var col: Color = q["col"]
		var cl: Array = q["cells"]
		if q["from"].x >= 0 and not cl.is_empty():
			var a0 := cell_rect(q["from"]).get_center() + off
			var a1 := cell_rect(cl[cl.size() - 1]).get_center() + off
			tl.draw_line(a0, a1, Color(col, 0.5 * (1.0 - k)), (6 - 4 * k) * S)
			tl.draw_line(a0, a1, Color(1, 1, 1, 1.0 - k), 2 * S)
		for p in cl:
			var r := cell_rect(p, (1.0 - k) * 6 * S)
			r.position += off
			tl.draw_rect(r, Color(col, 0.55 * (1.0 - k)))
			tl.draw_rect(cell_rect(p, S).grow(k * 2 * S), Color(1, 1, 1, 0.7 * (1.0 - k)), false, S)
	# enemy warnings: always above effects and units
	for t in battle.telegraphs:
		_telegraph(tl, t, off)
	for tm in battle.ctx.timers:
		_bomb(tl, tm, off)
	# hp bars and states, never hidden behind sprites
	for it in items:
		if it.has("unit"):
			_hp_bar(tl, it["unit"], off)
	_aim(tl, off)
	for q in popups:
		var k: float = (real - q["t0"]) / 1.0
		var pp: Vector2 = q["p"] + Vector2(0, -26 * k) + off
		var col: Color = q["col"]
		col.a = 1.0 - k * k
		var fs := 22 if k < 0.15 else 18
		tl.draw_string_outline(font, pp - Vector2(10, 0), q["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 6, Color(0, 0, 0, col.a))
		tl.draw_string(font, pp - Vector2(10, 0), q["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	# bullet time: a cool veil and slowly drifting motes while the player decides
	if not replaying:
		var borrowing := battle.borrowing()
		tl.draw_rect(Rect2(origin, Vector2(Grid.W, Grid.H) * C), Color(0.6, 0.3, 1.0, 0.13) if borrowing else Color(0.35, 0.55, 1.0, 0.06))
		for k2 in 18:
			var sp := 4.0 + float(k2 % 5)
			var px := fmod(float(k2) * 97.0 + clock * 18.0 * sp, Grid.W * C)
			var py := fmod(float(k2) * 53.0 + clock * 11.0 * sp, Grid.H * C)
			tl.draw_rect(Rect2(origin + Vector2(px, py).snapped(Vector2(S, S)), Vector2(S, S)),
				Color(0.85, 0.7, 1.0, 0.5) if borrowing else Color(0.8, 0.9, 1.0, 0.35))

func _corners(tl: Control, r: Rect2, col: Color, L: float) -> void:
	var w := float(S)
	for c in [[r.position, Vector2(1, 1)], [Vector2(r.end.x, r.position.y), Vector2(-1, 1)],
			[Vector2(r.position.x, r.end.y), Vector2(1, -1)], [r.end, Vector2(-1, -1)]]:
		var o: Vector2 = c[0]
		var d: Vector2 = c[1]
		tl.draw_rect(Rect2(o + Vector2(0 if d.x > 0 else -L, 0 if d.y > 0 else -w), Vector2(L, w)), col)
		tl.draw_rect(Rect2(o + Vector2(0 if d.x > 0 else -w, 0 if d.y > 0 else -L), Vector2(w, L)), col)

## Variable states shown inside the cell they belong to: time, charge, wind, crush.
func _aura(tl: Control, p: Vector2i, off: Vector2) -> void:
	var g := battle.grid
	var r := cell_rect(p)
	r.position += off
	var c := r.get_center()
	var ts := float(g.get_var(p, "time_scale"))
	if ts <= 0.01:
		tl.draw_rect(r.grow(-S), Color(0.75, 0.75, 0.85, 0.28))
		_hand(tl, c, 0.0, Color(0.9, 0.9, 1.0, 0.7))
	elif ts < 0.95:
		tl.draw_rect(r.grow(-S), Color(0.45, 0.35, 0.7, 0.10 + (1.0 - ts) * 0.12))
		_hand(tl, c, real * 0.6 * ts, Color(0.75, 0.65, 1.0, 0.55))
	elif ts > 1.05:
		var hs := Art.fx("haste")
		if hs.is_empty():
			_hand(tl, c, real * 4.0 * ts, Color(1.0, 0.85, 0.4, 0.7))
		else:
			_sprite(tl, hs, c, Art.frame_at(hs, real, p.x + p.y), Color(1, 1, 1, 0.6))
	var m := g.get_material(p)
	var surf := {"water": "water_splash", "ice": "ice_glint", "swamp": "swamp_bubbles"}
	if surf.has(m) and (m != "water" or (p.x * 7 + p.y * 3) % 3 == 0):
		var ss := Art.fx(surf[m])
		_sprite(tl, ss, c, Art.frame_at(ss, clock * 1.5, p.x * 5 + p.y * 9))
	if m == "trap_rabbit":
		# a sprung-open jaw trap: iron ring with teeth
		var tc := c + Vector2(0, 3 * S)
		tl.draw_arc(tc, 5 * S, 0, TAU, 16, Color("#2a2730"), 2 * S)
		tl.draw_arc(tc, 5 * S, 0, TAU, 16, Color("#8a8f9c"), S)
		for k5 in 6:
			var an := k5 * TAU / 6.0
			tl.draw_line(tc + Vector2(cos(an), sin(an) * 0.6) * 5 * S, tc + Vector2(cos(an), sin(an) * 0.6) * 2.5 * S, Color("#c8ccd6"), S)
		tl.draw_circle(tc, S, Color("#b08840"))
	elif m == "smoke_screen":
		for k6 in 4:
			var ph := real * 0.4 + k6 * 1.7 + p.x * 0.9 + p.y * 1.3
			var pc := c + Vector2(sin(ph) * 5, cos(ph * 0.8) * 3 - 2) * S
			tl.draw_circle(pc, (6 + 1.5 * sin(ph * 1.3)) * S, Color(0.72, 0.72, 0.78, 0.22))
	if m == "fire":
		var fl := 0.8 + 0.2 * sin(real * 7.0 + p.x)
		for k3 in 3:
			tl.draw_circle(c, (10 + k3 * 5) * S, Color(1.0, 0.55, 0.15, 0.035 * fl))
	var ch := float(g.get_var(p, "charge"))
	if ch > 0.5:
		var seed := int(real * 10.0) + p.x * 7 + p.y * 13
		if seed % 3 != 0:
			var a := r.position + Vector2((seed * 37) % 10 + 3, (seed * 11) % 6 + 2) * S
			var pts := PackedVector2Array([a])
			for i in 4:
				a += Vector2(((seed + i) % 3 - 1) * 2, 2) * S
				pts.append(a)
			tl.draw_polyline(pts, Color(1.0, 0.95, 0.4, 0.9), S)
	var f := EnvironmentStep.force_at(g, p)
	if f.length() > 0.4:
		var gs := Art.fx("gust_right")
		tl.draw_rect(r, Color(0.67, 0.82, 0.92, 0.13))
		if gs.is_empty():
			var d := f.normalized()
			for i in 3:
				var k := fmod(real * 1.6 + i / 3.0 + (p.x + p.y) * 0.13, 1.0)
				var lane := Vector2(-d.y, d.x) * (i - 1) * 4.0 * S
				var s0 := c + lane + d * (k - 0.5) * (C - 8 * S)
				tl.draw_line(s0, s0 + d * 4 * S, Color(0.92, 1.0, 0.95, 0.6 * sin(k * PI)), S)
		else:
			# the strip blows right; turn it to the force's main direction
			var ang := 0.0
			if absf(f.x) >= absf(f.y):
				ang = 0.0 if f.x > 0 else PI
			else:
				ang = PI / 2 if f.y > 0 else -PI / 2
			tl.draw_set_transform(c, ang)
			for k4 in 2:
				_sprite(tl, gs, Vector2.ZERO, Art.frame_at(gs, real, k4 * 11 + p.x), Color(1, 1, 1, 0.75 - k4 * 0.35))
			tl.draw_set_transform(Vector2.ZERO, 0.0)
	var pr := float(g.get_var(p, "pressure"))
	if pr > 2.0:
		var k2 := fmod(real * 0.8, 1.0)
		tl.draw_rect(r.grow(-S - k2 * 6 * S), Color(0.8, 0.7, 1.0, 0.5 * (1.0 - k2)), false, S)

func _hand(tl: Control, c: Vector2, ang: float, col: Color) -> void:
	tl.draw_arc(c, 5 * S, 0, TAU, 16, Color(col, col.a * 0.5), S)
	tl.draw_line(c, c + Vector2(sin(ang), -cos(ang)) * 4 * S, col, S)

## One sprite from an fx strip with its anchor on the cell's ground point.
func _sprite(tl: Control, st: Dictionary, ground: Vector2, i: int, mod := Color.WHITE, flip := false, sc := 1.0) -> void:
	if st.is_empty():
		return
	var src := Art.frame_src(st, i)
	var sz := src.size * S * sc
	var at := ground - Vector2(st["ax"], st["ay"]) * S * sc
	var dst := Rect2(at, sz)
	if flip:
		dst = Rect2(ground + Vector2(st["ax"] * S * sc, -st["ay"] * S * sc), Vector2(-sz.x, sz.y))
	tl.draw_texture_rect_region(st["tex"], dst, src, mod)

func _fx(tl: Control, kind: String, p: Vector2i, off: Vector2) -> void:
	var ground := feet(Vector2(p)) + off
	var alpha := 0.35 if aiming else 1.0
	var ev = cell_events.get(p)
	if kind == "fire" and ev != null and ev["kind"] == "fire_ignite" and real - float(ev["t0"]) < 0.75:
		var sti := Art.fx("fire_ignite")
		_sprite(tl, sti, ground, Art.frame_at(sti, real - float(ev["t0"])), Color(1, 1, 1, alpha))
		return
	var st := Art.fx(kind)
	if kind == "crystal":
		# floating gem, own shadow baked in; it hovers over the head of a unit held in the cell
		if battle.grid.unit_at(p) != null:
			ground -= Vector2(0, 14 * S)
		_crystal_glow(tl, ground, alpha)
		_sprite(tl, st, ground, Art.frame_at(st, clock, p.x * 7 + p.y * 5), Color(1, 1, 1, alpha))
		return
	if kind != "fire":
		tl.draw_rect(Rect2(ground + Vector2(-7 * S, 1 * S), Vector2(14 * S, 3 * S)), Color(0, 0, 0, 0.3 * alpha))
	_sprite(tl, st, ground, Art.frame_at(st, clock, p.x * 7 + p.y * 5), Color(1, 1, 1, alpha))

func _crystal_glow(tl: Control, ground: Vector2, alpha: float) -> void:
	var c := ground - Vector2(0, 10 * S)
	for k in 3:
		tl.draw_circle(c, (6 + k * 4) * S, Color(0.7, 0.5, 1.0, 0.05 * alpha))

func _block(tl: Control, kind: String, p: Vector2i, off: Vector2) -> void:
	var r := cell_rect(p)
	r.position += off
	if kind == "wall":
		var wall := Art.tex("floor/stone_wall_top.png")
		tl.draw_rect(Rect2(r.position + Vector2(0, C - 3 * S), Vector2(C, 4 * S)), Color(0, 0, 0, 0.35))
		tl.draw_texture_rect_region(wall, Rect2(r.position - Vector2(0, C * 0.5), Vector2(C, C)), Rect2((p.x * 3 + p.y) % 4 * Art.T, 0, Art.T, Art.T))
		tl.draw_rect(Rect2(r.position + Vector2(0, C * 0.5), Vector2(C, C * 0.5 - S)), Color("#2a2a36"))
		tl.draw_rect(Rect2(r.position + Vector2(0, C * 0.5), Vector2(C, S)), Color("#191922"))
	else:
		# mirror pane: silver frame, glassy face with a moving glint
		var a := 0.4 if aiming else 1.0
		var fr := Rect2(r.position + Vector2(3 * S, -4 * S), Vector2(10 * S, 17 * S))
		tl.draw_rect(Rect2(fr.position + Vector2(-S, fr.size.y), Vector2(fr.size.x + 2 * S, 2 * S)), Color(0, 0, 0, 0.35 * a))
		tl.draw_rect(fr, Color(Color("#c8d0dc"), a))
		tl.draw_rect(fr.grow(-S), Color(Color("#6e8fae"), a))
		var gx := fmod(real * 0.5, 1.0) * fr.size.x
		tl.draw_line(fr.position + Vector2(gx, S), fr.position + Vector2(gx - 4 * S, fr.size.y - S), Color(1, 1, 1, 0.6 * a), S)
		tl.draw_rect(fr, Color(Art.INK, a), false, S)

func _unit(tl: Control, u: Actor, off: Vector2) -> void:
	var cp := _pos_of(u)
	var st := Art.unit(Art.unit_id(u))
	if st.is_empty():
		return
	var f := feet(cp) + off
	# moving between cells: a little hop
	var frac := absf(cp.x - round(cp.x)) + absf(cp.y - round(cp.y))
	var hop := -sin(minf(frac * 2.0, 1.0) * PI) * 3 * S if replaying else 0.0
	var hit_k := (real - float(flashes[u.uid])) if flashes.has(u.uid) else 9.0
	var push := Vector2.ZERO
	if lunges.has(u.uid):
		var lk: float = (real - float(lunges[u.uid]["t0"])) / 0.22
		if lk < 1.0:
			push = lunges[u.uid]["dir"] * 3 * S * sin(lk * PI)
	if hit_k < 0.15:
		push += Vector2(-1 if _faces_left(u) else 1, 0) * -S
	tl.draw_rect(Rect2(f - Vector2(6 * S, 2 * S), Vector2(12 * S, 4 * S)), Color(0, 0, 0, 0.43))
	var look_left := _faces_left(u)
	var flip: bool = look_left == bool(st["faces_right"])
	var ground := f + push + Vector2(0, hop)
	var idx := Art.frame_at(st, clock * 1.0, u.uid * 3)
	var tint := Color(0.35, 0.2, 0.55, 0.7) if u.controller == "echo" else Color.WHITE
	_sprite(tl, st, ground, idx, tint, flip)
	if hit_k < 0.09:
		_sprite(tl, st, ground, idx, Color(5, 5, 5, 1), flip)   # white flash
	if u.has_status("shocked"):
		var sh := Art.fx("shock")
		_sprite(tl, sh, f - Vector2(0, st["h"] * 0.45 * S), Art.frame_at(sh, clock * 3.0, u.uid))
	if u.has_status("crystal"):
		if battle.grid.get_material(u.pos) != "crystal":
			var cr := Art.fx("crystal")
			var cg := f - Vector2(0, 14 * S)
			_crystal_glow(tl, cg, 1.0)
			_sprite(tl, cr, cg, Art.frame_at(cr, clock, u.uid))
	if u.has_status("frozen"):
		tl.draw_rect(Rect2(f - Vector2(st["w"] * 0.4 * S, st["h"] * 0.85 * S), Vector2(st["w"] * 0.8 * S, st["h"] * 0.85 * S)), Color(0.7, 0.9, 1.0, 0.35))

## 시한폭탄: the bomb with a burning fuse, its blast area and the seconds left.
func _bomb(tl: Control, tm: Dictionary, off: Vector2) -> void:
	var left: int = int(tm["at"]) - battle.now
	var pulse := 0.5 + 0.5 * sin(real * (10.0 if left <= 1 else 5.0))
	for p in tm["cells"]:
		var r := cell_rect(p, S)
		r.position += off
		tl.draw_rect(r, Color(1.0, 0.45, 0.2, 0.10 + 0.10 * pulse))
		tl.draw_rect(r, Color(1.0, 0.5, 0.2, 0.55), false, S)
	var c := cell_rect(tm["aim"]).get_center() + off + Vector2(0, 2 * S)
	tl.draw_circle(c + Vector2(0, S), 5 * S, Color(0, 0, 0, 0.35))
	tl.draw_circle(c, 5 * S, Color("#1d1b24"))
	tl.draw_circle(c - Vector2(1.5, 1.5) * S, 1.5 * S, Color(1, 1, 1, 0.35))
	tl.draw_line(c + Vector2(2, -4) * S, c + Vector2(4, -7) * S, Color("#b08840"), S)
	tl.draw_circle(c + Vector2(4, -7) * S, (1.2 + pulse) * S, Color(1.0, 0.8, 0.3, 0.9))
	var txt := "%d" % maxi(0, left)
	var bp := cell_rect(tm["aim"]).position + off + Vector2(C - 6 * S, 2 * S)
	tl.draw_string_outline(font, bp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 5, Art.INK)
	tl.draw_string(font, bp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("#ffcf6a"))

func _faces_left(u: Actor) -> bool:
	# the body's own facing (back attacks depend on it); straight up/down keeps the nearest foe
	if u.facing.x != 0:
		return u.facing.x < 0
	var best := 999
	var dx := 0
	for o in battle.actors:
		if o == u or o.team == u.team or not battle.grid.units.has(o):
			continue
		var d := Battle.dist(o.pos, u.pos)
		if d < best:
			best = d
			dx = o.pos.x - u.pos.x
	return dx < 0

func _hp_bar(tl: Control, u: Actor, off: Vector2) -> void:
	var f := feet(_pos_of(u)) + off + Vector2(0, 3 * S)
	var hp := _hp_of(u)
	var w := 18 * S
	var r := Rect2(f - Vector2(w / 2, 0), Vector2(w, 3 * S))
	tl.draw_rect(r.grow(S), Art.INK)
	tl.draw_rect(r, Color("#3a1418"))
	var mine := u.controller == "human"
	var fill := Color("#e04848") if not mine else Color("#58c46a")
	tl.draw_rect(Rect2(r.position, Vector2(w * clampf(float(hp) / u.max_hp, 0, 1), r.size.y)), fill)
	tl.draw_rect(Rect2(r.position, Vector2(w * clampf(float(hp) / u.max_hp, 0, 1), S)), fill.lightened(0.3))
	if u.shield > 0:
		var sw := w * clampf(float(u.shield) / u.max_hp, 0.05, 1)
		tl.draw_rect(Rect2(r.position - Vector2(0, S), Vector2(sw, r.size.y + 2 * S)), Color(0.55, 0.8, 1.0, 0.85))
	var txt := "%d" % hp + ("+%d" % u.shield if u.shield > 0 else "")
	var tp := Vector2(r.end.x + 2 * S, r.end.y + 2)
	tl.draw_string_outline(font, tp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 5, Art.INK)
	tl.draw_string(font, tp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("#bfe3ff") if u.shield > 0 else Color.WHITE)
	# states as small marks above the head
	var marks := []
	for s in ["burning", "wet", "frozen", "crystal", "shocked", "rooted", "shadowed", "poisoned"]:
		if u.has_status(s):
			marks.append(s)
	var ust := Art.unit(Art.unit_id(u))
	var head := feet(_pos_of(u)) + off - Vector2(0, (float(ust.get("ay", 22)) + 3) * S)
	for i in marks.size():
		_mark(tl, marks[i], head + Vector2((i - (marks.size() - 1) / 2.0) * 7 * S, 0))
	# predicted damage of the aimed card
	if preview.has("damage_by_uid") and preview["damage_by_uid"].has(u.uid):
		var dmg := int(preview["damage_by_uid"][u.uid])
		var pulse := 0.7 + 0.3 * sin(real * 6.0)
		var dp := r.position + Vector2(0, -4 * S)
		tl.draw_string_outline(font, dp, "-%d" % dmg, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, 6, Art.INK)
		tl.draw_string(font, dp, "-%d" % dmg, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 0.35, 0.3, pulse))

func _mark(tl: Control, s: String, c: Vector2) -> void:
	var col: Color = {"burning": Color("#ff8a3a"), "wet": Color("#5aa8ff"), "frozen": Color("#bfe8ff"),
		"crystal": Color("#b48cff"), "shocked": Color("#ffe14a"), "rooted": Color("#b0a090"), "shadowed": Color("#5a3a8a"), "poisoned": Color("#7ad04a")}[s]
	tl.draw_circle(c, 3 * S, Art.INK)
	tl.draw_circle(c, 2 * S, col)

func _telegraph(tl: Control, t: Dictionary, off: Vector2) -> void:
	var left: int = int(t["fire_at"]) - (shown_now if replaying else battle.now)
	var hot := left <= 1
	var pulse := 0.5 + 0.5 * sin(real * (9.0 if hot else 4.0))
	var col := Art.DANGER if hot else Color("#ff8a3a")
	var cells: Array = t["cells"]
	var centre := Vector2.ZERO
	var box := Rect2()
	for p in cells:
		box = cell_rect(p) if box.size == Vector2.ZERO else box.merge(cell_rect(p))
		var r := cell_rect(p, S)
		r.position += off
		tl.draw_rect(r, Color(col, 0.16 + 0.12 * pulse))
		_corners(tl, r, Color(col, 0.75 + 0.25 * pulse), 4 * S)
		centre += r.get_center()
	if cells.is_empty():
		return
	centre /= cells.size()
	var a: Actor = battle._actor(t["actor_uid"])
	if a == null or not battle.grid.units.has(a):
		return
	var from := feet(_pos_of(a)) + off - Vector2(0, 8 * S)
	# chevrons running from the attacker to the area
	var d := centre - from
	var L := d.length()
	if L > C * 0.8:
		var dir := d / L
		var nrm := Vector2(-dir.y, dir.x)
		var step := C * 0.55
		var shift := fmod(real * (2.0 if hot else 1.0), 1.0) * step
		var s := step * 0.6 + shift
		while s < L - C * 0.35:
			var pnt := from + dir * s
			var k := s / L
			var cc := Color(col, 0.35 + 0.6 * k)
			var tip := pnt + dir * 3 * S
			tl.draw_polyline(PackedVector2Array([pnt - dir * 2 * S + nrm * 3 * S, tip, pnt - dir * 2 * S - nrm * 3 * S]), Color(Art.INK, cc.a), 3 * S)
			tl.draw_polyline(PackedVector2Array([pnt - dir * 2 * S + nrm * 3 * S, tip, pnt - dir * 2 * S - nrm * 3 * S]), cc, S)
			s += step
	# seconds left: a badge on the area's top-right corner, clear of the heads standing in it
	var bp := Vector2(box.end.x, box.position.y) + off + Vector2(-2 * S, 2 * S)
	tl.draw_circle(bp, 9 * S * (1.0 + (0.12 * pulse if hot else 0.0)) * 0.7, Art.INK)
	tl.draw_circle(bp, 8 * S * 0.7, col)
	var txt := "%d" % maxi(left, 0)
	tl.draw_string(font, bp + Vector2(-5 if txt.length() == 1 else -9, 7), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Art.INK)

func _ghost(tl: Control, t: Dictionary, off: Vector2) -> void:
	var cells: Array = t["cells"]
	var a: Actor = battle._actor(t["actor_uid"])
	if cells.is_empty() or cells.size() > 4 or a == null or not battle.grid.units.has(a):
		return
	var centre := Vector2.ZERO
	for p in cells:
		centre += cell_rect(p).get_center()
	centre = centre / cells.size() + off
	var pulse := 0.5 + 0.5 * sin(real * 4.0)
	var st := Art.unit(Art.unit_id(a))
	var ghost_at := centre + Vector2(0, -C * 0.5 + 12 * S)
	_sprite(tl, st, ghost_at, 0, Color(1, 0.3, 0.25, 0.18 + 0.12 * pulse), not _faces_left(a) == bool(st.get("faces_right", false)))

## Aiming: the hovered cell, and when it is out of reach a line that falls short and fizzles.
func _aim(tl: Control, off: Vector2) -> void:
	var h := battle.human()
	if not fizzle.is_empty() and real - float(fizzle["t0"]) < 0.6:
		var k := (real - float(fizzle["t0"])) / 0.6
		var fr := cell_rect(fizzle["cell"], S + k * 4 * S)
		fr.position += off
		tl.draw_line(fr.position, fr.end, Color(Art.DANGER, 1.0 - k), 2 * S)
		tl.draw_line(Vector2(fr.end.x, fr.position.y), Vector2(fr.position.x, fr.end.y), Color(Art.DANGER, 1.0 - k), 2 * S)
	if hover.x < 0 or h == null or replaying:
		return
	var hr := cell_rect(hover)
	hr.position += off
	if not aiming:
		_corners(tl, hr.grow(-S), Color(1, 1, 1, 0.55), 3 * S)
		return
	if hover in range_cells or range_cells.is_empty():
		_corners(tl, hr.grow(-S), Color(Art.GOLD, 0.95), 4 * S)
		return
	# out of reach: the shot travels as far as it can, then droops and fizzles
	var from := feet(_pos_of(h)) + off - Vector2(0, 8 * S)
	var to := hr.get_center()
	var last := from
	var n := 24
	var reach_k := 0.0
	for i in range(1, n + 1):
		var k := float(i) / n
		var q := from.lerp(to, k)
		var cq := cell_at(q - off)
		if cq.x >= 0 and (cq in range_cells or cq == h.pos):
			reach_k = k
	last = from.lerp(to, reach_k)
	var dash := 3 * S
	var segs := int(from.distance_to(last) / (dash * 2))
	for i in segs:
		var a := from.lerp(last, float(i * 2) / maxi(1, segs * 2))
		var b := from.lerp(last, float(i * 2 + 1) / maxi(1, segs * 2))
		tl.draw_line(a, b, Art.INK, 3 * S)
		tl.draw_line(a, b, Color(Art.GOLD, 0.95), 2 * S)
	# the rest of the way: faint, sagging red dots that never arrive
	var rest := to - last
	for i in 6:
		var k := float(i + 1) / 7.0
		var q := last + rest * k * 0.55 + Vector2(0, k * k * 10 * S)
		tl.draw_rect(Rect2(q.snapped(Vector2(S, S)), Vector2(2 * S, 2 * S)), Color(Art.DANGER, 0.75 * (1.0 - k)))
	var puff := fmod(real * 1.5, 1.0)
	tl.draw_arc(last, (2 + puff * 5) * S, 0, TAU, 12, Color(Art.DANGER, 0.85 * (1.0 - puff)), 2 * S)
	tl.draw_rect(hr.grow(-2 * S), Color(Art.DANGER, 0.08))
	var droop := Rect2(hr.position + Vector2(0, 2 * S), hr.size).grow(-2 * S)
	var dots := 10
	for i in dots:
		var k := float(i) / dots
		tl.draw_rect(Rect2(droop.position + Vector2(droop.size.x * k, 0), Vector2(S * 2, S)), Color(Art.DANGER, 0.5))
		tl.draw_rect(Rect2(droop.position + Vector2(droop.size.x * k, droop.size.y), Vector2(S * 2, S)), Color(Art.DANGER, 0.5))
