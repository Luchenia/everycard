# server/ — card forge (user cards) backend

Design and staged plan: `docs/card-forge-api-design.md` (Korean).

This folder never touches the game client. What is here now (stage F0 start):

- `forge/power.ts` — TypeScript port of `src/sim/power.gd`. Reads the same `data/power_scores.json` and `data/states.json`.
- `forge/power_test.ts` — scores every card in `data/cards/` and writes `forge/power_cases.json`.
- `tests/sim/power_parity_test.gd` — the game loads `power_cases.json` and checks the GDScript calculator gives the same numbers.
- `supabase/migrations/0001_card_forge.sql` — tables for cards, versions, forge jobs, votes, reports, moderation queue, appeals, stats.

Check both calculators agree (run after changing `power.gd`, `power.ts` or `data/power_scores.json`):

```
node --experimental-strip-types server/forge/power_test.ts
godot4 --headless --path . -s tests/run_all.gd -- power_parity_test
```

Next (F0/F1): `data/ops.json` part list, JSON schema generator, offline forge script (name + PNG → card JSON via the Claude API), Edge Functions.
