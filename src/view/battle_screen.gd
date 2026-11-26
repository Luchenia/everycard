extends Control
## Battle screen: clock track on top, the dungeon room filling the middle, the hand as a ring of
## cards at the bottom. Almost no text: hovering a card or a cell explains its [keywords].
## Keys: 1-5 pick a card, left click a cell to walk there, right click for full details (or to cancel
## a picked card), arrows move (1 s), mouse wheel or Q/E flip through the hand, Space wait 1 s.

const SEC_REAL := 0.5    # real seconds one game second takes when replayed
const HUB := Vector2(640, 800)   # hand wheel hub on screen
const WHEEL_STEP := 0.62         # radians between two wheel slots

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
var cards: Array = []          # CardView per hand slot (null for empty / heavy tail)
var hovered_card: CardView
var spin := 0.0                # ring turn animation (radians, eases to 0)
var wiggle_until := 0.0
var real := 0.0
var cell_hover_t := 0.0
var dragging := false     # left button held on the board with no card: drawing a walk
var drag_manual := false  # started on the hero: the path follows the mouse cell by cell
var drag_from := Vector2i(-1, -1)
var drag_px := Vector2.ZERO   # where the button went down: dragging right of it confirms, left cancels
const DRAG_GO := 24.0
var focus_at := -9.0     # when the window got focus: the click that focuses it never walks
var log_i := 0           # battle log entries already shown as flashes

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
	tips = VBoxContainer.new()
	tips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tips.add_theme_constant_override("separation", 4)
	tips.z_index = 10
	add_child(tips)
	overlay = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)
	_new_run()

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
	board.replaying = true
	replay_t += delta / SEC_REAL
	while replay_t >= 1.0 and shown_frame < fr.size() - 1:
		replay_t -= 1.0
		shown_frame += 1
	if shown_frame >= fr.size() - 1:
		replay_t = 0.0
		board.replaying = false
		flow.update()
		_refresh()
		return
	var a: Dictionary = fr[shown_frame]
	var b: Dictionary = fr[shown_frame + 1]
	var k := clampf(replay_t, 0.0, 1.0)
	var e := k * k * (3.0 - 2.0 * k)
	board.shown_pos = {}
	board.moving = {}
	board.replay_k = k
	for uid in a["pos"]:
		var p0 := Vector2(a["pos"][uid])
		var p1 := Vector2(b["pos"].get(uid, a["pos"][uid]))
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
		match e["t"]:
			"play":
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
	_step_replay(delta)
	_flashes()
	spin = move_toward(spin, 0.0, delta * 1.6)
	_layout_hand()
	if _replaying() and tips.visible and hovered_card == null:
		_clear_tips()   # bodies are still on their way: no stale facts under the mouse
	if board.hover.x >= 0 and selected < 0 and hovered_card == null and not _replaying() and not dragging:
		cell_hover_t += delta
		if cell_hover_t > 0.25 and tips.get_child_count() == 0:
			_cell_tips(board.hover)
	hud.queue_redraw()

# ---- layout -------------------------------------------------------------------------------------

func _refresh() -> void:
	for ch in overlay.get_children():
		ch.queue_free()
	var b := flow.battle
	board.battle = b
	board.fit()
	board.position = Vector2(round((1280 - board.size.x) / 2), 44)
	board.preview = {}
	board.aiming = selected >= 0
	timeline.battle = b
	_update_span()
	_build_hand()
	hand_layer.visible = flow.phase == "battle"
	if flow.phase == "reward":
		_reward_overlay()
	elif flow.phase in ["game_over", "victory"]:
		_end_overlay()

