# Timeline Battle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (chosen earlier: build all, review at the end). Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace player turn / enemy turn with one shared clock where every action costs game seconds and the world (environment, enemies, telegraphs) runs while time passes.

**Architecture:** `Battle` gets an integer clock `now` and `advance(secs)`. Each second: player completion first (ties favour the player), then environment step every `env_every` seconds, then due telegraphs, then enemies whose `next_at <= now`. Rounds are only the draw rhythm (every `round_time` seconds the relaxed hand draws). Tunables live in `data/battle.json` so grid size and round length can change without code edits.

**Tech Stack:** Godot 4.7.2, GDScript, headless tests via `tools/test.sh`.

**Spec:** `docs/superpowers/specs/2026-11-25-timeline-battle-design.md` plus Luchenia's answer (2026-11-25): move 1 tile = 1 s as the basic character's personal ability; prototype keeps the proposed attack patterns and must include 1-tile attacks; grid size and round length decided after playing, so both configurable.

## Global Constraints
- `data/battle.json`: `{"round_time": 10, "grid_w": 9, "grid_h": 7, "env_every": 2, "move_time": 1, "wheel_time": 1, "draws_per_round": 2}`.
- Action duration in seconds = `ceil(time / time_scale_of_actor_cell)`; actor on a time_scale 0 cell cannot act (only wait).
- Card effect lands at the END of its time (wind-up); `exhaust` seconds pass after it with the character idle.
- Effect `turns` and status durations count environment steps (one per `env_every` seconds).
- Ties at the same second: the player's action resolves before telegraphs and enemies.
- No model ids in repo; Korean UI text.

## Review Focus
1. Player standing on time_scale 0: must not soft-lock; `cmd_wait` still advances. Test in Task 1.
2. Enemy frozen by stasis when its telegraph is due: telegraph waits, does not fire. Test in Task 2.
3. Wheel roll with empty hand / empty draw pile: costs time, no crash. Test in Task 3.
4. Player dies during a card's wind-up: effect does not land, battle ends lost. Test in Task 1.
5. Body swap mid-battle: new body uses its own base ability; hand rebuilt. Existing test kept green in Task 1.

---

### Task 1: Clock, player actions, config
**Files:** Create `data/battle.json`; Modify `src/sim/catalog.gd` (`config` dict), `src/sim/grid.gd` (`static var W/H`), `src/sim/battle.gd`; Test `tests/sim/battle_test.gd` (rewrite).
**Produces:** `Battle.now:int`, `Battle.cfg:Dictionary`, `advance(secs:int)`, `cmd_move(dir)->bool` (step1 only, costs move_time), `cmd_ability(aim)->bool` (1 s), `cmd_play(slot, aim)->bool`, `cmd_wait(secs:=1)->bool`, `action_secs(base:int, actor)->int` (-1 if frozen), `phase` in `player|won|lost`, `next_draw_at()`.
- [ ] Tests: `test_move_costs_one_second` (now 0→1), `test_card_time_advances_clock` (3 s card → now 3, effect applied), `test_slow_cell_doubles_duration` (ts 0.5 → 2 s move), `test_frozen_player_can_wait`, `test_round_boundary_draws`, `test_die_during_windup_no_effect`, `test_exhaust_passes_time`.
- [ ] Implement; remove `cmd_end_turn/cmd_hold/cmd_flush/time_left/turn`. `time_budget` meta now delays every foe's `next_at` and telegraph `fire_at` by `delta` seconds.
- [ ] Run `tools/test.sh battle`, commit.

### Task 2: Enemy schedule, second-based telegraphs, attack patterns
**Files:** Modify `src/sim/enemy_ai.gd`, `src/sim/battle.gd`, `src/sim/actor.gd` (`next_at`); Create `data/cards/enemy_bite.json` (1-tile, telegraph 1 s, dmg 5), `enemy_cross.json` (cross size 2, 3 s), `enemy_quake.json` (all cells except `safe: 3` random cells, 4 s), `enemy_snipe.json` (cell range 6, 2 s, `track: true` locks 1 s before firing); update actors' patterns.
**Produces:** telegraph dict `{actor_uid, card_id, aim, cells, fire_at, track}`; `EnemyAI.choose` no longer advances `pattern_index` (Battle does on use).
- [ ] Tests: `test_telegraph_fires_after_card_time`, `test_move_dodges_one_tile_attack`, `test_area_attack_needs_two_moves`, `test_safe_zone_leaves_safe_cells`, `test_tracking_locks_one_second_before`, `test_frozen_enemy_delays_telegraph`, `test_pattern_index_only_on_use`.
- [ ] Implement, run, commit.

### Task 3: Wheel draw and exhaustion data
**Files:** Modify `src/sim/hand_belt.gd` (`roll(dir:int)->String` returns dropped id, "" if none), `src/sim/battle.gd` (`cmd_wheel(dir)->bool`, cost = dropped card weight × wheel_time, min wheel_time), `src/sim/power.gd` (`exhaust_credit` 3.0/s), data: laser exhaust 2, body_swap exhaust 3, guard turns 3, stasis turns 2.
- [ ] Tests (`tests/sim/hand_wheel_test.gd`): `test_roll_right_drops_last_draws_left`, `test_roll_left_drops_first`, `test_heavy_roll_costs_two`, `test_roll_empty_hand`.
- [ ] Implement, run full suite (content/power budgets), commit.

### Task 4: Screen
**Files:** Modify `src/view/battle_screen.gd`, `src/view/board_view.gd` (cell size fits 648×504 for any grid), Create `src/view/timeline_bar.gd`.
- [ ] Top bar shows now..now+round_time: telegraph fire times, enemy next actions, next draw. Telegraph cells show seconds left. Mouse wheel / Q,E roll the hand; Space waits 1 s; arrows move (1 s); A ability.
- [ ] Capture screenshots with `tools/capture.gd` into `evidence/timeline/`, commit, update PR #1.
