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
var shown_now := -1.0            # world seconds of the replayed moment (between two frames)
var replaying := false
var replay_k := 0.0              # 0..1 inside the replayed second

## The moment on screen, in world seconds: the replayed moment, or the battle clock when still.
func sim_time() -> float:
	if replaying:
		return shown_now
	return battle.now if battle != null else 0.0
var moving: Dictionary = {}      # uid -> Vector2i: where a gliding unit is heading
var walk_link: Dictionary = {}   # uid -> Vector2i(walked the second before, walks the second after): a walk over several cells loops its stride instead of restarting
var _last_look: Dictionary = {}  # uid -> {st, i, flip, sq}: last drawn frame, to blend into the next motion
var _xfade: Dictionary = {}      # uid -> {look, t0}: the previous motion fading out over the new one
var casts: Array = []            # {uid, cells, t0, t1}: the player's card being performed
var _speed := 0.14
const HELD := 0.2                # how fast the world still drifts while the player thinks
static var FREEZE := true         # study: bodies brake to a full stop mid-pose; N switches to crawling on
var uclock := 0.0                # study: body time (idle loops); stops dead in FREEZE
var _uspeed := 1.0
static var BT2 := true           # bullet-time study: B toggles the new look against the old one
const HELD2 := 0.06              # study: held time is much slower ...
const XFADE := 0.12   # seconds (wall clock) one motion takes to melt into the next
var rt := 0.0                    # study: true real time (UI pulses), while `real` becomes world time
var _wspeed := 1.0
var drift := false               # the seconds playing are only the ring turning (set by the battle screen)
var _drifted := false
var pulse_t0 := -9.0             # study: real time the world last snapped into held time
var _was_replaying := false
var acts: Dictionary = {}        # uid -> {kind, t0, t1}: game seconds of a roll / guard card
var trails: Array = []           # study: {uid, pos, t} afterimages left by moving units
var _bf := {}
var play_speed := 1.0            # game speed (1-5 keys): effects run faster with the replay
var self_aim := false            # a picked card with no target (방어 ...): the hero lights up instead of an arc
var forecast := 0                # seconds the picked action will take: warnings landing in them stand out
var walk_path: Array = []        # cells of the walk being dragged
var walk_mode := "go"            # "hold" until dragged right, "go" once confirmed, "cancel" when dragged left

var origin := Vector2(C, C * 2)  # top-left of cell (0,0) inside this control
var clock := 0.0                 # effect time: crawls while paused (bullet time), runs during replay
var real := 0.0
var liquid: ColorRect
var desat: ColorRect
var marks: Control                # drawn above the held-time veil
var top: Control
var _state_img: Image
var _state_tex: ImageTexture
var _floor: PackedInt32Array = PackedInt32Array()
var _wall: PackedInt32Array = PackedInt32Array()
var _floor_for: Battle
var popups: Array = []           # {p: Vector2 local, text, col, t0}
var flashes: Dictionary = {}     # uid -> real time of last hit
var hitstop_until := 0.0        # wall clock: a heavy hit freezes everything for a beat
var flash_rt: Dictionary = {}     # uid -> wall-clock time of last hit: the white flash always shows, however fast or slow the world runs
var _last_hp: Dictionary = {}
var shake_until := 0.0
var fizzle: Dictionary = {}      # {cell, t0}: an out-of-range click
var bursts: Array = []           # {cells, col, t0, beam_from}: a card or a blow landing
var lunges: Dictionary = {}      # uid -> {t0, dir}: attacker leaning into its blow
var beams: Array = []            # {from, path, bends, t0}
var oneshots: Array = []         # {fx, ground (local), t0, flip, under, sc, a, life}: slashes, hits, dust
var _moves: Dictionary = {}       # uid -> {fast, dir, next}: a body on the move, for its dust
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
	# held time: the whole world (floor, units, effects) drains to black-and-white; the marks above stay in colour
	desat = ColorRect.new()
	desat.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dm := ShaderMaterial.new()
	dm.shader = load("res://src/view/held_tint.gdshader")
	desat.material = dm
	add_child(desat)
	marks = Control.new()
	marks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marks.draw.connect(_draw_marks)
	add_child(marks)
	fit()

func fit() -> void:
	size = Vector2((Grid.W + 2) * C, (Grid.H + 3) * C)
	custom_minimum_size = size
	if liquid:
		liquid.position = origin
		liquid.size = Vector2(Grid.W, Grid.H) * C
		top.size = size
		marks.size = size
		# the whole room, walls included, so held time reads as black-and-white, not as a tint
		desat.position = Vector2.ZERO
		desat.size = size
		(liquid.material as ShaderMaterial).set_shader_parameter("grid", Vector2(Grid.W, Grid.H))
	_state_img = Image.create(Grid.W, Grid.H, false, Image.FORMAT_RGBA8)
	_state_tex = ImageTexture.create_from_image(_state_img)

func _process(delta: float) -> void:
	rt += delta
	var held := HELD2 if BT2 else HELD
	# effects crawl while the player thinks (bullet time) and ramp back up when time flows
	var target := play_speed if replaying else (0.0 if battle != null and battle.borrowing() else held)
	if BT2 and not replaying:
		_speed = lerpf(_speed, target, 1.0 - exp(-delta * 5.0))   # ease out: things visibly decelerate
	else:
		_speed = move_toward(_speed, target, delta * 4.0)
	clock += delta * _speed
	# bodies: crawl like the rest, or (FREEZE) brake smoothly to a dead stop mid-pose
	var utarget := _speed if replaying else (0.0 if (BT2 and FREEZE) else _speed)
	if BT2:
		# bodies ease both ways: they brake into held time and pick up speed again, never lurch
		_uspeed = lerpf(_uspeed, utarget, 1.0 - exp(-delta * (4.0 if utarget < _uspeed else 6.0)))
	else:
		_uspeed = lerpf(_uspeed, utarget, 1.0 - exp(-delta * 4.0)) if utarget < _uspeed else utarget
	if _uspeed < 0.004:
		_uspeed = 0.0
	if rt < hitstop_until:
		_uspeed = 0.0   # hit-stop: the whole world catches on the blow for a beat
	uclock += delta * _uspeed
	# world time: hits, slashes, flashes and bursts also crawl (or stop) in held time (study only)
	_wspeed = _uspeed if BT2 else 1.0
	real += delta * _wspeed
	if drift and replaying:
		_drifted = true
	if BT2 and _was_replaying and not replaying:
		if not _drifted:
			pulse_t0 = rt   # (after only the ring turning the world never left grey: no new wave)
		_drifted = false
	if BT2 and replaying and not _was_replaying and not drift:
		pulse_t0 = -rt   # negative: colour floods back in
	_was_replaying = replaying
	if BT2 and battle != null and replaying:
		for u in battle.actors:
			if shown_pos.has(u.uid):
				var cp := _pos_of(u)
				var fr := absf(cp.x - round(cp.x)) + absf(cp.y - round(cp.y))
				var last_t := -9.0
				for q in trails:
					if int(q["uid"]) == u.uid:
						last_t = maxf(last_t, float(q["t"]))
				if fr > 0.05 and real - last_t > 0.07:
					trails.append({"uid": u.uid, "pos": cp, "t": real})
	trails = trails.filter(func(q): return real - float(q["t"]) < 0.25)
	if marks:
		# while time flows the scene plays like film: warnings and numbers fade back, and return when time is held
		marks.modulate.a = lerpf(marks.modulate.a, lerpf(0.15, 1.0, _calm()) if BT2 else 1.0, 1.0 - exp(-delta * 8.0))
	if desat:
		var m := desat.material as ShaderMaterial
		m.set_shader_parameter("amount", _calm() if BT2 else 0.0)
		var h := battle.human() if battle != null else null
		if h != null:
			m.set_shader_parameter("center", (feet(_pos_of(h)) - Vector2(0, 8 * S)) / size)
		m.set_shader_parameter("aspect", size.x / size.y)
		m.set_shader_parameter("wave", (rt - pulse_t0) if pulse_t0 >= 0.0 else 9.0)
	if battle != null:
		_update_liquids()
		_track_hits()
		_move_dust(delta)
		_track_cells()
	queue_redraw()
	if top:
		top.queue_redraw()
	if marks:
		marks.queue_redraw()

func _calm() -> float:
	var held := HELD2 if BT2 else HELD
	var c := 1.0 - clampf((_speed - held) / maxf(0.01, play_speed - held), 0.0, 1.0)
	if BT2 and (drift or _drifted):
		c = maxf(c, 0.6)   # the ring turning lets time slip by in grey: colour only comes back for real actions
	return c

