extends Control
## Battle screen: clock track on top, the dungeon room filling the middle, the hand as a ring of
## cards at the bottom. Almost no text: hovering a card or a cell explains its [keywords].
## Keys: left click a cell to walk there, right click for full details (or to cancel
## a picked card), Q W E R T pick a card, 1-5 game speed, arrows move (1 s), mouse wheel or A/D flip
## through the hand, Space wait 1 s.

const SEC_REAL := 0.5    # real seconds one game second takes when replayed
const HUB := Vector2(640, 800)   # hand wheel hub on screen

var catalog: Catalog
var flow: RunFlow
var board: BoardView
var font: Font
var timeline: TimelineBar
var hand_layer: Control
var hud: Control
var tips: VBoxContainer
var overlay: Control
var selected := -1
var seed_value := 0
var shown_frame := 0
var replay_t := 0.0
var flow_from := 0       # first frame of the flow being replayed
var warp := 0.0           # time-warp factor: eases up from bullet time when time starts flowing, back down at the end
var cards: Array = []          # CardView per hand slot (null for empty / heavy tail)
var hovered_card: CardView
var wiggle_until := 0.0
var real := 0.0
var cell_hover_t := 0.0
var dragging := false     # left button held on the board with no card: drawing a walk
var drag_manual := false  # started on the hero: the path follows the mouse cell by cell
var drag_from := Vector2i(-1, -1)
var drag_px := Vector2.ZERO   # where the button went down: dragging right of it confirms, left cancels
const DRAG_GO := 24.0
var focus_at := -9.0
var speed := 1.0             # playback speed of passing seconds (1-5 keys)
var speed_shown_at := -9.0
var hand_cursor: HandCursor     # when the window got focus: the click that focuses it never walks
var log_i := 0           # battle log entries already shown as flashes
var board_base := Vector2.ZERO  # where the board sits; slides move it off and back
var slide_dir := Vector2i.ZERO  # walking through a door: the camera slides toward the next room
var slide_t := 0.0              # 0..1 out, then 1..2 in
var banner := ""                # room name shown for a moment on entering
var banner_at := -9.0
const SLIDE_OUT := 0.22
const SLIDE_IN := 0.32

func _ready() -> void:
	font = load("res://assets/fonts/Galmuri11.ttf")
	var th := Theme.new()
	th.default_font = font
	th.default_font_size = 14
	theme = th
	catalog = Catalog.load_dir("res://data")
	seed_value = int(Time.get_unix_time_from_system()) % 100000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			seed_value = int(a.substr(7))
	var bg := ColorRect.new()
	bg.color = Color("#0a090d")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	board = BoardView.new()
	board.font = font
	add_child(board)
	board.gui_input.connect(_on_board_input)
	timeline = TimelineBar.new()
	timeline.font = font
	timeline.size = Vector2(560, 40)
	timeline.position = Vector2(360, 0)
	timeline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	timeline.visible = false   # warnings and their seconds now live on the board itself
	add_child(timeline)
	hud = Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.draw.connect(_draw_hud)
	add_child(hud)
	hand_layer = Control.new()
	hand_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	hand_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hand_layer.draw.connect(_draw_wheel)
	add_child(hand_layer)
	hand_cursor = HandCursor.new()
	tips = VBoxContainer.new()
	tips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tips.add_theme_constant_override("separation", 4)
	tips.z_index = 10
	add_child(tips)
	_make_log_panel()
	overlay = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)
	add_child(hand_cursor)
	_new_run()

# ---- temporary damage log (to find where unexplained damage comes from) ------------------------

const LOG_SHOWN := ["play", "telegraph", "telegraph_hit", "damage", "status_damage", "collision", "void", "dislike",
	"like", "split", "death", "unknown", "shatter", "parry", "dodge", "trap", "timer_fire"]
const LOG_LINES := 40
var log_box: RichTextLabel

func _make_log_panel() -> void:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.045, 0.07, 0.82)
	sb.border_color = Color("#3a3548")
	sb.set_border_width_all(1)
	sb.set_content_margin_all(6)
	panel.add_theme_stylebox_override("panel", sb)
	panel.position = Vector2(1054, 168)
	panel.size = Vector2(222, 440)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	log_box = RichTextLabel.new()
	log_box.bbcode_enabled = true
	log_box.scroll_following = true
	log_box.fit_content = false
	log_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	log_box.add_theme_font_size_override("normal_font_size", 11)
	log_box.add_theme_constant_override("line_separation", 2)
	panel.add_child(log_box)
	add_child(panel)

func _log_line(e: Dictionary) -> void:
	if log_box == null or not e["t"] in LOG_SHOWN:
		return
	var col := "#b8b2c8"
	var me := flow.battle.human()
	var uid := int(e.get("data", {}).get("uid", -1))
	match e["t"]:
		"unknown": col = "#ff6af0"
		"damage", "status_damage", "collision", "void", "dislike":
			col = "#ff8a7a" if me != null and uid == me.uid else "#ffd27a"
		"like", "split": col = "#9cf08a"
		"play": col = "#9cc8f0"
		"telegraph", "telegraph_hit": col = "#d9a35a"
		"death": col = "#8a8498"
	var msg := str(e.get("msg", "")).replace("[", "(").replace("]", ")")
	log_box.append_text("[color=#5a5468]%d초[/color] [color=%s]%s[/color]\n" % [int(e.get("at", 0)), col, msg])
	if log_box.get_paragraph_count() > LOG_LINES + 10:
		log_box.remove_paragraph(0)

func _new_run() -> void:
	flow = RunFlow.new(catalog, seed_value)
	shown_frame = flow.battle.frames.size() - 1
	log_i = flow.battle.log.size()
	board.reset_tracking()
	_refresh()

func _replaying() -> bool:
	return flow != null and flow.battle != null and shown_frame < flow.battle.frames.size() - 1

