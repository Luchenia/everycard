# 1단계 전투 프로토타입 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**목표:** 격자 전장에서 변인 연쇄, 시간 비용, 흐르는 손패, 몸 바꾸기가 실제로 돌아가는 플레이 가능한 전투 3연전을 만들어 "변인 연쇄가 재밌는가"를 확인한다.

**구조:** 시뮬레이션 코어(`src/sim/`)는 Node에 의존하지 않는 순수 GDScript(RefCounted)로 짜고 헤드리스 테스트로 검증한다. 변인, 물질, 반응, 카드, 적, 위력 점수는 모두 `data/` JSON이다. 화면(`src/view/`)은 코어 상태를 읽어 그리고 입력을 코어 명령으로 바꾸기만 한다.

**기술:** Godot 4.7.2, GDScript, Compatibility 렌더러, 헤드리스 `--script` 테스트 (렉시포지와 같은 방식).

**설계:** [docs/superpowers/specs/2026-11-25-everycard-design.md](../specs/2026-11-25-everycard-design.md), 변인 카탈로그 [docs/design/variables-v1.md](../../design/variables-v1.md)

## Global Constraints
- Godot 4.7.2, GDScript만 (C# 금지, 웹 내보내기 호환), 렌더러 `gl_compatibility`.
- 전장 9×7 칸. 턴당 시간 예산 10. 손패 5칸, 턴 끝 1칸 흐름, 다음 카드 1장 미리보기. 기본 1칸 이동은 시간 비용 0, 턴당 1회.
- 반응 연쇄 상한: 환경 단계 한 번에 칸당 반응 8회.
- 모든 무작위는 `SimRng`(시드 기반) 하나만 사용. `randi()`/`randf()` 전역 호출 금지. 같은 시드 + 같은 입력 = 같은 결과.
- 플레이어와 적은 같은 `Actor` 클래스(몸 + 덱 + 조종자). 플레이어 전용 분기 금지, 조종자 종류로만 갈린다.
- 변인, 물질, 반응, 카드, 적 정의는 `data/*.json`. 코드에 변인 이름 하드코딩은 시뮬레이션 규칙 실행기 외에는 금지.
- 이 단계 범위 밖: 서버, LLM, 맵/런, 저장, 정식 아트, 제4의 벽 변인(데이터 자리만 둠).

## Review Focus
1. 반응이 서로를 다시 부르는 순환(증기→압력→…) → 칸당 8회 상한에서 멈추고 로그에 "연쇄 상한" 기록. (Task 5 테스트)
2. 밀기/당기기로 유닛이 벽, 다른 유닛, 전장 밖으로 가는 경우 → 직전 칸에서 멈추고 충돌 피해(질량×남은 거리). 전장 밖은 멈춤(공허 칸만 낙하). (Task 5, 6 테스트)
3. 덱과 버림 더미가 모두 비었을 때 벨트 채우기 → 빈칸으로 둔다, 오류 없음. 덱만 비면 버림 더미를 시드로 섞어 덱으로. (Task 7 테스트)
4. 유효한 대상이 없는 카드(빈 칸 대상 피해 등) → 카드는 사용되고 시간은 소모, 효과 없음 로그. 시간이 부족한 카드는 사용 불가로 거부, 상태 변화 없음. (Task 6, 8 테스트)
5. 몸 바꾸기 대상이 보스이거나 덱이 빈 적 → 보스는 거부(카드 사용 불가), 덱이 빈 적은 바꾼 뒤 기본 카드 3장으로 덱 보충. (Task 4, 9 테스트)

---

## 파일 구조
```
project.godot                 Godot 프로젝트 (gl_compatibility, 메인 씬 res://scenes/battle.tscn)
engine.lock.json              Godot 4.7.2 버전/체크섬 (렉시포지 파일과 동일 형식)
tools/run.sh                  Godot 바이너리 받고 실행 (렉시포지 tools/run.sh 방식)
tools/test.sh                 임포트 후 tests/run_all.gd 실행
tests/run_all.gd              테스트 러너 (tests/sim/*_test.gd 전부 로드, 실패 수로 종료 코드)
tests/test_case.gd            assert_eq / assert_true 헬퍼 기반 클래스
data/variables.json           프로토타입 변인 15종
data/materials.json           물질 12종
data/reactions.json           반응 규칙
data/power_scores.json        부품별 위력 점수, 희귀도 예산
data/cards/*.json             기본 카드 20장
data/actors/*.json            캐릭터 1명, 적 3종, 보스 1종
src/sim/sim_rng.gd            시드 RNG
src/sim/catalog.gd            data/ 로드와 검증
src/sim/grid.gd               칸 값, 물질, 유닛 위치
src/sim/actor.gd              몸 + 덱 + 조종자
src/sim/environment_step.gd   퍼짐, 회복, 반응, 힘에 의한 이동
src/sim/effects.gd            카드 부품 실행기
src/sim/targeting.gd          모양(칸 목록) 계산
src/sim/power.gd              위력 계산기
src/sim/hand_belt.gd          흐르는 손패
src/sim/battle.gd             턴 진행, 시간 예산, 명령 처리, 로그
src/sim/enemy_ai.gd           적 행동 선택과 예고
src/view/*.gd, scenes/*.tscn  화면
```

## 공용 인터페이스 (모든 태스크 공유)
- `SimRng.new(seed: int)`, `.next_int(n: int) -> int` (0..n-1), `.next_float() -> float`, `.shuffle(arr: Array) -> void`
- `Catalog.load_dir(path: String) -> Catalog`; `.variables: Dictionary`(id → def), `.materials`, `.reactions: Array`, `.cards`(id → def), `.actors`(id → def), `.power: Dictionary`
- 변인 정의: `{id, min, max, default, spread, recover, kind: "scalar"|"vector"}`
- 칸 좌표는 `Vector2i`. `Grid.W = 9`, `Grid.H = 7`.
- 카드 정의: `{id, name, time: int, weight: int, rarity: "basic"|"common"|"rare"|"epic", target: {shape, range}, parts: Array}`
- 부품: `{op: String, ...}` — op 목록은 Task 6.
- 로그 항목: `{t: String, msg: String, data: Dictionary}`; `Battle.log: Array`

---

### Task 1: 프로젝트 뼈대와 테스트 러너

**Files:**
- Create: `project.godot`, `engine.lock.json`, `tools/run.sh`, `tools/test.sh`, `tests/run_all.gd`, `tests/test_case.gd`, `tests/sim/smoke_test.gd`, `src/sim/sim_rng.gd`, `tests/sim/sim_rng_test.gd`

**Interfaces:**
- Produces: `tests/test_case.gd`(`class_name TestCase extends RefCounted`, `assert_eq(a, b, label)`, `assert_true(c, label)`, `failures: int`, `checks: int`, 각 테스트 파일은 `extends TestCase`이고 `func run() -> void`), `SimRng`

- [ ] **Step 1:** 렉시포지의 `engine.lock.json`, `tools/run.sh` 방식을 그대로 가져와 `tools/run.sh`가 `tools/runtime/`에 Godot 4.7.2를 받아 체크섬 확인 후 인자를 넘겨 실행하게 한다. `tools/runtime/`은 `.gitignore`에 추가.
- [ ] **Step 2:** `tests/run_all.gd`(extends SceneTree): `res://tests/sim/` 의 `*_test.gd`를 이름순으로 로드해 `run()` 호출, 파일별 `checks/failures` 출력, 마지막 줄 `ALL checks=N failures=M`, 실패 있으면 `quit(1)`.
- [ ] **Step 3:** 실패 테스트 `sim_rng_test.gd`: 같은 시드 두 개의 `next_int(100)` 10회 결과 동일, 다른 시드는 다름, `shuffle` 결과가 시드에 따라 재현.
- [ ] **Step 4:** `tools/test.sh` 실행 → FAIL(SimRng 없음) 확인.
- [ ] **Step 5:** `SimRng`를 `RandomNumberGenerator` 래핑으로 구현(`seed` 고정, `shuffle`은 Fisher-Yates로 `next_int` 사용).
- [ ] **Step 6:** `tools/test.sh` → `ALL ... failures=0`.
- [ ] **Step 7:** 커밋 `feat: project skeleton, test runner, seeded rng`

### Task 2: 데이터 카탈로그

**Files:**
- Create: `data/variables.json`, `data/materials.json`, `data/reactions.json`, `src/sim/catalog.gd`, `tests/sim/catalog_test.gd`

**Interfaces:**
- Produces: `Catalog` (위 공용 인터페이스), `Catalog.validate() -> Array[String]` (오류 문장 목록, 비면 정상)

프로토타입 변인 15종 (id): `temperature`(-100..300, 기본 20, spread 0.25, recover 0.1), `pressure`(0..10, 기본 1, spread 0.5, recover 0.2), `gravity`(vector, 세기 0..5, 기본 (0,0)), `wind`(vector), `humidity`(0..1), `oxygen`(0..2, 기본 1), `friction`(0..2, 기본 1), `charge`(0..10, spread는 conductivity 비례), `conductivity`(물질에서 유도, 칸 값 아님 — 물질 속성), `magnetism`(vector), `light`(0..5, 기본 2), `noise`(0..10), `toxicity`(0..10), `time_scale`(0..3, 기본 1), `mana_density`(0..3, 기본 1). 남는 수치는 구현자 판단, 데이터 파일에서 조정 가능.

물질 12종: `none, water, ice, steam, oil, fire, gas_flammable, smoke, wall, metal, crystal, void`. 각 물질은 `{id, passable: bool, conductivity, flammable: bool, friction_override?, hardness?}`.

반응 규칙 형식: `{id, when: [{var|material, op: "<"|">="|"=="|"!=", value}], then: [{set_material?|add_var?|status_to_units?|damage_units?}]}`. 최소 규칙: 물↔얼음(0), 물→증기(≥100, pressure +2), 증기→물(<100), 기름+fire/temperature≥250→fire, fire+oxygen<0.2→none, fire+oil+oxygen≥1.5→폭발(pressure +5, fire 주변 확산은 Task 5), 얼음+temperature≥0→물, crystal+noise≥7→none, wall+pressure≥9→none.

- [ ] **Step 1:** 실패 테스트: `load_dir("res://data")` 후 `variables.size() == 15`, `materials.size() == 12`, `validate().is_empty()`, 그리고 반응이 없는 변인 id를 참조하는 가짜 카탈로그에서 `validate()`가 그 id를 포함한 오류 1개 반환.
- [ ] **Step 2:** 실행 → FAIL.
- [ ] **Step 3:** JSON 파일 작성, `Catalog` 구현 (`JSON.parse_string`, 참조 무결성 검사).
- [ ] **Step 4:** 실행 → PASS.
- [ ] **Step 5:** 커밋 `feat: data catalog for variables, materials, reactions`

### Task 3: 격자 상태

**Files:**
- Create: `src/sim/grid.gd`, `tests/sim/grid_test.gd`

**Interfaces:**
- Consumes: `Catalog`
- Produces: `Grid.new(catalog: Catalog)`; `get_var(p: Vector2i, id: String) -> Variant`(scalar는 float, vector는 Vector2); `set_var(p, id, v)`(범위로 clamp); `add_var(p, id, delta)`; `get_material(p) -> String`; `set_material(p, id)`; `in_bounds(p) -> bool`; `unit_at(p) -> Actor or null`; `place_unit(a: Actor, p) -> bool`(점유/통행불가면 false); `move_unit(a, p) -> bool`; `remove_unit(a)`; `neighbors4(p) -> Array[Vector2i]`; `duplicate_state() -> Dictionary`, `restore_state(d)`(되감기/미리보기용)

- [ ] **Step 1:** 실패 테스트: 기본값 확인(온도 20), clamp(온도 1000 → 300), 벽 칸에 `place_unit` false, 점유 칸에 false, `in_bounds(Vector2i(9,0))` false, `duplicate_state` 후 변경하고 `restore_state` 하면 원복.
- [ ] **Step 2:** 실행 → FAIL.
- [ ] **Step 3:** 구현 (칸 값은 변인별 `PackedFloat32Array` 또는 Dictionary 배열 중 구현자 선택).
- [ ] **Step 4:** 실행 → PASS. **Step 5:** 커밋 `feat: battle grid state`

### Task 4: 행위자(몸 + 덱 + 조종자)

**Files:**
- Create: `src/sim/actor.gd`, `data/actors/walker.json`, `data/actors/slime.json`, `data/actors/ember_imp.json`, `data/actors/iron_golem.json`, `data/actors/boss_tide_warden.json`, `tests/sim/actor_test.gd`

**Interfaces:**
- Produces: `Actor.from_def(def: Dictionary, uid: int) -> Actor`; 필드 `uid, def_id, hp, max_hp, mass, armor, resist: Dictionary, statuses: Dictionary`(id → 남은 턴), `team: int`(0 플레이어 진영, 1 적), `controller: String`("human"|"ai"), `is_boss: bool`, `base_ability: String`("step1"|...), `deck: Array[String]`(카드 id), `pattern: Array[String]`(적 행동 순서, 없으면 빈 배열); `take_damage(amount: int, kind: String) -> int`(저항/방어 반영 실제 피해); `Actor.swap_bodies(a: Actor, b: Actor) -> bool` — 보스면 false, 아니면 `controller`와 `team`을 맞바꾸고 true. 덱은 몸에 붙어 있으므로 그대로(설계 2.7.1: 남은 원래 몸은 원래 덱으로 AI가 조종).
- 몸 바꾸기 후 새 몸의 덱이 비어 있으면 `["strike","guard","step"]`로 보충.

- [ ] **Step 1:** 실패 테스트: from_def 필드 로드, 피해/저항(열 저항 0.5면 10 → 5), `swap_bodies(player, slime)` 후 slime.controller=="human", slime.team==0, player.controller=="ai", 보스와는 false이고 아무것도 안 바뀜, 덱 빈 적과 바꾸면 덱 보충.
- [ ] **Step 2:** FAIL 확인. **Step 3:** 구현, 액터 JSON 5개 작성(적은 `pattern`과 `deck`, 플레이어용 `base_ability`도 모두 가짐). **Step 4:** PASS. **Step 5:** 커밋 `feat: unified actor model with body swap`

### Task 5: 환경 단계

**Files:**
- Create: `src/sim/environment_step.gd`, `tests/sim/environment_step_test.gd`

**Interfaces:**
- Consumes: `Grid`, `Catalog`, `Actor`
- Produces: `EnvironmentStep.run(grid: Grid, catalog: Catalog, rng: SimRng, log: Array) -> void`

순서(한 번 실행): ① 퍼짐 — 스칼라 변인을 4이웃과 `spread × time_scale`만큼 평균 쪽으로(동시 갱신, 이전 상태 복사본 기준) ② 회복 — 기본값 쪽으로 `recover × time_scale` ③ 반응 — 칸마다 규칙을 순서대로 평가, 일치하면 적용, 변화가 없을 때까지 반복하되 칸당 8회 상한(넘으면 로그 `t:"chain_cap"`) ④ 힘 — 각 유닛에 대해 (gravity + wind + 압력차 기울기)를 합산, 세기 ≥ 질량이면 그 방향으로 칸 이동, 마찰 < 0.5이면 막힐 때까지 계속 미끄러짐; 막히면 충돌 피해 `mass × 남은 거리`(최소 1), void 칸에 들어가면 즉사(보스는 체력 30% 피해 후 직전 칸). `time_scale == 0` 칸은 ①~④ 모두 건너뜀 ⑤ 상태 지속 턴 감소.

- [ ] **Step 1:** 실패 테스트: (a) 가운데 칸 온도 200, 이웃 20 → 한 번 실행 후 이웃 온도 > 20, 가운데 < 200 (b) 물 칸 온도 150 → steam, 압력 증가 (c) 순환 반응 두 개를 테스트용 카탈로그로 넣으면 8회에서 멈추고 `chain_cap` 로그 1개 (d) gravity (3,0), 질량 1 유닛, 오른쪽 2칸 뒤 벽, 마찰 0 → 벽 앞에서 멈추고 피해 발생 (e) 유닛 오른쪽 void, 중력 오른쪽 → 사망 (f) time_scale 0 칸 온도 불변.
- [ ] **Step 2:** FAIL. **Step 3:** 구현. **Step 4:** PASS. **Step 5:** 커밋 `feat: environment step (spread, recover, reactions, forces)`

### Task 6: 대상 지정과 카드 부품 실행기

**Files:**
- Create: `src/sim/targeting.gd`, `src/sim/effects.gd`, `tests/sim/targeting_test.gd`, `tests/sim/effects_test.gd`

**Interfaces:**
- Consumes: `Grid`, `Actor`, `Catalog`, `SimRng`
- Produces:
  - `Targeting.cells(shape: String, origin: Vector2i, aim: Vector2i, size: int) -> Array[Vector2i]` — shape: `"self"|"cell"|"line"|"circle"|"cone"|"cross"|"all"`; 전장 밖 칸 제외.
  - `Effects.apply(card: Dictionary, user: Actor, aim: Vector2i, ctx: BattleContext) -> void`. `BattleContext`(같은 파일 내부 클래스) = `{grid, catalog, rng, log, actors: Array[Actor], pending: Array}`(지연 효과 큐: `{ticks, card_part, user, aim}`).
- 부품 op (각 부품은 선택적으로 `shape/size`를 덮어씀):
  - `var` `{id, mode:"add"|"mul"|"set", value, turns?}` (turns 있으면 끝날 때 원래 값 쪽으로 되돌림은 하지 않고 회복에 맡김 — turns는 매 환경 단계마다 재적용 횟수)
  - `material` `{id}` / `damage` `{amount, kind}` / `heal` `{amount}` / `push` `{dist, dir:"away"|"toward"|"up"|"down"|"left"|"right"}` / `teleport` `{to:"aim"}` / `status` `{id, turns}` / `beam` `{damage, kind, length}` — user 위치에서 aim 방향으로 진행, 벽에서 멈춤, metal/ice/crystal 칸에서 반사(진행 방향 반전 1회), gravity가 있는 칸에서 진행 방향이 중력 쪽으로 1칸 휨 / `delay` `{ticks, part}` / `if` `{cond: reaction 조건 형식, part}` / `belt` `{action:"freeze"|"advance"|"reverse", amount}` / `time_budget` `{delta}` / `swap_bodies` `{}` (aim 칸 유닛과) / `steal_card` `{}` (aim 칸 유닛 덱에서 rng로 1장 → 사용자 덱) / `plant_card` `{card_id}` (aim 유닛 덱에 넣기) / `cardify` `{}` (aim 유닛 hp ≤ 30%면 제거하고 `summon:<def_id>` 카드를 사용자 덱에) / `summon` `{def_id}` (aim 칸에 사용자 진영 AI 유닛 생성)
  - `belt`, `time_budget`은 `ctx`에 `on_meta: Callable`을 두어 Battle이 처리.
- 대상 없는 경우 로그 `t:"no_target"`만 남기고 정상 종료.

- [ ] **Step 1:** 실패 테스트(targeting): 9×7 가장자리에서 circle 반경 1이 전장 밖 제외, line이 aim 방향으로 size칸.
- [ ] **Step 2:** 실패 테스트(effects): var add로 circle 내 온도 +50; damage가 저항 반영; push away가 벽에서 멈추고 충돌 피해; beam이 ice 칸에서 반사되어 뒤쪽 적 명중; `if` 조건(젖음 상태) 거짓이면 효과 없음; delay 2틱이 pending에 들어감; swap_bodies 보스 대상이면 아무 변화 없음 + 로그; cardify 체력 50%면 실패, 20%면 덱에 `summon:slime` 추가; 빈 칸 damage는 `no_target` 로그.
- [ ] **Step 3:** FAIL. **Step 4:** 구현. **Step 5:** PASS. **Step 6:** 커밋 `feat: targeting shapes and card effect parts`

### Task 7: 위력 계산기와 흐르는 손패

**Files:**
- Create: `data/power_scores.json`, `src/sim/power.gd`, `src/sim/hand_belt.gd`, `tests/sim/power_test.gd`, `tests/sim/hand_belt_test.gd`

**Interfaces:**
- Produces:
  - `Power.score(card: Dictionary, catalog: Catalog) -> float`, `Power.budget(rarity: String, catalog) -> float`, `Power.check(card, catalog) -> Dictionary` `{ok: bool, score, budget}`. 점수 = Σ 부품 점수 × 범위 배수(칸 수 기반) × 지속 배수, 시간 비용과 무게는 할인 요소. 정확한 공식은 `power_scores.json`의 계수로 표현(서버가 같은 파일을 쓸 수 있게 코드엔 공식 구조만).
  - `HandBelt.new(deck: Array[String], rng: SimRng, catalog: Catalog, size := 5)`; `slots: Array`(각 칸 `{card_id, age}` 또는 null), `preview() -> String`(다음 카드 id 또는 ""), `take(slot: int) -> String`(빈칸 만듦), `end_turn(speed: float) -> void`, `hold() -> void`(다음 end_turn 1회 흐름 없음), `flush() -> void`(즉시 1칸 흐름), `reverse_next: bool`.
  - 흐름 규칙: `end_turn(speed)` — 이동 칸 수 = `round(speed)`(최소 0, 최대 2); 칸마다 맨 왼쪽 카드의 `age += 1`, 카드 무게 2(무거움)는 age 2가 되어야 버려짐, 무게 1은 age 1; 버려지면 왼쪽으로 당기고, 빈칸은 오른쪽부터 덱에서 채움; 덱이 비면 버림 더미를 rng로 섞어 덱으로; 둘 다 비면 빈칸 유지.
- [ ] **Step 1:** 실패 테스트(power): 기본 카드 `strike`(피해 6, cell)의 점수 ≤ basic 예산; 같은 카드에 circle size 2를 주면 점수 증가해 예산 초과로 `ok=false`.
- [ ] **Step 2:** 실패 테스트(belt): 초기 5장 + preview; take 후 end_turn(1)에 빈칸 채워짐; 무거운 카드가 맨 왼쪽이면 첫 end_turn에 안 버려지고 두 번째에 버려짐; hold 후 end_turn은 흐름 0; speed 0.4 → 흐름 0, 1.6 → 2; 덱 3장뿐일 때 버림 더미 재사용; 덱/버림 모두 비면 null 칸 유지(오류 없음).
- [ ] **Step 3:** FAIL. **Step 4:** 구현. **Step 5:** PASS. **Step 6:** 커밋 `feat: power calculator and flowing hand belt`

### Task 8: 전투 진행(턴, 시간 예산, 예고)

**Files:**
- Create: `src/sim/battle.gd`, `src/sim/enemy_ai.gd`, `tests/sim/battle_test.gd`

**Interfaces:**
- Consumes: Task 3~7 전부
- Produces: `Battle.new(catalog: Catalog, seed: int, player_def: String, enemy_defs: Array[String], layout: Dictionary)` (layout = 물질/변인 초기 배치, 없으면 rng로 물/기름/벽 몇 칸); 필드 `grid, actors, belt: HandBelt(조종자 human인 액터의 것), time_left: int, phase: "player"|"enemy"|"won"|"lost", telegraphs: Array({actor_uid, cells: Array[Vector2i], card_id}), log`
  - 명령: `cmd_move(dir: Vector2i) -> bool`(턴당 1회, 시간 0, base_ability가 step1일 때만), `cmd_ability(aim: Vector2i) -> bool`(다른 base_ability용, 시간 0, 턴당 1회), `cmd_play(slot: int, aim: Vector2i) -> bool`(시간 부족/범위 밖이면 false, 상태 불변), `cmd_hold() -> bool`(시간 2), `cmd_flush() -> bool`(시간 0), `cmd_end_turn()`.
  - `preview(slot: int, aim: Vector2i) -> Dictionary` — `grid.duplicate_state()`에서 효과만 적용해 `{cells, damage_by_uid, moved_by_uid}` 반환 후 원복(환경 단계는 미포함).
  - 턴 순서: 플레이어 턴 → 환경 단계 → 적 턴(기존 예고 해결 → 각 AI 액터가 pattern 다음 카드 선택: 카드에 `"telegraph": true`면 대상 칸 예고만, 아니면 즉시 사용) → 환경 단계 → 플레이어 턴(시간 = 10 × 플레이어 칸 time_scale 반올림, 손패 end_turn(플레이어 칸 time_scale)).
  - 승패: human 조종 액터 사망 → lost; team 1 액터 전멸 → won. 몸 바꾸기 후에는 바뀐 team 기준.
  - `EnemyAI.choose(actor: Actor, battle) -> {card_id, aim}` — pattern 순환, aim은 team이 다른 가장 가까운 액터의 칸.
- [ ] **Step 1:** 실패 테스트: 시간 10에서 시간 4 카드 두 장 후 세 번째 4짜리 거부(상태 불변); 이동 두 번째 거부; 적 예고 칸에 머물면 다음 적 턴에 피해, 비키면 무피해; 플레이어 칸 time_scale 0.5면 다음 턴 시간 5; 같은 시드·같은 명령 열 두 번 실행 → 최종 `grid.duplicate_state()`와 액터 hp 동일; 몸 바꾸기 후 원래 플레이어 몸을 쓰러뜨리면 won; preview 후 grid 상태 불변.
- [ ] **Step 2:** FAIL. **Step 3:** 구현. **Step 4:** PASS. **Step 5:** 커밋 `feat: battle turn loop, time budget, telegraphs, enemy ai`

### Task 9: 기본 콘텐츠

**Files:**
- Create: `data/cards/*.json` (20장), `tests/sim/content_test.gd`

카드 20장(id: 이름 · 시간 · 핵심 부품): `strike` 타격 2 피해6 · `guard` 방어 2 방어 상태 · `step` 질주 1 teleport 2칸 · `heat_wave` 열파 4 circle1 온도+120 · `frost` 냉기 3 circle1 온도-80 · `oil_spill` 기름 뿌리기 2 cone2 oil · `spark` 불씨 2 cell fire · `rain` 비 3 circle2 water+humidity · `shock` 방전 3 cell charge+8 · `gravity_well` 중력 우물 4 circle2 gravity toward aim · `gust` 돌풍 3 line wind · `compress` 압축 4 circle1 pressure+6 · `laser` 레이저 4 beam 8 · `mirror` 거울 세우기 2 cell metal · `slow_field` 느린 장 3 circle1 time_scale 0.3, turns 2 · `haste_field` 빠른 장 3 self time_scale 1.8 · `stasis` 정지 5 cell time_scale 0, turns 1 · `body_swap` 몸 바꾸기 6 epic swap_bodies · `pickpocket` 소매치기 3 steal_card · `bind_soul` 혼 묶기 5 cardify.
적 카드는 액터 JSON의 deck이 위 카드 또는 적 전용 카드(같은 파일 형식, `data/cards/enemy_*.json`)를 참조.

- [ ] **Step 1:** 실패 테스트: 모든 카드가 `Power.check().ok`, 모든 액터 덱의 카드 id가 존재, 각 카드를 빈 전투에서 사용해도 오류 없음(rng 시드 1~20 반복, 무작위 aim).
- [ ] **Step 2:** FAIL. **Step 3:** 카드 작성, 예산 초과 카드는 수치 조정. **Step 4:** PASS. **Step 5:** 커밋 `feat: 20 basic cards and starter actors`

### Task 10: 전투 화면과 3연전

**Files:**
- Create: `scenes/battle.tscn`, `src/view/battle_view.gd`(격자와 유닛), `src/view/overlay_view.gd`(변인 덧칠: 온도 빨강/파랑, 압력 화살표, 중력 화살표, time_scale 회색 시계 아이콘), `src/view/hand_view.gd`(벨트 5칸 + 미리보기 + 무게 표시), `src/view/timeline_view.gd`(남은 시간 막대), `src/view/log_view.gd`, `src/view/run_flow.gd`(전투 3연전: slime 2 → ember_imp+iron_golem → boss_tide_warden, 사이에 보상 3장 중 1장), `export_presets.cfg`(Windows Desktop, Web 단일 스레드)
- Test: `tests/sim/run_flow_test.gd` (화면 없이 run_flow 논리만)

**Interfaces:**
- Consumes: `Battle`의 필드와 명령, `preview()`
- 조작: 방향키 = 이동, 손패 카드 클릭 후 칸 클릭 = 사용(마우스 올리면 `preview` 결과로 영향 칸 테두리와 예상 피해 숫자), H = 붙잡기, F = 흘려보내기, Space = 턴 종료, 칸에 마우스 올리면 그 칸 변인 전체 툴팁. 연쇄는 로그 항목 순서대로 0.15초 간격 재생.
- 그래픽은 색 사각형과 글자. 정식 아트는 이후 단계.

- [ ] **Step 1:** 실패 테스트(run_flow): 승리 시 다음 전투로 넘어가며 보상 후보 3장이 같은 시드에서 재현, 선택 카드가 덱에 추가, 패배 시 `phase=="game_over"`, 몸 바꾸기로 이긴 뒤 다음 전투의 플레이어 액터 def_id가 바뀐 몸.
- [ ] **Step 2:** FAIL. **Step 3:** run_flow와 화면 구현. **Step 4:** PASS.
- [ ] **Step 5:** 수동 확인: `tools/run.sh --path .`로 실행, 3연전 끝까지 플레이, 기름+불씨 폭발 연쇄와 레이저 반사, 몸 바꾸기가 화면에서 보이는지. 스크린샷 3장을 `evidence/stage1/`에.
- [ ] **Step 6:** 웹 내보내기 확인 (tools/run.sh가 4.7.2 내보내기 템플릿도 받아 두도록 Task 1 스크립트에 옵션 추가): `tools/run.sh --headless --export-release "Web" build/web/index.html` 성공.
- [ ] **Step 7:** 커밋 `feat: playable battle view and 3-battle run`
