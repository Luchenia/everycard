// Run: node --experimental-strip-types server/forge/power_test.ts
// Scores every bundled card with the TS calculator and fails if a non-enemy card is over budget.
// Expected scores per card are written to server/forge/power_cases.json; the GDScript side
// can load the same file to prove both calculators agree (see README).
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { check, type Rules } from "./power.ts";

const root = new URL("../../", import.meta.url);
const read = (p: string) => JSON.parse(readFileSync(new URL(p, root), "utf8"));

const battle = read("data/battle.json");
const rules: Rules = {
  power: read("data/power_scores.json"),
  states: Object.fromEntries(read("data/states.json").map((s: any) => [s.id, s])),
  gridW: battle.grid_w,
  gridH: battle.grid_h,
};

const cases: Record<string, number> = {};
const over: string[] = [];
for (const f of readdirSync(new URL("data/cards/", root)).sort()) {
  const card = read(`data/cards/${f}`);
  const r = check(card, rules);
  cases[card.id] = Math.round(r.score * 1000) / 1000;
  const enemy = card.id.startsWith("enemy_") || card.rarity === "boss";
  if (!r.ok && !enemy) over.push(`${card.id} ${r.score.toFixed(2)} > ${r.budget}`);
}
writeFileSync(new URL("server/forge/power_cases.json", root), JSON.stringify(cases, null, 1) + "\n");
console.log(`${Object.keys(cases).length} cards scored`);
if (over.length) {
  console.log("over budget (report only, the game allows hand-tuned base cards):\n  " + over.join("\n  "));
}