## Plays passed seconds back: units glide from one second's position to the next.
func _step_replay(delta: float) -> void:
	var fr: Array = flow.battle.frames
	if shown_frame >= fr.size() - 1:
		if board.replaying:
			board.replaying = false
			_refresh()
		return
	if not board.replaying:
		warp = BoardView.HELD
		flow_from = shown_frame
	board.replaying = true
	# ramp out of bullet time, and settle back into it over the last moments of the flow
	var left := float(fr.size() - 1 - shown_frame) - replay_t
	var tail := lerpf(0.3, 1.0, clampf(left / 0.6, 0.0, 1.0))
	if BoardView.BT2:
		# study: a longer, eased brake into held time, so the last moment visibly slows to a crawl
		var q := clampf(left / 0.9, 0.0, 1.0)
		tail = lerpf(0.12, 1.0, q * q * (3.0 - 2.0 * q))
	warp = move_toward(warp, tail, delta * 4.0) if warp < tail else tail
	if flow.calm() or fast_flow:
		warp = 1.0   # nothing to fight, or only the ring turning: no slow motion
	var calm_k := 3.0 if (flow.calm() or fast_flow) else 1.0
	board.play_speed = speed * warp
	replay_t += delta * speed * warp * calm_k / SEC_REAL
	while replay_t >= 1.0 and shown_frame < fr.size() - 1:
		replay_t -= 1.0
		shown_frame += 1
	if shown_frame >= fr.size() - 1:
		replay_t = 0.0
		fast_flow = false
		board.replaying = false
		flow.update()
		_refresh()
		return
	var a: Dictionary = fr[shown_frame]
	var b: Dictionary = fr[shown_frame + 1]
	var k := clampf(replay_t, 0.0, 1.0)
	var prev: Dictionary = fr[shown_frame - 1] if shown_frame > flow_from else {}
	var next: Dictionary = fr[shown_frame + 2] if shown_frame + 2 < fr.size() else {}
	board.shown_pos = {}
	board.moving = {}
	board.replay_k = k
	for uid in a["pos"]:
		var p0 := Vector2(a["pos"][uid])
		var p1 := Vector2(b["pos"].get(uid, a["pos"][uid]))
		# a walk over several seconds glides at a steady pace: ease only where it starts and stops
		var went: bool = prev.has("pos") and Vector2(prev["pos"].get(uid, a["pos"][uid])) != p0
		var goes: bool = next.has("pos") and Vector2(next["pos"].get(uid, b["pos"].get(uid, a["pos"][uid]))) != p1
		var e := k
		if went and not goes:
			e = 1.0 - (1.0 - k) * (1.0 - k)
		elif goes and not went:
			e = k * k
		elif not went and not goes:
			e = k * k * (3.0 - 2.0 * k)
		board.shown_pos[uid] = p0.lerp(p1, e)
		if p1 != p0:
			board.moving[uid] = Vector2i(p1)
	board.shown_hp = a["hp"] if k < 0.5 else b["hp"]
	board.shown_now = int(a["t"])

const FLASH := {"fire": Color("#ff8a3a"), "ice": Color("#bfe8ff"), "water": Color("#5aa8ff"), "electric": Color("#ffe14a")}

## Shows log events (cards landing, enemy blows) as flashes when the replay reaches their second.
func _flashes() -> void:
	var b := flow.battle
	if log_i > b.log.size():
		log_i = b.log.size()
	var t_now: int = board.shown_now if board.replaying else b.now
	while log_i < b.log.size():
		var e: Dictionary = b.log[log_i]
		if int(e.get("at", 0)) > t_now:
			break
		log_i += 1
		_log_line(e)
		match e["t"]:
			"play":
				var kind_by_card := {"roll": "roll", "guard": "guard", "parry": "guard"}
				var cid: String = str(e["data"].get("card", ""))
				if kind_by_card.has(cid) and e["data"].has("uid"):
					board.acts[int(e["data"]["uid"])] = {"kind": kind_by_card[cid], "t0": int(e["at"]),
						"t1": int(e["at"]) + maxi(1, int(e["data"].get("secs", 1)))}
				if int(e["data"].get("secs", 0)) >= 2:
					board.casts.append({"uid": int(e["data"].get("uid", -1)), "cells": e["data"].get("cells", []),
						"t0": int(e["at"]), "t1": int(e["at"]) + int(e["data"]["secs"])})
			"land":
				var c := Effects.card_def(e["data"].get("card", ""), catalog)
				var col := Color("#fff4c8")
				for part in c.get("parts", []):
					if part.get("op", "") == "material" and FLASH.has(part.get("id", "")):
						col = FLASH[part["id"]]
					if part.get("kind", "") == "electric":
						col = FLASH["electric"]
				var from := Vector2i(-1, -1)
				var is_beam: bool = c.get("parts", []).any(func(pt): return pt.get("op", "") == "beam")
				if c.get("target", {}).get("shape", "") == "line" and not is_beam:
					var u := b._actor(int(e["data"].get("user", -1)))
					if u:
						from = u.pos
				board.burst([] if is_beam else e["data"].get("cells", []), col, from)
				if c.get("parts", []).any(func(pt): return pt.get("op", "") == "damage"):
					board.attack(int(e["data"].get("user", -1)), e["data"].get("cells", []))
			"trap", "interrupt", "delay_actor", "clone", "vanish":
				board.burst(e["data"].get("cells", []), Color("#c0a0ff") if e["t"] in ["clone", "vanish", "delay_actor"] else Color("#ffcf6a"))
			"parry":
				board.burst(e["data"].get("cells", []), Color("#ffe27a"))
				board.shake(0.3)
			"dodge":
				board.burst(e["data"].get("cells", []), Color("#9fe8ff"))
			"dislike":
				board.burst(e["data"].get("cells", []), Color("#d8ecff"))
			"like":
				board.burst(e["data"].get("cells", []), Color("#9cf08a"))
			"split":
				board.burst(e["data"].get("cells", []), Color("#8fe07a"))
				board.shake(0.15)
			"backstab":
				board.burst(e["data"].get("cells", []), Color("#ff5a7a"))
			"timer_fire":
				board.burst(e["data"].get("cells", []), Color("#ff8a3a"))
				board.shake(0.25)
			"shatter":
				board.shatter(e["data"]["cell"])
				board.shake(0.12)
			"beam":
				board.beam(e["data"].get("from", Vector2i(-1, -1)), e["data"].get("path", []), e["data"].get("bends", []), e["data"].get("kind", "energy"))
			"telegraph_hit":
				board.burst(e["data"].get("cells", []), Art.DANGER)
				board.attack(int(e["data"].get("user", -1)), e["data"].get("cells", []))
				board.shake(0.18)

func _process(delta: float) -> void:
	real += delta
	if flow == null or flow.battle == null:
		return
	board.play_speed = speed
	_step_replay(delta)
	_step_slide(delta)
	_flashes()
	_step_ring(delta)
	_layout_hand()
	if _replaying() and tips.visible and hovered_card == null:
		_clear_tips()   # bodies are still on their way: no stale facts under the mouse
	if flow.phase != "battle" and board.hover.x >= 0:
		board.hover = Vector2i(-1, -1)   # a shop, reward or end screen covers the board: nothing under it answers the mouse
		cell_hover_t = 0.0
	if board.hover.x >= 0 and selected < 0 and hovered_card == null and not _replaying() and not dragging:
		cell_hover_t += delta
		if cell_hover_t > 0.25 and tips.get_child_count() == 0:
			_cell_tips(board.hover)
	hud.queue_redraw()

# ---- rooms --------------------------------------------------------------------------------------