## Frame index for a strip at time t; also remembers how far it is toward the next frame,
## so _sprite can cross-fade the two in held time instead of flipping at 1-5 fps.
func _fr(st: Dictionary, t: float, offset := 0) -> int:
	var f := t * float(st["fps"]) + offset
	var i := int(floor(f))
	var n := int(st["n"])
	var nx := i + 1
	if st["loop"]:
		i = posmod(i, n); nx = posmod(nx, n)
	else:
		i = clampi(i, 0, n - 1); nx = clampi(nx, 0, n - 1)
	_bf = {"tex": st["tex"], "i": i, "n": nx, "a": f - floor(f)}
	return i

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
	puff("crystal_shards", cell_rect(p).get_center() - Vector2(0, 6 * S), false, 0.25)   # slow tumbling shards on top

func _oneshots(tl: Control, off: Vector2, under: bool) -> void:
	for q in oneshots:
		if bool(q.get("under", false)) != under:
			continue
		var k: float = real - float(q["t0"])
		if k < 0.0:
			continue
		var st := Art.fx(q["fx"])
		if not st.is_empty() and k * st["fps"] < st["n"]:
			_sprite(tl, st, q["ground"] + off, Art.frame_at(st, k), Color(1, 1, 1, float(q.get("a", 1.0))), q["flip"], float(q.get("sc", 1.0)))

## A one-shot effect sprite on world time (so it hangs in held time). Ground is board-local.
func puff(fx: String, ground: Vector2, flip := false, delay := 0.0, under := false, sc := 1.0, a := 1.0) -> void:
	var st := Art.fx(fx)
	if st.is_empty():
		return
	oneshots.append({"fx": fx, "ground": ground, "t0": real + delay, "flip": flip, "under": under, "sc": sc, "a": a,
		"life": delay + float(st["n"]) / float(st["fps"])})

## Water or fire landing on bodies: droplets / embers fly off each one that is hit.
func splash(cells: Array, kind: String) -> void:
	for p in cells:
		if battle.grid.unit_at(p) != null:
			puff("droplets" if kind == "water" else "embers", feet(Vector2(p)) - Vector2(0, 8 * S), randf() < 0.5, 0.05)

## Dust and speed as bodies move: a puff when a step starts, a trail and speed lines for a roll
## or a dash (more than a cell a second), a dust ring where a fast body lands.
func _move_dust(delta: float) -> void:
	if battle == null:
		return
	for u in battle.actors:
		var going: bool = replaying and moving.has(u.uid)
		var was: Dictionary = _moves.get(u.uid, {})
		var cp := _pos_of(u)
		var f := feet(cp)
		if going and was.is_empty():
			var to := Vector2(moving[u.uid])
			var dir := to - cp
			var act: Dictionary = acts.get(u.uid, {})
			var fast: bool = dir.length() > 1.5 or act.get("kind", "") == "roll"
			_moves[u.uid] = {"fast": fast, "dir": dir.normalized(), "next": real}
			puff("roll_dust", f + Vector2(0, -2 * S), dir.x > 0, 0.0, true, 0.6 if not fast else 1.0, 0.9)
			if fast:
				puff("speed_lines", f - Vector2(0, 9 * S) - dir.normalized() * 8 * S, dir.x < 0, 0.0, false, 1.0, 0.8)
		elif going and bool(was["fast"]) and real >= float(was["next"]):
			was["next"] = real + 0.16
			puff("roll_dust", f + Vector2(0, -2 * S), float(was["dir"].x) > 0, 0.0, true, 0.8, 0.8)
		elif not going and not was.is_empty():
			if bool(was["fast"]):
				puff("land_ring", f, false, 0.0, true, 1.0, 0.9)
			_moves.erase(u.uid)

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
	if d.length() <= 1.6 and Art.strip("units", Art.unit_id(a) + "_act.png").is_empty():
		oneshots.append({"fx": "slash", "ground": feet(Vector2(a.pos)) - Vector2(0, 6 * S), "t0": real, "flip": dir.x < 0})
	for p in cells:
		if battle.grid.unit_at(p) != null:
			puff("hit_spark", feet(Vector2(p)) - Vector2(0, 9 * S), randf() < 0.5, 0.06)

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
	_doors(off)
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
		if m == "fire":
			var fl := 0.5 + 0.5 * sin(clock * 6.0 + p.x * 2.1 + p.y)
			draw_rect(Rect2(at, Vector2(C, C)), Color(0.47, 0.12, 0.04, 0.3 + 0.1 * fl))
			draw_rect(Rect2(at + Vector2(1, 1), Vector2(C - 2, C - 2)), Color(1.0, 0.47, 0.16, 0.45 + 0.15 * fl), false, S)
		elif g.has_state(p, "blaze"):
			var fb := 0.5 + 0.5 * sin(clock * 5.0 + p.x * 1.7 + p.y)
			draw_rect(Rect2(at, Vector2(C, C)), Color(1, 0.25, 0.05, 0.32 + 0.08 * fb))
		elif g.has_state(p, "heat"):
			draw_rect(Rect2(at, Vector2(C, C)), Color(1, 0.4, 0.12, 0.22))
		elif g.has_state(p, "cold") and m != "ice":
			draw_rect(Rect2(at, Vector2(C, C)), Color(0.6, 0.85, 1.0, 0.24))
		if g.has_state(p, "damp") and m != "water":
			draw_rect(Rect2(at, Vector2(C, C)), Color(0.35, 0.6, 1.0, 0.12))
		if g.has_state(p, "slick") and m != "oil" and m != "ice":
			draw_rect(Rect2(at + Vector2(2, 2) * S, Vector2(C - 4 * S, C - 4 * S)), Color(0.85, 0.95, 0.75, 0.14))
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
	if replaying:
		return shown_pos.get(u.uid, Vector2(u.pos))
	# held mid-step (불릿타임): a monster still on its way stands where it has got to
	if not u.glide.is_empty() and u.glide[1] == u.pos and battle != null and battle.tick < int(u.glide[3]):
		var span := float(int(u.glide[3]) - int(u.glide[2]))
		if span > Battle.TPS * battle.world_rate() + 0.5:
			var gk := clampf(float(battle.tick - int(u.glide[2])) / span, 0.0, 1.0)
			return Vector2(u.glide[0]).lerp(Vector2(u.glide[1]), gk * gk * (3.0 - 2.0 * gk))
	return Vector2(u.pos)

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
			flash_rt[u.uid] = rt
			if replaying:
				hitstop_until = maxf(hitstop_until, rt + clampf(0.03 + 0.012 * float(int(_last_hp[u.uid]) - hp), 0.05, 0.14))
		elif _last_hp.has(u.uid) and hp > int(_last_hp[u.uid]):
			popups.append({"p": feet(_pos_of(u)) - Vector2(0, 30 * S), "text": "+%d" % (hp - int(_last_hp[u.uid])),
				"col": Color("#7ee08a"), "t0": real})
		_last_hp[u.uid] = hp
	popups = popups.filter(func(q): return real - q["t0"] < 1.0)

func reset_tracking() -> void:
	_last_hp.clear()
	popups.clear()
	if _tracked_battle != battle:
		# a new fight (next battle or a new run): nothing of the last one's motions carries over
		_tracked_battle = battle
		acts.clear()
		casts.clear()
		lunges.clear()
		trails.clear()
		_last_look.clear()
		_xfade.clear()
		flashes.clear()
		flash_rt.clear()
		shown_pos.clear()
		shown_hp.clear()
		moving.clear()
		walk_link.clear()
		bursts.clear()
		beams.clear()
		oneshots.clear()
		_moves.clear()
		cell_events.clear()
		_prev_mat.clear()
		fizzle = {}
		walk_path = []
		replaying = false
		hitstop_until = 0.0

var _tracked_battle: Battle

# ---- top layer ----------------------------------------------------------------------------------