func _build_hand() -> void:
	for ch in hand_layer.get_children():
		ch.queue_free()
	cards = []
	hovered_card = null
	_clear_tips()
	var b := flow.battle
	if b.belt == null:
		return
	for i in b.belt.slots.size():
		var s = b.belt.slots[i]
		if s == null or s.get("tail", false):
			cards.append(null)
			continue
		var cv := CardView.new()
		cv.setup(s["card_id"], catalog, font)
		cv.set_meta("slot", i)
		cv.picked.connect(_on_card_picked)
		cv.hovered.connect(_on_card_hover)
		cv.inspected.connect(func(c):
			_clear_tips()
			_keyword_tips(c.def().get("desc", ""), true)
			tips.position = Vector2(clampf(c.global_position.x + c.size.x * c.scale.x + 12, 8, 1280 - 250), 300))
		hand_layer.add_child(cv)
		cards.append(cv)
	_layout_hand()

## The hand: five cards held in a fan at the bottom. Turning the wheel flips one card out at
## one end and a new one in at the other; the rest slide over by one place.
const FAN_GAP := 118.0
const FAN_Y := 668.0

func _fan_pos(f: float) -> Vector2:
	var d := f - 2.0
	return Vector2(640 + d * FAN_GAP, FAN_Y + d * d * 7.0)

func _draw_wheel() -> void:
	pass

func _layout_hand() -> void:
	hand_layer.queue_redraw()
	var aiming := selected >= 0
	var slide := spin / WHEEL_STEP     # -1..1 while a roll animates, eases to 0
	var wig := sin(real * 60.0) * 0.03 if real < wiggle_until else 0.0
	for ch in hand_layer.get_children():
		var cv := ch as CardView
		if cv == null:
			continue
		var i: int = cv.get_meta("slot")
		var f := float(i) + slide
		var anchor := _fan_pos(f)
		cv.lit = i == selected
		var big := cv == hovered_card and not aiming
		var z := 2 if big else 1
		if cv.zoom != z:
			cv.set_zoom(z)
		var alpha := 1.0
		if aiming:
			alpha = 0.62 if cv.lit else 0.24
		cv.pivot_offset = cv.size / 2
		# the card coming in turns over like a card taken into the hand
		var entering := (slide < 0.0 and i == 0) or (slide > 0.0 and i == cards.size() - 1)
		var sx := 1.0 - absf(slide) if entering else 1.0
		if big:
			var x := clampf(anchor.x - cv.size.x / 2, 8, 1280 - cv.size.x - 8)
			cv.position = Vector2(x, 796 - cv.size.y - (14 if cv.lit else 0))
			cv.rotation = wig if cv.lit else 0.0
			cv.scale = Vector2.ONE
		else:
			cv.position = anchor - cv.size / 2
			cv.rotation = (f - 2.0) * 0.07
			cv.scale = Vector2(maxf(0.02, sx), 1.0)
			if cv.lit:
				# the picked card stays small (the board must stay visible) but rises out of the hand
				cv.position.y -= 34
				cv.rotation = wig
		cv.modulate = Color(1, 1, 1, alpha)
		cv.z_index = 5 if (big or cv.lit) else 0