## Walking through a door: the view slides toward the next room, the room changes, and the
## new room slides in from the side the player came from.
func _step_slide(delta: float) -> void:
	if slide_dir == Vector2i.ZERO:
		if flow.phase == "battle" and flow.exit_dir != Vector2i.ZERO and not _replaying():
			slide_dir = flow.exit_dir
			slide_t = 0.0
			selected = -1
			_clear_tips()
		else:
			return
	var before := slide_t
	slide_t += delta / (SLIDE_OUT if slide_t < 1.0 else SLIDE_IN)
	if before < 1.0 and slide_t >= 1.0:
		flow.go(slide_dir)
		shown_frame = flow.battle.frames.size() - 1
		log_i = flow.battle.log.size()
		board.reset_tracking()
		var r := flow.room()
		banner = RunFlow.KIND_NAME.get(r["kind"], "")
		if banner == "":
			banner = RunFlow.THEME_NAME.get(r["theme"], "")
		banner_at = real
		_refresh()
	if slide_t >= 2.0:
		slide_dir = Vector2i.ZERO
		slide_t = 0.0
	board.position = board_base + _slide_off()

func _slide_off() -> Vector2:
	if slide_dir == Vector2i.ZERO:
		return Vector2.ZERO
	var span := Vector2(board.size.x, board.size.y) * 0.6
	var d := Vector2(slide_dir)
	if slide_t < 1.0:
		var k := slide_t * slide_t
		return -d * span * k
	var k2 := 1.0 - (slide_t - 1.0)
	return d * span * k2 * k2

## Tools and tests: jump straight into the first room of a kind, as if walked in.
func debug_enter(kind: String) -> void:
	for p in flow.dungeon.rooms:
		if flow.dungeon.rooms[p]["kind"] == kind:
			flow.at = p
			flow._enter(-flow.dungeon.doors(p)[0])
			break
	shown_frame = flow.battle.frames.size() - 1
	log_i = flow.battle.log.size()
	board.reset_tracking()
	_refresh()

func _sliding() -> bool:
	return slide_dir != Vector2i.ZERO

# ---- layout -------------------------------------------------------------------------------------

func _refresh() -> void:
	for ch in overlay.get_children():
		ch.queue_free()
	var b := flow.battle
	board.battle = b
	board.fit()
	board_base = Vector2(round((1280 - board.size.x) / 2), 44)
	board.position = board_base + _slide_off()
	board.preview = {}
	board.aiming = selected >= 0
	timeline.battle = b
	if b.human() != null:
		hand_cursor.set_actor(b.human().def_id)
	_update_span()
	_build_hand()
	hand_layer.visible = flow.phase == "battle"
	if flow.phase == "reward":
		_reward_overlay()
	elif flow.phase == "shop":
		_shop_overlay()
	elif flow.phase in ["game_over", "victory"]:
		_end_overlay()

func _build_hand() -> void:
	for ch in hand_layer.get_children():
		ch.queue_free()
	cards = []
	ring_views = []
	hovered_card = null
	_clear_tips()
	var b := flow.battle
	if b.belt == null:
		return
	_sync_ring()
	cards.resize(b.belt.slots.size())
	cards.fill(null)
	var slot_of := []
	for i in b.belt.slots.size():
		var s = b.belt.slots[i]
		if s != null and not s.get("tail", false):
			slot_of.append(i)
	for k in ring_tokens.size():
		var cv := CardView.new()
		cv.setup(ring_tokens[k]["id"], catalog, font)
		if k < slot_of.size():
			cv.set_meta("slot", slot_of[k])
			cv.picked.connect(_on_card_picked)
			cv.hovered.connect(_on_card_hover)
			cv.inspected.connect(func(c):
				_clear_tips()
				_keyword_tips(c.def().get("desc", ""), true)
				tips.position = Vector2(clampf(c.global_position.x + c.size.x * c.scale.x + 12, 8, 1280 - 250), 300))
			cards[slot_of[k]] = cv
		else:
			cv.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hand_layer.add_child(cv)
		ring_views.append(cv)
	_layout_hand()

## The hand and the deck are one ring of cards standing on an ellipse, seen in 3D. The hand is
## the front of the ring, facing the player; the rest of the deck stands around the back, turned
## away (backs showing). Rolling turns the whole ring; a used card goes round to the back and the
## next one comes round to the front. Every card glides to its new place, nothing jumps.
const RING_C := Vector2(640, 694)
const RING_R := Vector2(420, 34)
const HAND_STEP := 0.29          # radians between two hand cards
var ring_tokens: Array = []      # ring order: {id, q (shown place, unwrapped), t (target place)}
var ring_views: Array = []       # CardView per token
var hand_n := 5.0                # eases to the number of cards in the hand
var snap_index := -1             # old ring place of a card that just flew off to be played

## Matches the new ring to the cards already shown, so each card glides from where it was.
func _sync_ring() -> void:
	var ids: Array = flow.battle.belt.ring()
	var n := ids.size()
	var old := ring_tokens
	var on := maxi(1, old.size())
	var match_of := {}   # new index -> old token index
	var taken := {}
	# the card just played went to the back of the ring: it is already there
	if snap_index >= 0 and n > 0:
		for j in old.size():
			if posmod(int(round(float(old[j]["t"]))), on) == snap_index and old[j]["id"] == ids[n - 1]:
				match_of[n - 1] = j
				taken[j] = true
				break
	# Copies of the same card (four 베기) are matched as a group, keeping their order round the
	# ring: matching each new place to its nearest old copy one by one let two copies swap, and
	# a card then cut across the front instead of turning one step with the rest.
	var groups := {}
	for i in n:
		if not match_of.has(i):
			groups.get_or_add(ids[i], {"new": [], "old": []})["new"].append(i)
	for j in old.size():
		if not taken.has(j) and groups.has(old[j]["id"]):
			groups[old[j]["id"]]["old"].append(j)
	for id in groups:
		var nw: Array = groups[id]["new"]
		var ol: Array = groups[id]["old"]
		ol.sort_custom(func(x, y): return posmod(int(round(float(old[x]["t"]))), on) < posmod(int(round(float(old[y]["t"]))), on))
		var m := mini(nw.size(), ol.size())
		if m == 0:
			continue
		# try every rotation of the old copies against the new places; keep the one that moves least
		var best_r := 0
		var best_k := 0
		var best_cost := 1e18
		for k in range(0, nw.size() - m + 1):
			for r in ol.size():
				var cost := 0.0
				for i in m:
					var io := posmod(int(round(float(old[ol[(i + r) % ol.size()]]["t"]))), on)
					var d := absf(_wrap(float(nw[k + i] - io), n))
					cost += d * d
				if cost < best_cost - 0.001:
					best_cost = cost
					best_r = r
					best_k = k
		for i in m:
			match_of[nw[best_k + i]] = ol[(i + best_r) % ol.size()]
	var out := []
	for i in n:
		if not match_of.has(i):
			out.append({"id": ids[i], "q": float(i), "t": float(i)})
			continue
		var tk: Dictionary = old[match_of[i]]
		var io2 := posmod(int(round(float(tk["t"]))), on)
		var nt := float(tk["t"]) + _wrap(float(i - io2), n)
		var q := float(tk["q"])
		if io2 == snap_index:
			q = nt   # it flew to the board; it is already back on the ring
		out.append({"id": ids[i], "q": q, "t": nt, "moved": nt - float(tk["t"])})
	ring_tokens = out
	snap_index = -1