func _draw_top() -> void:
	if battle == null:
		return
	var g := battle.grid
	var off := _shake_off()
	var tl := top
	# haste: one big dial over each connected group, not a rune per cell
	_haste_fields(tl, off)
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
	# where each body really stands: a floor mark in its team colour
	for u in battle.actors:
		if not g.units.has(u) and not (replaying and shown_pos.has(u.uid)):
			continue
		var cell: Vector2i = moving.get(u.uid, u.pos) if replaying else u.pos
		var fr := cell_rect(cell, 2 * S)
		fr.position += off
		var fc := Color("#58c46a") if u.controller == "human" else (Color("#9a7ad8") if u.controller == "echo" else Color("#ff6a5a"))
		fc.a = lerpf(0.2, 1.0, _calm()) if BT2 else 1.0   # team rings fade while time flows, like the other marks
		tl.draw_rect(fr, Color(fc, 0.12 * fc.a))
		# a ring on the floor around the feet
		var fp := cell_rect(cell).get_center() + off + Vector2(0, C * 0.25)
		var ring := PackedVector2Array()
		for i in 25:
			var an := TAU * i / 24.0
			ring.append(fp + Vector2(cos(an) * C * 0.42, sin(an) * C * 0.17))
		tl.draw_polyline(ring, Color(Art.INK, 0.6 * fc.a), 3 * S)
		tl.draw_polyline(ring, Color(fc, 0.85 * fc.a), S)
	# y-sorted effects and units
	var items := []
	for p in g.all_cells():
		var m := g.get_material(p)
		if m == "fire" or m == "crystal" or m == "metal":
			var over := m == "crystal" and g.unit_at(p) != null
			items.append({"y": float(p.y) + (0.97 if over else 0.75), "fx": ("mirror" if m == "metal" else m), "p": p})
		elif m == "wall":
			items.append({"y": float(p.y) + 0.95, "block": m, "p": p})
		elif m in ["chest", "chest_open", "stall", "spring", "spring_dry"]:
			items.append({"y": float(p.y) + (0.2 if m in ["stall", "spring", "spring_dry"] else 0.7), "feature": m, "p": p})
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
	# ground effects (dust, landing rings) sit under the bodies
	_oneshots(tl, off, true)
	for it in items:
		if it.has("fx"):
			_fx(tl, it["fx"], it["p"], off)
		elif it.has("block"):
			_block(tl, it["block"], it["p"], off)
		elif it.has("feature"):
			_feature(tl, it["feature"], it["p"], off)
		else:
			_unit(tl, it["unit"], off)
	# one-shot effects: slashes, hit bursts, fire going out, ice breaking
	oneshots = oneshots.filter(func(q): return real - float(q["t0"]) < float(q.get("life", 0.8)))
	_oneshots(tl, off, false)
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
	# bullet time: drifting motes and afterimages belong to the world, so they go grey with it
	if BT2:
		_held_look(tl, _calm())

## Above the black-and-white veil: what the player must read (warnings, paths, bars, numbers)
## keeps its colour while the world drains to grey in held time.
func _draw_marks() -> void:
	if battle == null:
		return
	var g := battle.grid
	var off := _shake_off()
	var tl := marks
	# where bodies are heading: gliding now, or an enemy's next step
	if replaying:
		for uid in moving.keys():
			var mu: Actor = battle._actor(uid)
			if mu != null:
				_move_arrow(tl, _pos_of(mu), moving[uid], off, mu.controller == "human", -1)
	else:
		for a in battle.actors:
			var it := battle.ai_intent(a)
			if it.get("kind", "") == "move":
				_move_arrow(tl, Vector2(a.pos), it["to"], off, false, battle.secs_until(int(it["at"])))
	_casts(tl, off)
	if not replaying:
		if not walk_path.is_empty() and walk_mode != "cancel":
			_walk(tl, walk_path, off, walk_mode == "hold")
			if walk_mode == "hold":
				# a little arrow at the destination: drag this way to go
				var dc := cell_rect(walk_path.back()).get_center() + off + Vector2(C * 0.55, 0)
				var nud := fmod(real * 1.5, 1.0) * 3 * S
				tl.draw_colored_polygon(PackedVector2Array([dc + Vector2(4 * S + nud, 0), dc + Vector2(nud - 2 * S, -4 * S), dc + Vector2(nud - 2 * S, 4 * S)]), Color("#9fe8b0"))
	if self_aim and not replaying and battle.human() != null:
		# no target to pick: the hero glows, click the card again to use it
		var hc := cell_rect(battle.human().pos)
		hc.position += off
		var k5 := 0.5 + 0.5 * sin(real * 5.0)
		tl.draw_rect(hc.grow(-S), Color(Art.GOLD, 0.12 + 0.10 * k5))
		_corners(tl, hc.grow((-1.0 + k5) * S), Color(Art.GOLD, 0.95), 5 * S)
	# enemy warnings: always above effects and units
	_badge_spots = []
	for t in battle.telegraphs:
		_telegraph(tl, t, off)
	if not replaying:
		# blows not started yet: an enemy in reach shows where and when its next one would land
		for a in battle.actors:
			var it := battle.ai_intent(a)
			if it.get("kind", "") == "attack" and not it["cells"].is_empty():
				_telegraph(tl, it, off)
	for tm in battle.ctx.timers:
		_bomb(tl, tm, off)
	# hp bars and states, never hidden behind sprites
	for u in battle.actors:
		if (replaying and shown_pos.has(u.uid)) or (not replaying and g.units.has(u)):
			_hp_bar(tl, u, off)
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
	var calm := _calm()
	if not BT2 and calm > 0.01:
		# a slow breathing vignette closes in while time is held
		var breath := 0.5 + 0.5 * sin(real * 1.4)
		var room := Rect2(origin, Vector2(Grid.W, Grid.H) * C)
		for i in 7:
			var w := (7 - i) * 5 * S
			var a := calm * (0.05 + 0.025 * breath) * (1.0 + i * 0.25)
			var r := room.grow(-i * 5 * S)
			tl.draw_rect(Rect2(r.position, Vector2(r.size.x, 5 * S)), Color(0.02, 0.03, 0.08, a))
			tl.draw_rect(Rect2(Vector2(r.position.x, r.end.y - 5 * S), Vector2(r.size.x, 5 * S)), Color(0.02, 0.03, 0.08, a))
			tl.draw_rect(Rect2(r.position + Vector2(0, 5 * S), Vector2(5 * S, r.size.y - 10 * S)), Color(0.02, 0.03, 0.08, a))
			tl.draw_rect(Rect2(Vector2(r.end.x - 5 * S, r.position.y + 5 * S), Vector2(5 * S, r.size.y - 10 * S)), Color(0.02, 0.03, 0.08, a))
	if not replaying and not BT2:
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

## [가속] cells joined into groups; each group gets one dial stretched over its bounding box.
func _haste_fields(tl: Control, off: Vector2) -> void:
	var st := Art.fx("haste_field")
	if st.is_empty():
		return
	var g := battle.grid
	var seen := {}
	for p in g.all_cells():
		if seen.has(p) or g.time_scale(p) <= 1.05:
			continue
		var lo := p
		var hi := p
		var todo: Array[Vector2i] = [p]
		seen[p] = true
		while not todo.is_empty():
			var q: Vector2i = todo.pop_back()
			lo = Vector2i(mini(lo.x, q.x), mini(lo.y, q.y))
			hi = Vector2i(maxi(hi.x, q.x), maxi(hi.y, q.y))
			for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				var nq: Vector2i = q + d
				if g.in_bounds(nq) and not seen.has(nq) and g.time_scale(nq) > 1.05:
					seen[nq] = true
					todo.append(nq)
		var box := cell_rect(lo).merge(cell_rect(hi))
		var wpx := box.size.x / (32.0 * S)
		var hpx := box.size.y / (32.0 * S)
		var sc := minf(wpx, hpx)
		_sprite(tl, st, box.get_center() + off, Art.frame_at(st, real, lo.x + lo.y), Color(1, 1, 1, 0.7), false, sc, Vector2(wpx / sc, hpx / sc))

