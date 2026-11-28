// Card power calculator: a line-by-line port of src/sim/power.gd.
// Game and server must agree, so both read the same data/power_scores.json and
// data/states.json, and server/forge/power_test.ts checks every bundled card.
// Runs on Node (tests) and Deno (Supabase Edge Functions): no imports.

export type Json = Record<string, any>;

export interface Rules {
  power: Json;                       // data/power_scores.json
  states: Record<string, Json>;      // data/states.json indexed by id
  gridW: number;                     // data/battle.json grid_w
  gridH: number;                     // data/battle.json grid_h
}

export const AREA_OPS = ["state", "material", "damage", "status", "push", "heal"];

export function budget(rarity: string, r: Rules): number {
  return Number(r.power.budgets?.[rarity] ?? 0);
}

export function areaCells(shape: string, size: number, r: Rules): number {
  switch (shape) {
    case "line": return Math.max(size, 1);
    case "circle": case "around": return (2 * size + 1) ** 2;
    case "square": return Math.max(size, 1) ** 2;
    case "cross": return 4 * size + 1;
    case "cone": return Math.max(size, 1) ** 2;
    case "all": return r.gridW * r.gridH;
  }
  return 1;
}

export function partScore(part: Json, r: Rules): number {
  const pw = r.power;
  const op: string = part.op ?? "";
  const o: Json = pw.ops?.[op] ?? {};
  const n = (v: any, d = 0) => Number(v ?? d);
  switch (op) {
    case "damage": case "heal": return n(part.amount) * n(o.per_amount, 1);
    case "beam": return n(part.damage) * n(o.per_damage, 1);
    case "push": return n(part.dist, 1) * n(o.per_dist, 1);
    case "shield": return n(part.amount) * n(o.per_amount, 1);
    case "discount": return n(part.amount) * n(o.per_amount, 1);
    case "borrow": return n(part.secs) * n(o.per_sec, 1);
    case "dash": return n(o.flat);
    case "belt": return n(part.amount, 1) * n(o.per_amount, 1);
    case "time_budget": return Math.abs(n(part.delta)) * n(o.per_delta, 1);
    case "delay": case "if": return partScore(part.part ?? {}, r) * n(o.inner_factor, 1);
    case "material": return n(pw.material_scores?.[part.id], 2);
    case "status":
      return n(pw.status_scores?.[part.id], 3) * Math.max(1, n(part.turns, 1)) * n(pw.status_turn_factor, 0.6);
    case "state": {
      const baseSecs = n(r.states[part.id]?.secs, 4);
      const held = Math.max(1, n(part.secs, baseSecs) / Math.max(1, baseSecs));
      return n(pw.state_scores?.[part.id], 3) * held;
    }
  }
  return n(o.flat);
}

export function score(card: Json, r: Rules): number {
  const pw = r.power;
  const tgt: Json = card.target ?? {};
  let total = 0;
  for (const part of card.parts ?? []) {
    let s = partScore(part, r);
    if (AREA_OPS.includes(part.op)) {
      const shape: string = part.shape ?? tgt.shape ?? "cell";
      const size = Math.trunc(Number(part.size ?? tgt.size ?? 0));
      s *= Math.pow(areaCells(shape, size, r), Number(pw.area_exponent ?? 0.6));
    }
    if (part.op !== "status") s *= 1 + Number(part.turns ?? 0) * Number(pw.turns_factor ?? 1);
    total += s;
  }
  return total
    - Number(card.time ?? 0) * Number(pw.time_credit ?? 2.5)
    - Number(card.exhaust ?? 0) * Number(pw.exhaust_credit ?? 3);
}

export function check(card: Json, r: Rules): { ok: boolean; score: number; budget: number } {
  const s = score(card, r);
  const b = budget(card.rarity ?? "common", r);
  return { ok: s <= b, score: s, budget: b };
}

/** Floor proposed in docs/card-forge-api-design.md §1.4: user cards must not be junk. */
export function tooWeak(card: Json, r: Rules, floor = 0.6): boolean {
  return score(card, r) < budget(card.rarity ?? "common", r) * floor;
}