static func _wrap(d: float, n: int) -> float:
	if n <= 0:
		return d
	var h := n / 2.0
	while d > h:
		d -= n
	while d <= -h:
		d += n
	return d

## Angle on the ring for place q (0 = the hand's left card). The hand spreads evenly over the
## front; the rest of the deck shares the back.
func _ring_phi(q: float, n: int) -> float:
	var h := clampf(hand_n, 1.0, float(maxi(1, n)))
	var c := (h - 1.0) / 2.0
	var a0 := PI / 2 + c * HAND_STEP              # hand's left card
	var a1 := PI / 2 - c * HAND_STEP              # hand's right card
	var qm := fposmod(q, float(maxi(1, n)))
	if qm <= h - 1.0:
		return a0 - qm * HAND_STEP
	var back := float(n) - (h - 1.0)               # steps from the hand's right card round to its left
	var k := (qm - (h - 1.0)) / maxf(0.001, back)
	return a1 - k * (2.0 * PI - (a0 - a1))

func _ring_at(phi: float) -> Vector2:
	return RING_C + Vector2(cos(phi) * RING_R.x, sin(phi) * RING_R.y)

func _step_ring(delta: float) -> void:
	var h := 0
	if flow.battle.belt != null:
		h = flow.battle.belt._entries().size()
	hand_n = move_toward(hand_n, float(h), delta * 4.0)
	var k := minf(1.0, delta * 9.0)
	for tk in ring_tokens:
		tk["q"] = float(tk["q"]) + (float(tk["t"]) - float(tk["q"])) * k

func _draw_wheel() -> void:
	if flow == null or flow.phase != "battle" or flow.battle.belt == null:
		return
	var n := ring_tokens.size()
	var dim := 0.45 if selected >= 0 else 1.0
	# the backs of cards turned away, far ones first
	var order := range(n)
	order.sort_custom(func(a, b): return sin(_ring_phi(ring_tokens[a]["q"], n)) < sin(_ring_phi(ring_tokens[b]["q"], n)))
	var t := Art.tex("ui/card_back.png")
	for i in order:
		var phi := _ring_phi(ring_tokens[i]["q"], n)
		var depth := sin(phi)
		if depth > 0.02:
			continue
		var p := _ring_at(phi)
		var sc := 0.6 + 0.4 * (depth + 1.0) / 2.0
		var w := maxf(0.06, absf(depth))
		var sz := CardView.SIZE * sc
		var shade := (0.45 + 0.4 * (depth + 1.0) / 2.0) * dim
		hand_layer.draw_set_transform(p, 0.0, Vector2(w, 1.0))
		var rr := Rect2(-sz / 2, sz)
		hand_layer.draw_rect(Rect2(rr.position + Vector2(3, 4), rr.size), Color(0, 0, 0, 0.3 * dim))
		if t != null:
			hand_layer.draw_texture_rect(t, rr, false, Color(shade, shade, shade))
		else:
			hand_layer.draw_rect(rr, Color("#2a4a9a") * Color(shade, shade, shade))
		hand_layer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _layout_hand() -> void:
	if flow.battle.belt == null:
		return
	hand_layer.queue_redraw()
	var aiming := selected >= 0
	var wig := sin(real * 60.0) * 0.03 if real < wiggle_until else 0.0
	var n := ring_tokens.size()
	for i in mini(n, ring_views.size()):
		var cv: CardView = ring_views[i]
		if cv == null:
			continue
		var phi := _ring_phi(ring_tokens[i]["q"], n)
		var depth := sin(phi)
		var in_hand: bool = cv.has_meta("slot")
		cv.visible = depth > 0.02
		if not cv.visible:
			continue
		var p := _ring_at(phi)
		var sc := 0.6 + 0.4 * (depth + 1.0) / 2.0
		var w := maxf(0.06, absf(depth))
		cv.lit = in_hand and int(cv.get_meta("slot")) == selected
		var big := in_hand and cv == hovered_card and not aiming
		var z := 2 if big else 1
		if cv.zoom != z:
			cv.set_zoom(z)
		cv.pivot_offset = cv.size / 2
		if big:
			var x := clampf(p.x - cv.size.x / 2, 8, 1280 - cv.size.x - 8)
			cv.position = Vector2(x, 796 - cv.size.y)
			cv.rotation = 0.0
			cv.scale = Vector2.ONE
		else:
			cv.position = p - cv.size / 2
			cv.rotation = wig if cv.lit else 0.0
			cv.scale = Vector2(sc * w, sc)
			if cv.lit:
				cv.position.y -= 34   # the picked card rises out of the hand
		var alpha := 1.0
		if aiming:
			alpha = 0.62 if cv.lit else 0.24
		var shade := 1.0 if in_hand else 0.55   # deck cards passing the front are not in hand
		cv.modulate = Color(shade, shade, shade, alpha)
		cv.z_index = 40 if (big or cv.lit) else int((depth + 1.0) * 10.0)

# ---- hud ----------------------------------------------------------------------------------------