## Variable states shown inside the cell they belong to: time, charge, wind, crush.
func _aura(tl: Control, p: Vector2i, off: Vector2) -> void:
	var g := battle.grid
	var r := cell_rect(p)
	r.position += off
	var c := r.get_center()
	var ts := g.time_scale(p)
	if ts <= 0.01:
		tl.draw_rect(r.grow(-S), Color(0.75, 0.75, 0.85, 0.28))
		_hand(tl, c, 0.0, Color(0.9, 0.9, 1.0, 0.7))
	elif ts < 0.95:
		tl.draw_rect(r.grow(-S), Color(0.45, 0.35, 0.7, 0.10 + (1.0 - ts) * 0.12))
		_hand(tl, c, real * 0.6 * ts, Color(0.75, 0.65, 1.0, 0.55))
	elif ts > 1.05 and Art.fx("haste_field").is_empty():
		var hs := Art.fx("haste")
		if hs.is_empty():
			_hand(tl, c, real * 4.0 * ts, Color(1.0, 0.85, 0.4, 0.7))
		else:
			_sprite(tl, hs, c, Art.frame_at(hs, real, p.x + p.y), Color(1, 1, 1, 0.6))
	var m := g.get_material(p)
	var surf := {"water": "water_splash", "ice": "ice_glint", "swamp": "swamp_bubbles"}
	if surf.has(m) and (m != "water" or (p.x * 7 + p.y * 3) % 3 == 0):
		var ss := Art.fx(surf[m])
		_sprite(tl, ss, c, _fr(ss, clock * 1.5, p.x * 5 + p.y * 9))
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
	if g.has_state(p, "heat") or g.has_state(p, "blaze"):
		# heat shimmer rising off the floor
		for k7 in 2:
			var hk := fmod(real * 0.7 + k7 * 0.5 + p.x * 0.31, 1.0)
			var hx := c.x + (k7 * 8 - 4) * S + sin(hk * 9.0) * S
			tl.draw_line(Vector2(hx, r.end.y - 4 * S - hk * 14 * S), Vector2(hx + S, r.end.y - 8 * S - hk * 14 * S), Color(1.0, 0.7, 0.35, 0.5 * sin(hk * PI)), S)
	if g.has_state(p, "cold"):
		for k8 in 3:
			var fk := fmod(real * 0.25 + k8 / 3.0 + p.y * 0.2, 1.0)
			tl.draw_rect(Rect2(r.position + Vector2((k8 * 9 + p.x * 5) % 20 + 4, fk * 20 + 2) * S, Vector2(S, S)), Color(0.9, 0.97, 1.0, 0.8 * sin(fk * PI)))
	if g.has_state(p, "miasma") or g.has_state(p, "curse"):
		var mc := Color(0.45, 0.85, 0.3, 0.16) if g.has_state(p, "miasma") else Color(0.6, 0.3, 0.8, 0.18)
		for k9 in 3:
			var ph2 := real * 0.5 + k9 * 2.1 + p.x * 1.1 + p.y * 0.7
			tl.draw_circle(c + Vector2(sin(ph2) * 6, cos(ph2 * 0.7) * 3 + 3) * S, (5 + 1.5 * sin(ph2 * 1.4)) * S, mc)
	if g.has_state(p, "echo"):
		var ek := fmod(real * 1.2, 1.0)
		tl.draw_arc(c, (3 + ek * 10) * S, 0, TAU, 20, Color(1, 1, 1, 0.5 * (1.0 - ek)), S)
	if g.has_state(p, "mana"):
		for k10 in 3:
			var mk := fmod(real * 0.5 + k10 / 3.0 + p.x * 0.17, 1.0)
			tl.draw_rect(Rect2(c + Vector2((k10 - 1) * 7, 8 - mk * 18) * S, Vector2(S, S)), Color(0.55, 0.75, 1.0, 0.9 * sin(mk * PI)))
	if g.has_state(p, "charged"):
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
	if g.has_state(p, "crush") or g.has_state(p, "collapse"):
		var k2 := fmod(real * 0.8, 1.0)
		tl.draw_rect(r.grow(-S - k2 * 6 * S), Color(0.8, 0.7, 1.0, 0.5 * (1.0 - k2)), false, S)

func _hand(tl: Control, c: Vector2, ang: float, col: Color) -> void:
	tl.draw_arc(c, 5 * S, 0, TAU, 16, Color(col, col.a * 0.5), S)
	tl.draw_line(c, c + Vector2(sin(ang), -cos(ang)) * 4 * S, col, S)

## One sprite from an fx strip with its anchor on the cell's ground point.
func _sprite(tl: Control, st: Dictionary, ground: Vector2, i: int, mod := Color.WHITE, flip := false, sc := 1.0, sq := Vector2.ONE) -> void:
	if st.is_empty():
		return
	var src := Art.frame_src(st, i)
	var sz := src.size * S * sc
	var at := ground - Vector2(st["ax"], st["ay"]) * S * sc
	if BT2 and not _bf.is_empty() and _bf["tex"] == st["tex"] and int(_bf["i"]) == i:
		var a: float = _bf["a"]
		_bf = {}
		_sprite(tl, st, ground, i, mod, flip, sc, sq)
		if _speed < 0.5 and a > 0.03:
			var nx := (i + 1) % int(st["n"]) if st["loop"] else mini(i + 1, int(st["n"]) - 1)
			if nx != i:
				_sprite(tl, st, ground, nx, Color(mod, mod.a * a), flip, sc, sq)
		return
	if flip or sq != Vector2.ONE:
		# mirror / squash around the anchor with a transform: a negative-size rect is not drawn mirrored in place
		tl.draw_set_transform(ground, 0.0, Vector2(-sq.x if flip else sq.x, sq.y))
		tl.draw_texture_rect_region(st["tex"], Rect2(at - ground, sz), src, mod)
		tl.draw_set_transform(Vector2.ZERO)
		return
	tl.draw_texture_rect_region(st["tex"], Rect2(at, sz), src, mod)

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
		_sprite(tl, st, ground, _fr(st, clock, p.x * 7 + p.y * 5), Color(1, 1, 1, alpha))
		return
	if kind != "fire":
		tl.draw_rect(Rect2(ground + Vector2(-7 * S, 1 * S), Vector2(14 * S, 3 * S)), Color(0, 0, 0, 0.3 * alpha))
	_sprite(tl, st, ground, _fr(st, clock, p.x * 7 + p.y * 5), Color(1, 1, 1, alpha))

## Doorways cut into the outer wall next to door cells. A sealed one is barred by violet
## crystal that shatters when the room is cleared.
func _doors(off: Vector2) -> void:
	var g := battle.grid
	for p in g.all_cells():
		var m := g.get_material(p)
		if m != "door" and m != "door_sealed":
			continue
		var out := Vector2i.ZERO
		if p.x == 0: out = Vector2i.LEFT
		elif p.x == Grid.W - 1: out = Vector2i.RIGHT
		elif p.y == 0: out = Vector2i.UP
		else: out = Vector2i.DOWN
		var r := cell_rect(p + out)
		r.position += off
		if out == Vector2i.UP:
			r = Rect2(r.position - Vector2(0, C), Vector2(C, 2 * C))
		var inner := r.grow(-3 * S)
		draw_rect(r.grow(-S), Color("#e0b040"))
		draw_rect(r.grow(-2 * S), Art.INK)
		draw_rect(inner, Color("#050408"))
		# light spilling in from the next room
		var lc := Color(0.95, 0.8, 0.45, 0.10 + 0.04 * sin(real * 2.0))
		draw_rect(inner.grow(-2 * S), lc)
		var cr := cell_rect(p)
		cr.position += off
		if m == "door":
			draw_rect(cr.grow(-2 * S), Color(0.95, 0.8, 0.45, 0.10), false, S)
		else:
			var pulse := 0.7 + 0.3 * sin(real * 3.0 + p.x)
			for k in 3:
				var t := (k + 1) / 4.0
				if out.x != 0:
					var y := inner.position.y + inner.size.y * t
					draw_rect(Rect2(inner.position.x, y - S, inner.size.x, 2 * S), Color(0.72, 0.55, 1.0, pulse))
				else:
					var x := inner.position.x + inner.size.x * t
					draw_rect(Rect2(x - S, inner.position.y, 2 * S, inner.size.y), Color(0.72, 0.55, 1.0, pulse))
			draw_rect(inner, Color(0.6, 0.4, 1.0, 0.12 * pulse))