## The card pushed out by a roll leaves past the end of the hand.
func _drop_out(slot: int, dir: int) -> void:
	var src: CardView = cards[slot] if slot >= 0 and slot < cards.size() else null
	if src == null:
		return
	var cv := CardView.new()
	cv.setup(src.card_id, catalog, font, src.zoom)
	cv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cv.position = src.position
	cv.rotation = src.rotation
	cv.pivot_offset = cv.size / 2
	add_child(cv)
	var dest := _fan_pos(float(slot) + dir * 1.2) - cv.size / 2 + Vector2(0, 60)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(cv, "position", dest, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(cv, "rotation", cv.rotation + dir * 0.3, 0.3)
	tw.tween_property(cv, "modulate", Color(1, 1, 1, 0.0), 0.3)
	tw.chain().tween_callback(cv.queue_free)

# ---- hud ----------------------------------------------------------------------------------------

func _draw_hud() -> void:
	var b := flow.battle
	# fight pips (top-left)
	for i in 3:
		var c := Vector2(24 + i * 22, 20)
		var dia := PackedVector2Array([c + Vector2(0, -8), c + Vector2(8, 0), c + Vector2(0, 8), c + Vector2(-8, 0)])
		hud.draw_colored_polygon(dia, Art.INK)
		var col := Color("#e0b040") if i < flow.index else (Color("#ff6a4a") if i == flow.index else Color("#3a3644"))
		if i == 2:
			col = col if i <= flow.index else Color("#5a2a3a")
		hud.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -5), c + Vector2(5, 0), c + Vector2(0, 5), c + Vector2(-5, 0)]), col)
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
	# hand refill: a small ring on the deck icon counts the seconds to the next card
	var dr := b.next_draw_at() - b.now
	var dk := Vector2(1214, 20)
	if dr >= 1:
		hud.draw_arc(dk, 17, -PI / 2, -PI / 2 + TAU * (1.0 - float(dr) / maxf(1.0, float(b.round_time()))), 24, Color("#9cc8f0"), 2)
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
			var sl := _fan_pos(float(cv.get_meta("slot")))
			tips.position = Vector2(sl.x + CardView.SIZE.x + 12, 420)
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
	var ts := float(b.grid.get_var(p, "time_scale"))
	if ts > 1.05:
		_tip("가속", kw.get("가속", ""), Color("#9cc8f0"))
	elif ts <= 0.01:
		_tip("멈춘 시간", kw.get("멈춘 시간", ""), Color("#9cc8f0"))
	elif ts < 0.95 and m != "swamp":
		_tip("느림", kw.get("느림", ""), Color("#9cc8f0"))
	# what the floor marks are: sparks, wind streaks, crushing rings
	if float(b.grid.get_var(p, "charge")) > 0.5:
		_tip("전기", kw.get("전기", ""), Color("#ffe14a"))
	if EnvironmentStep.force_at(b.grid, p).length() > 0.4:
		_tip("돌풍", kw.get("돌풍", ""), Color("#9cc8f0"))
	if float(b.grid.get_var(p, "pressure")) > 2.0:
		_tip("짓누름", kw.get("짓누름", ""), Color("#9cc8f0"))
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
	_title("승리", 200)
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

func _end_overlay() -> void:
	_veil()
	_title("쓰러졌다" if flow.phase == "game_over" else "3연전 돌파", 300)
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
	if flow.phase != "battle" or _replaying():
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
	if flow.phase != "battle" or _replaying():
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
		elif dx <= DRAG_GO:
			# no drag: only a step onto a neighbouring cell counts
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

func _input(ev: InputEvent) -> void:
	# the wheel turns the ring wherever the mouse is
	if flow == null or flow.phase != "battle" or not (ev is InputEventMouseButton) or not ev.pressed or _replaying():
		return
	if ev.button_index == MOUSE_BUTTON_WHEEL_UP or ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_roll(-1 if ev.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
		get_viewport().set_input_as_handled()

func _roll(dir: int) -> void:
	selected = -1
	var out_slot := cards.size() - 1 if dir > 0 else 0
	var leaving: CardView = cards[out_slot] if out_slot >= 0 and out_slot < cards.size() else null
	if flow.battle.cmd_wheel(dir):
		spin = -WHEEL_STEP * dir
		if leaving != null:
			_drop_out(out_slot, dir)
	_after()

func _unhandled_input(ev: InputEvent) -> void:
	if flow == null or flow.phase != "battle" or not (ev is InputEventKey) or not ev.pressed or ev.echo or _replaying():
		return
	var b := flow.battle
	match ev.keycode:
		KEY_UP: b.cmd_move(Vector2i.UP)
		KEY_DOWN: b.cmd_move(Vector2i.DOWN)
		KEY_LEFT: b.cmd_move(Vector2i.LEFT)
		KEY_RIGHT: b.cmd_move(Vector2i.RIGHT)
		KEY_SPACE:
			selected = -1
			b.cmd_wait(1)
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
			var i: int = ev.keycode - KEY_1
			if i < cards.size() and cards[i] != null:
				_on_card_picked(cards[i])
			return
		KEY_Q:
			_roll(-1)
			return
		KEY_E:
			_roll(1)
			return
		KEY_ESCAPE:
			selected = -1
		_: return
	_after()

func _after() -> void:
	if not _replaying():
		flow.update()
	_refresh()