func _draw_hud() -> void:
	var b := flow.battle
	_draw_map(Vector2(1068, 62))
	# room name for a moment after walking in
	if banner != "" and real - banner_at < 1.6:
		var ba := clampf(1.6 - (real - banner_at), 0.0, 1.0)
		hud.draw_string_outline(font, Vector2(0, 104), banner, HORIZONTAL_ALIGNMENT_CENTER, 1280, 28, 8, Color(Art.INK, ba))
		hud.draw_string(font, Vector2(0, 104), banner, HORIZONTAL_ALIGNMENT_CENTER, 1280, 28, Color(Art.GOLD, ba))
	# the hero's health, always readable in the corner (bars on the board carry no numbers)
	var me := b.human()
	if me != null:
		var hp_at := Vector2(16, 40)
		hud.draw_rect(Rect2(hp_at, Vector2(120, 14)), Art.INK)
		hud.draw_rect(Rect2(hp_at + Vector2(2, 2), Vector2(116, 10)), Color("#3a1418"))
		hud.draw_rect(Rect2(hp_at + Vector2(2, 2), Vector2(116 * clampf(float(me.hp) / me.max_hp, 0, 1), 10)), Color("#58c46a"))
		var ht := "%d / %d" % [me.hp, me.max_hp] + ("  +%d" % me.shield if me.shield > 0 else "")
		hud.draw_string_outline(font, hp_at + Vector2(128, 13), ht, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 5, Art.INK)
		hud.draw_string(font, hp_at + Vector2(128, 13), ht, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
	# gold: a coin and the count under the health
	var gc := Vector2(24, 72)
	hud.draw_circle(gc, 8, Art.INK)
	hud.draw_circle(gc, 6, Color("#e0b040"))
	hud.draw_circle(gc + Vector2(-1, -1), 3, Color("#ffe48a"))
	hud.draw_string_outline(font, gc + Vector2(14, 6), "%d" % flow.gold, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 5, Art.INK)
	hud.draw_string(font, gc + Vector2(14, 6), "%d" % flow.gold, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Art.GOLD)
	# hand refill: a small ring on the deck icon counts the seconds to the next card
	var dr := b.next_draw_at() - b.now
	var dk := Vector2(1214, 20)
	if dr >= 1:
		hud.draw_arc(dk, 17, -PI / 2, -PI / 2 + TAU * (1.0 - float(dr) / maxf(1.0, float(b.round_time()))), 24, Color("#9cc8f0"), 2)
	# game speed (1-5 keys): shown while it is not normal, and big for a moment after a change
	if speed != 1.0 or real - speed_shown_at < 1.2:
		var big := real - speed_shown_at < 1.2
		var st := "×%s" % (str(int(speed)) if speed == floor(speed) else str(speed))
		var sp := Vector2(1150, 26) if not big else Vector2(600, 90)
		var fs := 16 if not big else 34
		var a := 1.0 if not big else clampf(1.2 - (real - speed_shown_at), 0.0, 1.0)
		hud.draw_string_outline(font, sp, st, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 6, Color(Art.INK, a))
		hud.draw_string(font, sp, st, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(Art.GOLD, a))
	# small icons (top-right): help and deck size
	var hc := Vector2(1252, 20)
	hud.draw_circle(hc, 12, Art.INK)
	hud.draw_circle(hc, 10, Color("#3a3644"))
	hud.draw_string(font, hc + Vector2(-4, 6), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1, 0.8))
	var dc := Vector2(1214, 20)
	hud.draw_rect(Rect2(dc - Vector2(9, 12), Vector2(18, 24)), Art.INK)
	hud.draw_rect(Rect2(dc - Vector2(7, 10), Vector2(14, 20)), Color("#9cc8f0"))
	if b.belt:
		hud.draw_string(font, dc + Vector2(-16, 26), "%d" % b.belt.ring().size(), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.5))
	var h := b.human()
	if h != null and h.discount > 0:
		var p := board.position + board.feet(Vector2(h.pos)) - Vector2(-26, 90)
		hud.draw_string_outline(font, p, "-%d초" % h.discount, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, 5, Art.INK)
		hud.draw_string(font, p, "-%d초" % h.discount, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#bfe8ff"))

## The floor map (top-right): every room is a small card face down until you have been in it;
## rooms next to visited ones show as outlines. Special rooms carry a glyph once seen.
func _draw_map(at: Vector2) -> void:
	var dg := flow.dungeon
	var lo := Vector2i(99, 99)
	var hi := Vector2i(-1, -1)
	for p in dg.rooms:
		if dg.seen(p):
			lo = Vector2i(mini(lo.x, p.x), mini(lo.y, p.y))
			hi = Vector2i(maxi(hi.x, p.x), maxi(hi.y, p.y))
	if hi.x < 0:
		return
	var pitch := Vector2(26, 30)
	var sz := Vector2(18, 24)
	var w := float(hi.x - lo.x + 1) * pitch.x
	var o := at + Vector2(196 - w, 0)
	# corridors first
	for p in dg.rooms:
		if not dg.rooms[p]["visited"]:
			continue
		for d in dg.doors(p):
			var a := o + Vector2(p - lo) * pitch + sz / 2
			hud.draw_line(a, a + Vector2(d) * pitch * 0.5, Color("#5a5468"), 3)
	for p in dg.rooms:
		if not dg.seen(p):
			continue
		var r: Dictionary = dg.rooms[p]
		var rc := Rect2(o + Vector2(p - lo) * pitch, sz)
		var here: bool = p == flow.at
		hud.draw_rect(rc.grow(2), Art.INK)
		if r["visited"]:
			hud.draw_rect(rc, Color("#e8dcc0") if here else Color("#8a8296"))
		else:
			hud.draw_rect(rc, Color("#24203a"))
			hud.draw_rect(rc.grow(-2), Color("#2a4a9a"))
		if here:
			var pulse := 0.6 + 0.4 * sin(real * 4.0)
			hud.draw_rect(rc.grow(3), Color(Art.GOLD, pulse), false, 2)
		var c := rc.get_center()
		var ink := Color("#2a2630") if r["visited"] else Color("#e8dcc0")
		match r["kind"]:
			"boss":
				var crown := PackedVector2Array([c + Vector2(-6, 4), c + Vector2(-6, -4), c + Vector2(-3, 0), c + Vector2(0, -6), c + Vector2(3, 0), c + Vector2(6, -4), c + Vector2(6, 4)])
				hud.draw_colored_polygon(crown, Color("#e04a4a"))
			"shop":
				hud.draw_circle(c, 5, Color("#e0b040"))
				hud.draw_circle(c, 2, ink)
			"chest":
				if not r["used"]:
					hud.draw_rect(Rect2(c - Vector2(5, 3), Vector2(10, 7)), Color("#b07038"))
					hud.draw_rect(Rect2(c - Vector2(5, 1), Vector2(10, 1)), Color("#e0b040"))
			"spring":
				if not r["used"]:
					hud.draw_circle(c + Vector2(0, 2), 4, Color("#4a8ae0"))
					hud.draw_colored_polygon(PackedVector2Array([c + Vector2(-3, 1), c + Vector2(0, -6), c + Vector2(3, 1)]), Color("#4a8ae0"))
			"fight":
				if not r["cleared"] and r["visited"]:
					hud.draw_line(c + Vector2(-4, -4), c + Vector2(4, 4), Color("#c04040"), 2)
					hud.draw_line(c + Vector2(4, -4), c + Vector2(-4, 4), Color("#c04040"), 2)

func _update_span() -> void:
	var b := flow.battle
	board.range_cells = []
	board.self_aim = false
	board.forecast = 0
	timeline.span_secs = 0
	timeline.span_exhaust = 0
	if selected < 0 or b.belt == null or selected >= b.belt.slots.size() or b.belt.slots[selected] == null or b.human() == null:
		return
	var c := Effects.card_def(b.belt.slots[selected]["card_id"], catalog)
	var shape: String = c.get("target", {}).get("shape", "cell")
	if not shape in ["self", "all", "around"]:
		for p in b.grid.all_cells():
			if b.can_play(selected, p):
				board.range_cells.append(p)
	else:
		board.self_aim = true
	var secs := maxi(0, b.action_secs(int(c.get("time", 0)), b.human()))
	if secs > 0:
		secs = maxi(0, secs - b.human().discount)
	timeline.span_secs = secs
	timeline.span_exhaust = int(c.get("exhaust", 0))
	board.forecast = secs

# ---- tips ---------------------------------------------------------------------------------------

func _clear_tips() -> void:
	for ch in tips.get_children():
		ch.queue_free()
	tips.visible = false

func _tip(title: String, text: String, accent: Color) -> void:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#1b1822f0")
	sb.border_color = accent
	sb.set_border_width_all(2)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 8
	pc.add_theme_stylebox_override("panel", sb)
	pc.set_meta("title", title)
	pc.set_meta("raw", text)
	pc.custom_minimum_size = Vector2(230, 0)
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rt.custom_minimum_size = Vector2(210, 0)
	rt.add_theme_font_size_override("normal_font_size", 13)
	rt.text = "[color=#%s]%s[/color]\n%s" % [accent.to_html(false), title, CardView.rich(text).replace("#9a3d12", "#ffcf6a")]
	pc.add_child(rt)
	tips.add_child(pc)
	tips.visible = true

func _keyword_tips(text: String, full := false) -> void:
	var kw: Dictionary = catalog.keywords.get("keywords", {})
	var seen := []
	var queue := CardView.keywords_in(text)
	while not queue.is_empty() and (full or seen.size() < 5):
		var k: String = queue.pop_front()
		if k in seen or not kw.has(k):
			continue
		seen.append(k)
		_tip(k, kw[k], Color("#ffcf6a"))
		if full:
			queue.append_array(CardView.keywords_in(kw[k]))

func _on_card_hover(cv: CardView, on: bool) -> void:
	if on:
		hovered_card = cv
		_clear_tips()
		if selected < 0:
			_keyword_tips(cv.def().get("desc", ""))
			tips.position = Vector2(cv.global_position.x + cv.size.x * cv.scale.x + 12, 420)
			if tips.position.x > 1280 - 250:
				tips.position.x = cv.global_position.x - 250
	elif hovered_card == cv:
		hovered_card = null
		_clear_tips()

func _cell_tips(p: Vector2i, full := false) -> void:
	var b := flow.battle
	var kw: Dictionary = catalog.keywords.get("keywords", {})
	var cellmap: Dictionary = catalog.keywords.get("cell", {})
	var stmap: Dictionary = catalog.keywords.get("status", {})
	var u = b.grid.unit_at(p)
	if u != null:
		var parts := []
		for s in u.statuses.keys():
			if stmap.has(s):
				parts.append("[%s]" % stmap[s])
		_tip(u.name, "체력 %d / %d" % [u.hp, u.max_hp] + ("\n" + " ".join(parts) if not parts.is_empty() else ""),
			Color("#7ee08a") if u.controller == "human" else Color("#ff8a7a"))
		for s in u.statuses.keys():
			if stmap.has(s) and kw.has(stmap[s]):
				_tip(stmap[s], kw[stmap[s]], Color("#ffcf6a"))
		if full:
			_unit_details(u)
	var m := b.grid.get_material(p)
	if cellmap.has(m) and kw.has(cellmap[m]):
		_tip(cellmap[m], kw[cellmap[m]], Color("#9cc8f0"))
	# the cell's states: [열기], [돌풍], [멈춘 시간]...
	var smap: Dictionary = b.catalog.keywords.get("state", {})
	for sid in b.grid.states_at(p):
		var nm: String = smap.get(sid, "")
		if nm != "" and kw.has(nm):
			_tip(nm, kw[nm], Color("#ffe14a") if sid == "charged" else Color("#9cc8f0"))
	if full:
		# keywords named inside those explanations too, one level deep
		var titles := []
		var raws := []
		for ch in tips.get_children():
			titles.append(ch.get_meta("title", ""))
			raws.append(ch.get_meta("raw", ""))
		for r in raws:
			for k in CardView.keywords_in(r):
				if not k in titles and kw.has(k):
					titles.append(k)
					_tip(k, kw[k], Color("#ffcf6a"))
	if tips.get_child_count() > 0:
		var mp := get_viewport().get_mouse_position()
		tips.position = mp + Vector2(18, 10)
		if tips.position.x > 1280 - 250:
			tips.position.x = mp.x - 250
		if tips.position.y > 520:
			tips.position.y = 520

## Right-click on a body: what it will do next and the cards it fights with.
func _unit_details(u: Actor) -> void:
	var b := flow.battle
	if u.controller == "ai":
		var lines := []
		for t in b.telegraphs:
			if int(t["actor_uid"]) == u.uid:
				lines.append("%s: %d초 뒤" % [Effects.card_def(t["card_id"], catalog).get("name", ""), int(t["fire_at"]) - b.now])
		var it := b.ai_intent(u)
		if it.get("kind", "") == "move":
			lines.append("이동: %d초 뒤" % (int(it["at"]) - b.now))
		var seq: Array = u.pattern if not u.pattern.is_empty() else u.deck
		if not seq.is_empty():
			var names := []
			for i in seq.size():
				names.append(Effects.card_def(seq[(u.pattern_index + i) % seq.size()], catalog).get("name", ""))
			lines.append("순서: " + " → ".join(names))
		if not lines.is_empty():
			_tip("다음 행동", "\n".join(lines), Color("#ff8a7a"))
	else:
		var pas := []
		for p in u.passives:
			pas.append(p)
		if "backstab" in pas:
			_tip("급소 찌르기", catalog.keywords.get("keywords", {}).get("급소 찌르기", ""), Color("#7ee08a"))

# ---- overlays -----------------------------------------------------------------------------------

func _veil() -> void:
	var v := ColorRect.new()
	v.color = Color(0.02, 0.02, 0.04, 0.72)
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(v)

func _title(t: String, y: float) -> void:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 30)
	l.add_theme_color_override("font_outline_color", Art.INK)
	l.add_theme_constant_override("outline_size", 8)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.position = Vector2(0, y)
	l.size = Vector2(1280, 40)
	overlay.add_child(l)