## Room features you step on: a chest, the shop's rug, the spring.
func _feature(tl: Control, kind: String, p: Vector2i, off: Vector2) -> void:
	var r := cell_rect(p)
	r.position += off
	var c := r.get_center()
	match kind:
		"chest", "chest_open":
			var base := Rect2(c + Vector2(-7, -2) * S, Vector2(14, 9) * S)
			tl.draw_rect(Rect2(base.position + Vector2(0, base.size.y), Vector2(base.size.x, 2 * S)), Color(0, 0, 0, 0.35))
			tl.draw_rect(base.grow(S), Art.INK)
			tl.draw_rect(base, Color("#7a4a26"))
			tl.draw_rect(Rect2(base.position + Vector2(0, 3 * S), Vector2(base.size.x, S)), Color("#e0b040"))
			if kind == "chest":
				var bob := sin(real * 2.0) * 0.5 * S
				var lid := Rect2(c + Vector2(-7, -7) * S + Vector2(0, bob), Vector2(14, 5) * S)
				tl.draw_rect(lid.grow(S), Art.INK)
				tl.draw_rect(lid, Color("#93592c"))
				tl.draw_rect(Rect2(lid.position + Vector2(6 * S, 2 * S), Vector2(2 * S, 3 * S)), Color("#ffd86a"))
				for k in 2:
					var gk := fmod(real * 0.6 + k * 0.5, 1.0)
					tl.draw_rect(Rect2(c + Vector2(-4 + k * 7, -9 - gk * 8) * S, Vector2(S, S)), Color(1, 0.9, 0.5, sin(gk * PI)))
			else:
				tl.draw_rect(Rect2(base.position + Vector2(S, S), Vector2(base.size.x - 2 * S, 2 * S)), Color("#1a1016"))
				var lid2 := Rect2(c + Vector2(-7, -12) * S, Vector2(14, 4) * S)
				tl.draw_rect(lid2.grow(S), Art.INK)
				tl.draw_rect(lid2, Color("#5e3a1e"))
		"stall":
			# a merchant's rug with a fan of cards on it
			var rug := r.grow(-2 * S)
			tl.draw_rect(rug, Color("#5a1e2a"))
			tl.draw_rect(rug.grow(-S), Color("#8a2e3a"), false, S)
			tl.draw_rect(rug.grow(-3 * S), Color("#e0b040"), false, S)
			for k in 3:
				var ang := (k - 1) * 0.35
				tl.draw_set_transform(c + Vector2(0, 2 * S), ang)
				tl.draw_rect(Rect2(Vector2(-3, -9) * S, Vector2(6, 9) * S), Art.INK)
				tl.draw_rect(Rect2(Vector2(-2, -8) * S, Vector2(4, 7) * S), Color("#2a4a9a") if k != 1 else Color("#e8dcc0"))
				tl.draw_set_transform(Vector2.ZERO)
			var coin := 0.5 + 0.5 * sin(real * 3.0)
			tl.draw_circle(c + Vector2(6, 5) * S, 2 * S, Color("#e0b040"))
			tl.draw_circle(c + Vector2(6, 5) * S, S, Color(1, 0.95, 0.6, coin))
		"spring", "spring_dry":
			var rim := r.grow(-S)
			tl.draw_rect(rim, Color("#6a6a7a"))
			tl.draw_rect(rim.grow(-S), Art.INK, false, S)
			var pool := rim.grow(-2 * S)
			if kind == "spring":
				tl.draw_rect(pool, Color("#2f6fd0"))
				for k in 3:
					var wk := fmod(real * 0.5 + k / 3.0, 1.0)
					tl.draw_rect(Rect2(pool.get_center() - Vector2(wk * 6, wk * 3) * S, Vector2(wk * 12, wk * 6) * S), Color(0.75, 0.9, 1.0, 0.6 * (1.0 - wk)), false, S)
				tl.draw_circle(pool.get_center(), 2 * S, Color(0.8, 0.95, 1.0, 0.5 + 0.3 * sin(real * 2.5)))
			else:
				tl.draw_rect(pool, Color("#2a2630"))

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
	var act_s := Art.strip("units", Art.unit_id(u) + "_act.png")
	if lunges.has(u.uid) and act_s.is_empty():
		var lk: float = (real - float(lunges[u.uid]["t0"])) / 0.22
		if lk < 1.0:
			push = lunges[u.uid]["dir"] * 3 * S * sin(lk * PI)
	if hit_k < 0.15:
		push += Vector2(-1 if _faces_left(u) else 1, 0) * -S
	tl.draw_rect(Rect2(f - Vector2(6 * S, 2 * S), Vector2(12 * S, 4 * S)), Color(0, 0, 0, 0.43))
	var look_left := _faces_left(u)
	var flip: bool = look_left == bool(st["faces_right"])
	var ground := f + push + Vector2(0, hop)
	var idx := _fr(st, uclock * 1.0, u.uid * 3)
	var tint := Color(0.35, 0.2, 0.55, 0.7) if u.controller == "echo" else Color.WHITE
	# alive while time is held: idle loop (or slow breathing), an attacker visibly winding up for
	# its blow, then the strike, a flinch when hit, and the hero's step while walking
	var sid := Art.unit_id(u)
	var sq := Vector2.ONE
	var body_st := st   # base sprite size: status marks sit on the body, not on a wider motion canvas
	var idle := Art.strip("units", sid + "_idle.png")
	if not idle.is_empty():
		st = idle
		idx = _fr(idle, uclock, u.uid * 7)
	else:
		sq = Vector2(1.0, 1.0 + 0.025 * sin(uclock * 2.2 + u.uid))
	var lk := (real - float(lunges[u.uid]["t0"])) if lunges.has(u.uid) else 9.0
	var hit_s := Art.strip("units", sid + "_hit.png")
	var strike_s := Art.strip("units", sid + "_strike.png")
	var walk_s := Art.strip("units", sid + "_walk.png")
	var wind := _windup(u)
	var flashed := false
	var hurt_s := Art.strip("units", sid + "_hurt.png")
	var tc := sim_time()
	var act: Dictionary = acts.get(u.uid, {})
	if not act.is_empty() and tc > float(act["t1"]) + 0.01:
		acts.erase(u.uid)
		act = {}
	var act_k := clampf((tc - float(act.get("t0", 0))) / maxf(0.01, float(act.get("t1", 1)) - float(act.get("t0", 0))), 0.0, 0.999) if not act.is_empty() else -1.0
	var act_strip := Art.strip("units", sid + "_" + str(act.get("kind", "")) + ".png") if not act.is_empty() else {}
	if not hurt_s.is_empty() and hit_k < hurt_s["n"] / 24.0:
		# exaggerated flinch drawn frame by frame (plays on world time, so it hangs in held time)
		st = hurt_s
		idx = _fr(hurt_s, hit_k)
		ground += Vector2(1 if look_left else -1, 0) * 2 * S * sin(minf(hit_k * 4.0, 1.0) * PI)
	elif not act_s.is_empty() and lk < (act_s["n"] - act_s["peak"]) / 24.0:
		# the blow itself: the release half of the exaggerated attack strip
		st = act_s
		idx = _fr(act_s, lk, act_s["peak"])
	elif not act_s.is_empty() and wind.has("k"):
		# the wind-up half, driven by how close the blow is: it holds the cocked pose at the end
		st = act_s
		var kk: float = wind["k"] * float(act_s["peak"] - 1)
		idx = int(kk)
		_bf = {"tex": act_s["tex"], "i": idx, "n": mini(idx + 1, act_s["peak"] - 1), "a": kk - floor(kk)}
	elif not act_strip.is_empty():
		# 구르기 / 방어 / 받아치기: the card's own motion across its seconds
		st = act_strip
		# a blow being wound up plays only the strip's wind-up half (up to its peak); the release comes when it lands
		var last := (int(act_strip["peak"]) - 1) if act.get("kind", "") == "act" and int(act_strip["peak"]) > 0 else int(act_strip["n"]) - 1
		var kf := act_k * float(last)
		idx = int(kf)
		_bf = {"tex": act_strip["tex"], "i": idx, "n": mini(idx + 1, last), "a": kf - floor(kf)}
		if replaying and frac > 0.01:
			ground.y -= hop
	elif not hit_s.is_empty() and hit_k < hit_s["n"] / 24.0:
		st = hit_s
		idx = clampi(int(hit_k * 24.0), 0, hit_s["n"] - 1)
		flashed = true
	elif not strike_s.is_empty() and lk < strike_s["n"] / 24.0:
		st = strike_s
		idx = clampi(int(lk * 24.0), 0, strike_s["n"] - 1)
	elif wind.has("k"):
		var k: float = wind["k"]
		var ws := Art.strip("units", sid + "_windup.png")
		if not ws.is_empty():
			st = ws
			idx = clampi(int(k * (ws["n"] - 1)), 0, ws["n"] - 1)
			sq = Vector2.ONE
		else:
			# crouch and draw back away from the target, trembling harder as the blow nears
			sq = Vector2(1.0 + 0.10 * k, 1.0 - 0.14 * k)
			var away: Vector2 = -wind["dir"]
			ground += away * 3 * S * k + Vector2(sin(real * 40.0 + u.uid), 0) * S * k * k
			tint = tint.lerp(Color(1.4, 0.75, 0.7, tint.a), 0.6 * k * (0.6 + 0.4 * sin(real * 8.0)))
	elif replaying and frac > 0.01 and not Art.strip("units", sid + "_run.png").is_empty():
		var rs := Art.strip("units", sid + "_run.png")
		st = rs
		var rf := _walk_frame(rs, u.uid)
		idx = int(rf)
		_bf = {"tex": rs["tex"], "i": idx, "n": mini(idx + 1, rs["n"] - 1), "a": rf - floor(rf)}
		ground.y -= hop   # the dash strip carries its own bounce
	elif replaying and frac > 0.01 and not walk_s.is_empty():
		st = walk_s
		idx = clampi(int(replay_k * walk_s["n"]), 0, walk_s["n"] - 1)
		ground.y -= hop   # the step strip carries its own bounce
	elif not replaying and u.controller == "ai":
		# about to step: lean toward the next cell, rocking slowly in held time
		var it := battle.ai_intent(u)
		if it.get("kind", "") == "move":
			var d := (Vector2(it["to"]) - Vector2(u.pos)).normalized()
			ground += d * S * (1.5 + 0.8 * sin(uclock * 3.0 + u.uid))
	if u.splits and u.split_done:
		sq *= 0.8   # a split half is a smaller body
	_sprite_sq(tl, st, ground, idx, tint, flip, sq)
	# one motion melts into the next: the last frame of the old one fades out over the new one
	var last: Dictionary = _last_look.get(u.uid, {})
	if not last.is_empty() and last["st"]["tex"] != st["tex"]:
		_xfade[u.uid] = {"look": last, "t0": rt}
	var xf: Dictionary = _xfade.get(u.uid, {})
	if not xf.is_empty():
		var xk := (rt - float(xf["t0"])) / XFADE
		if xk >= 1.0:
			_xfade.erase(u.uid)
		else:
			var lo: Dictionary = xf["look"]
			_bf = {}
			_sprite_sq(tl, lo["st"], ground, lo["i"], Color(tint, tint.a * (1.0 - xk) * 0.85), lo["flip"], lo["sq"])
	_last_look[u.uid] = {"st": st, "i": idx, "flip": flip, "sq": sq}
	# white flash on a hit, on wall-clock time: solid white, a gap, then a second blink
	var fk := (rt - float(flash_rt[u.uid])) if flash_rt.has(u.uid) else 9.0
	if not flashed and (fk < 0.11 or (fk > 0.17 and fk < 0.24)):
		_sprite_sq(tl, st, ground, idx, Color(30, 30, 30, 1), flip, sq)
	if u.has_status("shocked"):
		var sh := Art.fx("shock")
		_sprite(tl, sh, f - Vector2(0, body_st["h"] * 0.45 * S), _fr(sh, clock * 3.0, u.uid))
	if u.has_status("crystal"):
		if battle.grid.get_material(u.pos) != "crystal":
			var cr := Art.fx("crystal")
			var cg := f - Vector2(0, 14 * S)
			_crystal_glow(tl, cg, 1.0)
			_sprite(tl, cr, cg, _fr(cr, clock, u.uid))
	if u.has_status("frozen"):
		tl.draw_rect(Rect2(f - Vector2(body_st["w"] * 0.4 * S, body_st["h"] * 0.85 * S), Vector2(body_st["w"] * 0.8 * S, body_st["h"] * 0.85 * S)), Color(0.7, 0.9, 1.0, 0.35))

## Frame (fractional) of a move strip for this replayed second. A walk over several cells starts
## once, loops the strip's stride (manifest "cycle") while it keeps going, and settles once at the end.
func _walk_frame(rs: Dictionary, uid: int) -> float:
	var n := float(rs["n"] - 1)
	var cy: Array = rs.get("cycle", [])
	var link: Vector2i = walk_link.get(uid, Vector2i.ZERO)
	if cy.size() < 2 or link == Vector2i.ZERO:
		return replay_k * n
	var a := float(cy[0])
	var b := float(cy[1])
	if link.x == 0:   # first cell of a longer walk: set off, then into the stride
		return replay_k * b
	if link.y == 1:   # in the middle: the stride, looping
		return a + replay_k * (b - a)
	return a + replay_k * (n - a)   # last cell: from the stride into the stop

## How far an enemy is into the wind-up of its announced blow: {k: 0..1, dir} or {}.
func _windup(u: Actor) -> Dictionary:
	if replaying:
		var tc := sim_time()
		for c in casts:
			if int(c["uid"]) == u.uid and tc >= float(c["t0"]) and tc < float(c["t1"]):
				var ck := (tc - float(c["t0"])) / maxf(0.05, float(c["t1"] - c["t0"]))
				var cd := Vector2.ZERO
				for p in c["cells"]:
					cd += Vector2(p) - _pos_of(u)
				return {"k": ck, "dir": cd.normalized() if cd.length() > 0.01 else Vector2.RIGHT}
	for t in battle.telegraphs:
		if int(t["actor_uid"]) != u.uid:
			continue
		var t_now := sim_time()
		var t0 := float(t.get("set_at", int(t["fire_at"]) - 2 * Battle.TPS)) / Battle.TPS
		var span := maxf(0.1, float(t["fire_at"]) / Battle.TPS - t0)
		var k := clampf((t_now - t0) / span, 0.0, 1.0)
		var c := Vector2.ZERO
		for p in t["cells"]:
			c += Vector2(p)
		if not t["cells"].is_empty():
			c /= t["cells"].size()
		var d := c - _pos_of(u)
		return {"k": maxf(k, 0.15), "dir": d.normalized() if d.length() > 0.01 else Vector2.LEFT}
	return {}

func _sprite_sq(tl: Control, st: Dictionary, ground: Vector2, i: int, mod: Color, flip: bool, sq: Vector2) -> void:
	_sprite(tl, st, ground, i, mod, flip, 1.0, sq)

## 시한폭탄: the bomb with a burning fuse, its blast area and the seconds left.
func _bomb(tl: Control, tm: Dictionary, off: Vector2) -> void:
	var left: float = float(tm["at"]) / Battle.TPS - sim_time()
	var pulse := 0.5 + 0.5 * sin(real * (10.0 if left <= 1.0 else 5.0))
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
	var txt := Battle.fmt_secs(maxf(0.0, left))
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
	var w := 14 * S   # narrower than a cell, so neighbours' bars never touch
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
	if Vector2i(_pos_of(u).round()) == hover:
		# numbers only where they are wanted: the hero's own, or the body under the mouse
		var txt := "%d" % hp + ("+%d" % u.shield if u.shield > 0 else "")
		var tp := Vector2(r.end.x + 2 * S, r.end.y + 2)
		tl.draw_string_outline(font, tp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 5, Art.INK)
		tl.draw_string(font, tp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("#bfe3ff") if u.shield > 0 else Color.WHITE)
	# states as small marks above the head
	var tags := []
	for s in ["burning", "wet", "frozen", "crystal", "shocked", "rooted", "shadowed", "poisoned"]:
		if u.has_status(s):
			tags.append(s)
	var ust := Art.unit(Art.unit_id(u))
	var head := feet(_pos_of(u)) + off - Vector2(0, (float(ust.get("ay", 22)) + 3) * S)
	for i in tags.size():
		_mark(tl, tags[i], head + Vector2((i - (tags.size() - 1) / 2.0) * 7 * S, 0))
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
	var left: float = float(t["fire_at"]) / Battle.TPS - sim_time()
	var hot := left <= 1.0
	var pulse := 0.5 + 0.5 * sin(real * (9.0 if hot else 4.0))
	var col := Art.DANGER if hot else Color("#ff8a3a")
	var cells: Array = t["cells"]
	var pending: bool = t.get("pending", false)
	if pending and not hot:
		col = Color("#d9a35a")
		pulse = 0.2
	var wr := battle.world_rate()
	var soon := not replaying and left <= _ahead() * wr + 0.001 and _ahead() > 0
	if soon:
		# lands during the action being planned: bolder, and a mark if it catches the hero there
		hot = true
		col = Art.DANGER
		pulse = 0.5 + 0.5 * sin(real * 10.0)
		var spot := _hero_at(int(ceil(left / wr - 0.001)))
		if cells.has(spot):
			_danger_mark(tl, cell_rect(spot).get_center() + off, _blow_damage(t))
	var centre := Vector2.ZERO
	var box := Rect2()
	for p in cells:
		box = cell_rect(p) if box.size == Vector2.ZERO else box.merge(cell_rect(p))
		var r := cell_rect(p, S)
		r.position += off
		var fa := 0.5 if pending else 1.0
		var body_there := battle.grid.unit_at(p) != null
		tl.draw_rect(r, Color(col, (0.16 + 0.12 * pulse) * fa * (0.35 if body_there else 1.0)))
		_corners(tl, r, Color(col, (0.75 + 0.25 * pulse) * fa), (3 if pending else 4) * S)
		centre += r.get_center()
	if cells.is_empty():
		return
	centre /= cells.size()
	var a: Actor = battle._actor(t["actor_uid"])
	if a == null or not battle.grid.units.has(a):
		return
	var from := feet(_pos_of(a)) + off - Vector2(0, 8 * S)
	var leap: bool = battle.catalog.actors.get(a.def_id, {}).get("leap", false)
	var txt := Battle.fmt_secs(maxf(left, 0.0))
	var d := centre - from
	if d.length() < C * 0.5:
		# a blow around itself: the number rides above its head too
		var ast0 := Art.unit(Art.unit_id(a))
		_badge(tl, feet(_pos_of(a)) + off - Vector2(0, (float(ast0.get("ay", 22)) + 10) * S), txt, col, hot, pulse)
		return
	var start := from + d.normalized() * C * 0.3
	var h := (d.length() * 0.3 + C * 0.3) if leap else 0.0
	var stop := centre - d.normalized() * C * 0.42   # the head stops at the cell's edge: it never sits on the body
	_arrow(tl, start, stop, col, h, hot, pulse)
	# the seconds ride above the attacker's head, where the arrow starts
	var ast := Art.unit(Art.unit_id(a))
	_badge(tl, feet(_pos_of(a)) + off - Vector2(0, (float(ast.get("ay", 22)) + 10) * S), txt, col, hot, pulse)