func _reward_overlay() -> void:
	_veil()
	_title("보물 상자" if flow.room()["kind"] == "chest" else "방 정리", 200)
	_button("넘기기", Vector2(590, 560), func(): _pick_reward(-1))
	for i in flow.rewards.size():
		var cv := CardView.new()
		cv.setup(flow.rewards[i], catalog, font, 2)
		cv.position = Vector2(640 - 1.5 * 190 + i * 190 - 76 + 95, 270)
		var idx := i
		cv.picked.connect(func(_c): _pick_reward(idx))
		cv.hovered.connect(func(c, on):
			_clear_tips()
			if on:
				_keyword_tips(c.def().get("desc", ""))
				tips.position = Vector2(c.position.x + 164, 280))
		overlay.add_child(cv)

func _button(text: String, at: Vector2, on_press: Callable, enabled := true) -> Button:
	var bt := Button.new()
	bt.text = text
	bt.position = at
	bt.size = Vector2(100, 36)
	bt.disabled = not enabled
	bt.pressed.connect(on_press)
	overlay.add_child(bt)
	return bt

## The shop: cards on the merchant's rug with their prices, a heal, and the way out.
func _shop_overlay() -> void:
	_veil()
	_title("상점   금화 %d" % flow.gold, 150)
	var items := flow.stock()
	for i in items.size():
		var it: Dictionary = items[i]
		var x := 640 - 2 * 190 + i * 190 + 18
		if not it["sold"]:
			var cv := CardView.new()
			cv.setup(it["id"], catalog, font, 2)
			cv.position = Vector2(x, 220)
			var idx := i
			cv.picked.connect(func(_c):
				if flow.buy(idx):
					_refresh())
			cv.hovered.connect(func(c, on):
				_clear_tips()
				if on:
					_keyword_tips(c.def().get("desc", ""))
					tips.position = Vector2(c.position.x + 164, 230))
			if flow.gold < int(it["price"]):
				cv.modulate = Color(0.55, 0.55, 0.6)
			overlay.add_child(cv)
		var pl := Label.new()
		pl.text = "팔림" if it["sold"] else "%d" % it["price"]
		pl.position = Vector2(x, 470)
		pl.size = Vector2(152, 24)
		pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		pl.add_theme_font_size_override("font_size", 20)
		pl.add_theme_color_override("font_color", Art.GOLD if not it["sold"] and flow.gold >= int(it["price"]) else Color(0.6, 0.6, 0.65))
		pl.add_theme_color_override("font_outline_color", Art.INK)
		pl.add_theme_constant_override("outline_size", 6)
		overlay.add_child(pl)
	var me := flow.battle.human()
	_button("회복 +%d (%d)" % [RunFlow.HEAL_AMOUNT, RunFlow.HEAL_PRICE], Vector2(480, 540), func():
		if flow.buy_heal():
			_refresh(), flow.gold >= RunFlow.HEAL_PRICE and me != null and me.hp < me.max_hp).size = Vector2(150, 36)
	_button("나가기", Vector2(660, 540), func():
		flow.leave_shop()
		_refresh())