var _badge_spots: Array = []   # where this frame's countdown badges went, so two never sit on each other

func _badge(tl: Control, at: Vector2, txt: String, col: Color, hot: bool, pulse: float) -> void:
	var r := 4.5 * S * (1.0 + (0.12 * pulse if hot else 0.0))
	at.y -= 4 * S
	for k in 6:
		var clash := false
		for q in _badge_spots:
			if at.distance_to(q) < 13.0 * S:
				clash = true
				break
		if not clash:
			break
		at.x += 13.0 * S
	_badge_spots.append(at)
	tl.draw_circle(at, r + S, Art.INK)
	tl.draw_circle(at, r, col)
	tl.draw_string(font, at + Vector2(-4 if txt.length() == 1 else -8, 5), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Art.INK)

## Point on a straight or arched (leaping) path from a to b at k.
func _arc_pt(a: Vector2, b: Vector2, h: float, k: float) -> Vector2:
	return a.lerp(b, k) - Vector2(0, 4.0 * h * k * (1.0 - k))

## An attack arrow: a straight shaft, or an arch for leaps, with a head at the target.
## Returns where its number goes (beside the middle of the shaft).
func _arrow(tl: Control, a: Vector2, b: Vector2, col: Color, h: float, hot: bool, pulse: float) -> Vector2:
	var pts := PackedVector2Array()
	var n := 18
	for i in n + 1:
		pts.append(_arc_pt(a, b, h, float(i) / n))
	var end := pts[n - 1]
	var tip := pts[n]
	var dir := (tip - end).normalized()
	var nrm := Vector2(-dir.y, dir.x)
	var body := pts.slice(0, n)
	body.append(tip - dir * 4 * S)
	var a_col := Color(col, 0.75 + 0.25 * pulse) if hot else Color(col, 0.85)
	tl.draw_polyline(body, Art.INK, 4 * S)
	tl.draw_polyline(body, a_col, 2 * S)
	var head := PackedVector2Array([tip + dir * S, tip - dir * 6 * S + nrm * 4 * S, tip - dir * 6 * S - nrm * 4 * S])
	tl.draw_colored_polygon(PackedVector2Array([head[0] + dir * S, head[1] + (nrm - dir) * S, head[2] - (nrm + dir) * S]), Art.INK)
	tl.draw_colored_polygon(head, a_col)
	var mid := _arc_pt(a, b, h, 0.5)
	var side := (b - a).normalized()
	var off_n := Vector2(-side.y, side.x)
	if off_n.y > 0:
		off_n = -off_n
	return mid + off_n * 9 * S

## Where a body is going: a dashed arrow and the landing cell. secs < 0 hides the count.
func _move_arrow(tl: Control, from_c: Vector2, to: Vector2i, off: Vector2, mine: bool, secs: float) -> void:
	var col := Color("#9fe8b0") if mine else Color("#e8e0d0")
	var a := cell_rect(Vector2i(0, 0)).get_center() + from_c * C + off
	var b := cell_rect(to).get_center() + off
	if a.distance_to(b) < 2.0:
		return
	var dr := cell_rect(to, 3 * S)
	dr.position += off
	var dash := 3 * S
	var per := dr.size.x
	for i in int(per / (dash * 2)):
		for e in [[dr.position + Vector2(i * dash * 2, 0), Vector2(1, 0)], [dr.position + Vector2(i * dash * 2, dr.size.y), Vector2(1, 0)],
				[dr.position + Vector2(0, i * dash * 2), Vector2(0, 1)], [dr.position + Vector2(dr.size.x, i * dash * 2), Vector2(0, 1)]]:
			tl.draw_line(e[0], e[0] + e[1] * dash, Color(col, 0.8), S)
	var dir := (b - a).normalized()
	var s0 := a + dir * C * 0.28
	var s1 := b - dir * C * 0.22
	tl.draw_line(s0, s1, Art.INK, 3 * S)
	tl.draw_line(s0, s1, Color(col, 0.85), S)
	var nrm := Vector2(-dir.y, dir.x)
	tl.draw_colored_polygon(PackedVector2Array([s1 + dir * 3 * S, s1 - dir * 2 * S + nrm * 3 * S, s1 - dir * 2 * S - nrm * 3 * S]), Color(col, 0.9))
	if secs > 0.0:
		var lp := (s0 + s1) / 2 + Vector2(0, -6 * S)
		tl.draw_string_outline(font, lp - Vector2(4, -5), Battle.fmt_secs(secs), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, 5, Art.INK)
		tl.draw_string(font, lp - Vector2(4, -5), Battle.fmt_secs(secs), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, col)

## The player's card while it is being performed: its cells fill up and a ring over the head runs out.
func _casts(tl: Control, off: Vector2) -> void:
	if not replaying:
		casts.clear()
		return
	var t := sim_time()
	for c in casts:
		if t < float(c["t0"]) or t >= float(c["t1"]):
			continue
		var k := (t - float(c["t0"])) / maxf(0.05, float(c["t1"] - c["t0"]))
		for p in c["cells"]:
			var r := cell_rect(p, S)
			r.position += off
			tl.draw_rect(r, Color(Art.GOLD, 0.10 + 0.25 * k))
			_corners(tl, r, Color(Art.GOLD, 0.9), (3 + 3 * k) * S)
		var u: Actor = battle._actor(c["uid"])
		if u == null:
			continue
		var ust := Art.unit(Art.unit_id(u))
		var head := feet(_pos_of(u)) + off - Vector2(0, (float(ust.get("ay", 22)) + 9) * S)
		tl.draw_circle(head, 6 * S, Color(Art.INK, 0.8))
		tl.draw_arc(head, 5 * S, -PI / 2, -PI / 2 + TAU * k, 24, Art.GOLD, 2 * S)
		var left := Battle.fmt_secs(float(c["t1"]) - t)
		tl.draw_string(font, head + Vector2(-4 * left.length(), 6), left, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color.WHITE)

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

## How many seconds the action being planned takes (picked card or dragged walk).
func _ahead() -> int:
	if not walk_path.is_empty():
		return walk_path.size()
	return forecast

## Where the hero will stand `secs` seconds from now in the planned action.
func _hero_at(secs: int) -> Vector2i:
	var h := battle.human()
	if h == null:
		return Vector2i(-1, -1)
	if not walk_path.is_empty():
		return walk_path[clampi(secs - 1, 0, walk_path.size() - 1)]
	return h.pos

func _blow_damage(t: Dictionary) -> int:
	var dmg := 0
	for part in Effects.card_def(t["card_id"], battle.catalog).get("parts", []):
		if part.get("op", "") == "damage":
			dmg += int(part.get("amount", 0)) * maxi(1, int(part.get("hits", 1)))
	return dmg

func _danger_mark(tl: Control, c: Vector2, dmg: int) -> void:
	var k := 0.5 + 0.5 * sin(real * 10.0)
	# beside the head (upper left of the cell), small: the body itself stays in view
	var at := c + Vector2(-C * 0.55, -C * 0.75)
	tl.draw_circle(at, (5 + 0.5 * k) * S, Art.INK)
	tl.draw_circle(at, (4 + 0.5 * k) * S, Art.DANGER)
	tl.draw_rect(Rect2(at + Vector2(-S * 0.5, -3 * S), Vector2(S, 3.5 * S)), Color.WHITE)
	tl.draw_rect(Rect2(at + Vector2(-S * 0.5, 1.5 * S), Vector2(S, S)), Color.WHITE)
	if dmg > 0:
		var tx := "-%d" % dmg
		var tp := at + Vector2(-6 * S - 9 * tx.length(), 5)
		tl.draw_string_outline(font, tp, tx, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, 5, Art.INK)
		tl.draw_string(font, tp, tx, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Art.DANGER)

## A walk: the route cell by cell, the seconds it takes at its end, red where a blow lands on the way.
func _walk(tl: Control, path: Array, off: Vector2, faint: bool) -> void:
	var h := battle.human()
	if h == null or path.is_empty():
		return
	var pts := PackedVector2Array([cell_rect(h.pos).get_center() + off])
	for q in path:
		pts.append(cell_rect(q).get_center() + off)
	var col := Color("#9fe8b0", 0.45 if faint else 0.95)
	var step := maxi(1, int(round(battle.world_rate() * Battle.TPS)))
	for i in path.size():
		var arrive := battle.tick + (i + 1) * step
		var bad := false
		for t in battle.telegraphs:
			# a blow as the hero steps in catches it there; one while still on the way, on the cell before
			var fa := int(t["fire_at"])
			if (fa == arrive and t["cells"].has(path[i])) or (fa > arrive - step and fa < arrive and t["cells"].has(path[i - 1] if i > 0 else h.pos)):
				bad = true
		var seg_col := Color(Art.DANGER, col.a) if bad else col
		tl.draw_line(pts[i], pts[i + 1], Color(Art.INK, col.a), 5 * S)
		tl.draw_line(pts[i], pts[i + 1], seg_col, 2 * S)
		var r := cell_rect(path[i], 4 * S)
		r.position += off
		tl.draw_rect(r, Color(seg_col, 0.10 if faint else 0.18))
		if bad and not faint:
			tl.draw_line(r.position, r.end, Art.DANGER, 2 * S)
			tl.draw_line(Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y), Art.DANGER, 2 * S)
	var end := pts[pts.size() - 1]
	var dir := (end - pts[pts.size() - 2]).normalized()
	var nrm := Vector2(-dir.y, dir.x)
	tl.draw_colored_polygon(PackedVector2Array([end + dir * 5 * S, end - dir * 3 * S + nrm * 5 * S, end - dir * 3 * S - nrm * 5 * S]), col)
	var tx := "%d초" % path.size()
	var tp := end + Vector2(6 * S, -6 * S)
	tl.draw_string_outline(font, tp, tx, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 6, Color(Art.INK, col.a))
	tl.draw_string(font, tp, tx, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1, col.a))

## Aiming: the hovered cell, and when it is out of reach a line that falls short and fizzles.
func _aim(tl: Control, off: Vector2) -> void:
	var h := battle.human()
	if not fizzle.is_empty() and real - float(fizzle["t0"]) < 0.6:
		var k := (real - float(fizzle["t0"])) / 0.6
		var fr := cell_rect(fizzle["cell"], S + k * 4 * S)
		fr.position += off
		tl.draw_line(fr.position, fr.end, Color(Art.DANGER, 1.0 - k), 2 * S)
		tl.draw_line(Vector2(fr.end.x, fr.position.y), Vector2(fr.position.x, fr.end.y), Color(Art.DANGER, 1.0 - k), 2 * S)
	if hover.x < 0 or h == null or replaying or self_aim:
		return
	var hr := cell_rect(hover)
	hr.position += off
	if not aiming:
		_corners(tl, hr.grow(-S), Color(1, 1, 1, 0.55), 3 * S)
		return
	var from := feet(_pos_of(h)) + off - Vector2(0, 8 * S)
	var to := hr.get_center()
	var arch := from.distance_to(to) * 0.16
	if hover in range_cells or range_cells.is_empty():
		_corners(tl, hr.grow(-S), Color(Art.GOLD, 0.95), 4 * S)
		if hover != h.pos:
			_dotted_arc(tl, from, to, arch, 1.0, Color(Art.GOLD, 0.95))
		return
	# out of reach: the arc flies as far as the reach allows, then drops short of the cell
	var reach_k := 0.0
	for i in range(1, 41):
		var k := float(i) / 40.0
		var cq := cell_at(from.lerp(to, k) - off)
		if cq.x >= 0 and (cq in range_cells or cq == h.pos):
			reach_k = k
	_dotted_arc(tl, from, to, arch, reach_k, Color(Art.GOLD, 0.95))
	# the rest of the way stays on the same arc, faint and red, broken where reach runs out
	var last := _arc_pt(from, to, arch, reach_k)
	var n2 := int(from.distance_to(to) / (5 * S)) + 2
	for i in n2:
		var k := float(i) / n2
		if k <= reach_k + 0.04:
			continue
		var q := _arc_pt(from, to, arch, k)
		tl.draw_rect(Rect2(q.snapped(Vector2(S, S)) - Vector2(S, S), Vector2(2 * S, 2 * S)), Color(Art.DANGER, 0.45))
	tl.draw_line(last + Vector2(-3, -3) * S, last + Vector2(3, 3) * S, Art.INK, 3 * S)
	tl.draw_line(last + Vector2(3, -3) * S, last + Vector2(-3, 3) * S, Art.INK, 3 * S)
	tl.draw_line(last + Vector2(-3, -3) * S, last + Vector2(3, 3) * S, Art.DANGER, S)
	tl.draw_line(last + Vector2(3, -3) * S, last + Vector2(-3, 3) * S, Art.DANGER, S)
	# the cell itself: a red frame exactly on its edges
	var cr := cell_rect(hover, S)
	cr.position += off
	tl.draw_rect(cr, Color(Art.DANGER, 0.10))
	tl.draw_rect(cr, Color(Art.DANGER, 0.8), false, S)

func _dotted_arc(tl: Control, a: Vector2, b: Vector2, h: float, upto: float, col: Color) -> void:
	var n := int(a.distance_to(b) / (5 * S)) + 2
	var run := fmod(real * 0.6, 1.0)
	for i in n:
		var k := (float(i) + run) / n
		if k > upto:
			break
		var q := _arc_pt(a, b, h, k)
		tl.draw_rect(Rect2(q.snapped(Vector2(S, S)) - Vector2(1.5 * S, 1.5 * S), Vector2(3 * S, 3 * S)), Art.INK)
		tl.draw_rect(Rect2(q.snapped(Vector2(S, S)) - Vector2(S, S), Vector2(2 * S, 2 * S)), col)


## Study: the held-time look. Dust and embers hang in the air and drift continuously (never
## frame-flipped), stretching into streaks when time runs; a ring snaps out from the hero the
## moment time stops.
func _held_look(tl: Control, calm: float) -> void:
	var room := Rect2(origin, Vector2(Grid.W, Grid.H) * C)
	var v := clampf(_speed, 0.0, 3.0)
	for k in 46:
		var h1 := fmod(float(k) * 0.6180339 * 977.0, 1.0)
		var h2 := fmod(float(k) * 0.7548776 * 613.0, 1.0)
		var sp := 6.0 + 10.0 * h2
		var dir := Vector2(0.9, -0.45 + 0.3 * h1).normalized()
		var pos := Vector2(h1 * room.size.x, h2 * room.size.y) + dir * clock * sp * 9.0
		pos = Vector2(fposmod(pos.x, room.size.x), fposmod(pos.y, room.size.y))
		var p0 := room.position + pos
		var ember := k % 3 == 0
		var col := Color(1.0, 0.72, 0.4, 0.75) if ember else Color(0.85, 0.9, 1.0, 0.45)
		var tail := dir * minf(v * sp * 2.2, 40.0)
		if tail.length() > S:
			tl.draw_line(p0 - tail, p0, Color(col, col.a * 0.35), S)
		tl.draw_rect(Rect2(p0.snapped(Vector2(S, S)), Vector2(S, S) * (2 if ember and k % 2 == 0 else 1)), col)
	# afterimages of moving units: they hang where they were when time stops
	for q in trails:
		var a := 1.0 - (real - float(q["t"])) / 0.25
		var u: Actor = null
		for x in battle.actors:
			if x.uid == int(q["uid"]):
				u = x
		if u == null:
			continue
		var st := Art.unit(Art.unit_id(u))
		if st.is_empty():
			continue
		var flip: bool = _faces_left(u) == bool(st["faces_right"])
		var idle := Art.strip("units", Art.unit_id(u) + "_idle.png")
		if not idle.is_empty():
			st = idle
		_sprite(tl, st, feet(q["pos"]), 0, Color(0.55, 0.8, 1.0, 0.18 * a), flip)
	# the snap into held time: a thin ring racing out from the hero, once
	if pulse_t0 >= 0.0:
		var k2 := (rt - pulse_t0) / 0.55
		if k2 < 1.0:
			var h := battle.human()
			if h != null:
				var c := feet(_pos_of(h)) - Vector2(0, 8 * S)
				var r := lerpf(6.0, room.size.x * 0.9, 1.0 - pow(1.0 - k2, 3.0))
				tl.draw_arc(c, r, 0, TAU, 96, Color(0.8, 0.9, 1.0, 0.55 * (1.0 - k2)), 2 * S)
				tl.draw_arc(c, r * 0.94, 0, TAU, 96, Color(0.5, 0.7, 1.0, 0.25 * (1.0 - k2)), S)