func _end_overlay() -> void:
	_veil()
	_title("쓰러졌다" if flow.phase == "game_over" else "보스 격파", 300)
	var again := Button.new()
	again.text = "새 판"
	again.position = Vector2(590, 380)
	again.size = Vector2(100, 40)
	again.pressed.connect(func():
		seed_value += 1
		_new_run())
	overlay.add_child(again)

func _pick_reward(i: int) -> void:
	flow.choose_reward(i)
	shown_frame = flow.battle.frames.size() - 1
	log_i = flow.battle.log.size()
	selected = -1
	board.reset_tracking()
	_refresh()

# ---- input --------------------------------------------------------------------------------------

func _on_card_picked(cv: CardView) -> void:
	if flow.phase != "battle" or _replaying() or _sliding():
		return
	var i: int = cv.get_meta("slot")
	var b := flow.battle
	if selected == i:
		# a selected card that needs no aim plays when clicked again
		var shape: String = cv.def().get("target", {}).get("shape", "cell")
		var me := b.human().pos
		if shape in ["self", "all", "around"] and b.cmd_play(i, me):
			_fly(i, me)
			selected = -1
			_after()
			return
		selected = -1
	else:
		selected = i
	_clear_tips()
	_refresh()

## The played card leaves the hand and flies into its target, shrinking away.
func _fly(slot: int, target: Vector2i) -> void:
	var src: CardView = cards[slot] if slot < cards.size() else null
	if src == null:
		return
	snap_index = ring_views.find(src)
	var cv := CardView.new()
	cv.setup(src.card_id, catalog, font, src.zoom)
	cv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cv.position = src.position
	cv.rotation = src.rotation
	cv.scale = src.scale
	cv.pivot_offset = cv.size / 2
	cv.z_index = 20
	add_child(cv)
	var dest := board.position + board.cell_rect(target).get_center() - cv.size / 2
	var tw := create_tween().set_parallel(true)
	tw.tween_property(cv, "position", dest, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(cv, "scale", Vector2(0.25, 0.25), 0.22)
	tw.tween_property(cv, "rotation", 0.0, 0.22)
	tw.tween_property(cv, "modulate", Color(1, 1, 1, 0.0), 0.22).set_delay(0.08)
	tw.chain().tween_callback(cv.queue_free)

func _on_board_input(ev: InputEvent) -> void:
	if flow.phase != "battle" or _replaying() or _sliding():
		return
	var b := flow.battle
	if ev is InputEventMouseMotion:
		var c := board.cell_at(ev.position)
		if c != board.hover:
			board.hover = c
			cell_hover_t = 0.0
			_clear_tips()
			board.preview = b.preview(selected, c) if selected >= 0 and c.x >= 0 else {}
			if dragging and drag_manual and c.x >= 0:
				_drag_to(c)
		if dragging and not drag_manual:
			var dx: float = ev.position.x - drag_px.x
			board.walk_mode = "go" if dx > DRAG_GO else ("cancel" if dx < -DRAG_GO else "hold")
	elif ev is InputEventMouseButton and not ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and dragging:
		_end_drag(board.cell_at(ev.position), ev.position)
	elif ev is InputEventMouseButton and ev.pressed:
		var cell := board.cell_at(ev.position)
		if ev.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			return
		if ev.button_index == MOUSE_BUTTON_RIGHT and dragging:
			dragging = false
			board.walk_path = []
			return
		if ev.button_index == MOUSE_BUTTON_RIGHT:
			if selected >= 0:
				selected = -1
				_refresh()
			elif cell.x >= 0:
				# everything about that cell, nothing cut short
				_clear_tips()
				_cell_tips(cell, true)
		elif ev.button_index == MOUSE_BUTTON_LEFT and cell.x >= 0 and selected < 0:
			if real - focus_at < 0.4 or b.human() == null:
				return   # the click that only focuses the window
			dragging = true
			drag_from = cell
			drag_px = ev.position
			drag_manual = cell == b.human().pos
			# a ping: the pressed cell is the destination and stays put while the mouse moves
			board.walk_path = [] if drag_manual else _path(b.human().pos, cell)
			board.walk_mode = "go" if drag_manual else "hold"
			_clear_tips()
		elif ev.button_index == MOUSE_BUTTON_LEFT and cell.x >= 0 and selected >= 0:
			var played := selected
			if board.self_aim and b.human() != null:
				cell = b.human().pos   # a card on oneself: a click anywhere on the board uses it
			if b.cmd_play(selected, cell):
				_fly(played, cell)
				selected = -1
				_after()
			else:
				board.out_of_range_click(cell)
				wiggle_until = real + 0.3

## Click-to-move: walks there one cell (one second) at a time, and stops early when a new
## warning appears or the body is hit, so the player can rethink.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		focus_at = real

## Walking, like a ping: press on the destination, drag right and release to go; drag left or
## right-click to cancel. The destination is the cell first pressed. Pressing on the hero instead
## draws the route by hand, cell by cell (it may cross itself). A plain click steps to a neighbour.
func _drag_to(c: Vector2i) -> void:
	var b := flow.battle
	var h := b.human()
	if h == null:
		return
	var path: Array = board.walk_path
	var last: Vector2i = path.back() if not path.is_empty() else h.pos
	if c == last:
		return
	var prev: Vector2i = path[path.size() - 2] if path.size() >= 2 else h.pos
	if not path.is_empty() and c == prev:
		path.pop_back()   # stepping back over the last cell rubs it out
	elif absi(c.x - last.x) + absi(c.y - last.y) == 1 and b.grid.passable(c) and (b.grid.unit_at(c) == null or c == h.pos):
		path.append(c)
	else:
		var tail := _path(last, c)
		if tail.is_empty():
			return
		path.append_array(tail)
	board.walk_path = path

func _end_drag(cell: Vector2i, at: Vector2) -> void:
	dragging = false
	var b := flow.battle
	var h := b.human()
	var path: Array = board.walk_path
	board.walk_path = []
	if h == null:
		return
	var dx := at.x - drag_px.x
	if not drag_manual:
		if dx < -DRAG_GO:
			path = []   # dragged left: cancelled
		elif dx <= DRAG_GO and not flow.calm():
			# no drag: only a step onto a neighbouring cell counts (in a calm room, any click walks)
			path = [drag_from] if absi(drag_from.x - h.pos.x) + absi(drag_from.y - h.pos.y) == 1 else []
	if path.is_empty():
		_refresh()
		return
	var hp0 := h.hp
	for step in path:
		var hh := b.human()
		if hh == null or b.phase != "player" or not b.cmd_move(step - hh.pos):
			break
		if b.human() != null and b.human().hp < hp0:
			break   # hit on the way: hand control back
		if b.grid.get_material(b.human().pos) in ["door", "chest", "stall", "spring"]:
			break   # stepped on something that does something
	_after()

func _path(from: Vector2i, to: Vector2i) -> Array:
	var g := flow.battle.grid
	var prev := {from: from}
	var q := [from]
	while not q.is_empty():
		var c: Vector2i = q.pop_front()
		if c == to:
			break
		for n in g.neighbors4(c):
			if prev.has(n) or not g.passable(n) or (g.unit_at(n) != null and n != to) or g.mat_def(n).get("lethal", false):
				continue
			prev[n] = c
			q.append(n)
	if not prev.has(to):
		return []
	var out := []
	var c2 := to
	while c2 != from:
		out.push_front(c2)
		c2 = prev[c2]
	if not out.is_empty() and flow.battle.grid.unit_at(out.back()) != null:
		out.pop_back()   # clicked a body: walk up to it
	return out

## A quick flick of the wheel keeps turning the ring: notches that follow within a moment add
## up to ROLL_BURST cards in one smooth turn (one card per notch, so a single notch never
## over-turns by mistake).
const ROLL_BURST := 4
const ROLL_CHAIN := 0.35   # seconds after a roll in which the next notch joins it
var roll_at := -9.0
var roll_burst := 0
var fast_flow := false      # the seconds now playing are only the ring turning: play them quickly

func _input(ev: InputEvent) -> void:
	# the wheel turns the ring wherever the mouse is
	if flow == null or flow.phase != "battle" or not (ev is InputEventMouseButton) or not ev.pressed or _sliding():
		return
	if ev.button_index != MOUSE_BUTTON_WHEEL_UP and ev.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return
	get_viewport().set_input_as_handled()
	var chained := real - roll_at < ROLL_CHAIN
	if _replaying() and not (chained and fast_flow and roll_burst < ROLL_BURST):
		return
	if not chained:
		roll_burst = 0
	_roll(-1 if ev.button_index == MOUSE_BUTTON_WHEEL_UP else 1)

func _roll(dir: int) -> void:
	selected = -1
	if flow.battle.cmd_wheel(dir):
		roll_at = real
		roll_burst += 1
		fast_flow = true
	if not _replaying():
		flow.update()
	_refresh()

const SPEEDS := [1.0, 1.5, 2.0, 3.0, 4.0]
const CARD_KEYS := [KEY_Q, KEY_W, KEY_E, KEY_R, KEY_T]

func _unhandled_input(ev: InputEvent) -> void:
	if flow == null or flow.phase != "battle" or not (ev is InputEventKey) or not ev.pressed or ev.echo or _sliding():
		return
	# physical keys, so a Korean input mode (ㅂㅈㄷㄱㅅ) still works
	var pk: int = ev.physical_keycode
	if pk == KEY_N:
		BoardView.FREEZE = not BoardView.FREEZE   # study: crawl on vs brake to a full stop
		return
	if pk == KEY_B:
		BoardView.BT2 = not BoardView.BT2   # study: compare the new held-time look with the old one
		return
	if pk >= KEY_1 and pk <= KEY_5:
		# game speed: only how fast passing seconds play back, never the rules
		speed = SPEEDS[pk - KEY_1]
		speed_shown_at = real
		return
	if _replaying():
		return
	var b := flow.battle
	if pk in CARD_KEYS:
		var i: int = CARD_KEYS.find(pk)
		if i < cards.size() and cards[i] != null:
			_on_card_picked(cards[i])
		return
	if pk == KEY_A or pk == KEY_D:
		_roll(-1 if pk == KEY_A else 1)
		return
	match ev.keycode:
		KEY_UP: b.cmd_move(Vector2i.UP)
		KEY_DOWN: b.cmd_move(Vector2i.DOWN)
		KEY_LEFT: b.cmd_move(Vector2i.LEFT)
		KEY_RIGHT: b.cmd_move(Vector2i.RIGHT)
		KEY_SPACE:
			selected = -1
			b.cmd_wait(1)
		KEY_ESCAPE:
			selected = -1
		_: return
	_after()

func _after() -> void:
	fast_flow = false
	if not _replaying():
		flow.update()
	_refresh()
