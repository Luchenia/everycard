-- Card forge: user-made cards, versions, feedback and moderation.
-- Design: docs/card-forge-api-design.md §3.3. Writes go through Edge Functions (service role);
-- players may only read public data and their own rows.

create table players (
  id uuid primary key references auth.users(id) on delete cascade,
  steam_id text unique,
  created_at timestamptz not null default now(),
  trust real not null default 0.5 check (trust between 0 and 1),   -- report weight
  report_ban_until timestamptz,
  forge_tickets int not null default 0 check (forge_tickets >= 0)
);

create type card_status as enum ('forging', 'preview', 'public', 'hidden', 'removed', 'discarded');

create table cards (
  id text primary key,                                   -- 'u_' + short id
  creator_id uuid not null references players(id),
  name text not null check (char_length(name) between 1 and 12),
  art_path text not null,                                -- storage: card-art/art/{id}.png
  art_hash text not null,
  status card_status not null default 'forging',
  current_version int not null default 0,
  content_tags text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index cards_status_updated on cards (status, updated_at);
create index cards_art_hash on cards (art_hash);

create table card_versions (
  card_id text not null references cards(id) on delete cascade,
  version int not null,
  effect jsonb not null,                                  -- same shape as data/cards/*.json
  description text not null,
  rarity text not null,
  family text not null,
  power_score real not null,
  min_rules_version int not null default 1,               -- game must know every op used
  author text not null check (author in ('llm', 'operator')),
  model text,
  prompt_version text,
  reason text,
  created_at timestamptz not null default now(),
  primary key (card_id, version)
);

create table forge_jobs (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id),
  card_id text references cards(id),
  stage text not null default 'queued',                   -- queued / screening / designing / validating / done / failed
  error text,
  tokens_in int, tokens_out int, cost_usd numeric(10, 5),
  started_at timestamptz not null default now(),
  finished_at timestamptz
);

-- Only cards a player actually obtained in a run can be voted on or reported.
create table card_obtained (
  player_id uuid not null references players(id),
  card_id text not null references cards(id),
  first_at timestamptz not null default now(),
  times_played int not null default 0,
  primary key (player_id, card_id)
);

create table votes (
  player_id uuid not null references players(id),
  card_id text not null references cards(id),
  value smallint not null check (value in (-1, 1)),
  updated_at timestamptz not null default now(),
  primary key (player_id, card_id),
  foreign key (player_id, card_id) references card_obtained(player_id, card_id)
);

create type report_reason as enum ('illegal', 'offensive', 'balance', 'broken', 'other');

create table reports (
  id bigint generated always as identity primary key,
  reporter_id uuid not null references players(id),
  card_id text not null references cards(id),
  reason report_reason not null,
  note text check (char_length(note) <= 300),
  weight real not null,                                   -- reporter trust at report time
  status text not null default 'open',                    -- open / upheld / dismissed
  created_at timestamptz not null default now(),
  unique (reporter_id, card_id),
  foreign key (reporter_id, card_id) references card_obtained(player_id, card_id)
);

-- Nothing is hidden automatically by an "illegal" report: it only jumps the queue.
create table mod_queue (
  id bigint generated always as identity primary key,
  card_id text not null references cards(id),
  priority text not null check (priority in ('urgent', 'normal')),
  source text not null,                                   -- upload_screen / illegal_report / report_threshold / rebalance
  llm_verdict jsonb,
  opened_at timestamptz not null default now(),
  resolved_by uuid references players(id),
  resolution text,
  resolved_at timestamptz
);
create index mod_queue_open on mod_queue (priority, opened_at) where resolved_at is null;

create table appeals (
  id bigint generated always as identity primary key,
  card_id text not null references cards(id),
  creator_id uuid not null references players(id),
  body text not null check (char_length(body) <= 500),
  status text not null default 'open',
  created_at timestamptz not null default now()
);

create table card_stats_daily (
  card_id text not null references cards(id),
  day date not null,
  offered int not null default 0,
  picked int not null default 0,
  played int not null default 0,
  wins_with int not null default 0,
  damage_share real,
  primary key (card_id, day)
);

create table wishes (
  id bigint generated always as identity primary key,
  card_id text not null references cards(id),
  body text not null,
  cluster_id int
);

create table rules_versions (
  version int primary key,
  power_scores jsonb not null,
  ops_schema jsonb not null,
  active_from timestamptz not null default now()
);

-- Row level security: clients read public cards and their own rows; all writes via functions.
alter table players enable row level security;
alter table cards enable row level security;
alter table card_versions enable row level security;
alter table forge_jobs enable row level security;
alter table card_obtained enable row level security;
alter table votes enable row level security;
alter table reports enable row level security;
alter table mod_queue enable row level security;
alter table appeals enable row level security;
alter table card_stats_daily enable row level security;
alter table wishes enable row level security;
alter table rules_versions enable row level security;

create policy "own player row" on players for select using (id = auth.uid());
create policy "public cards" on cards for select using (status = 'public' or creator_id = auth.uid());
create policy "versions of visible cards" on card_versions for select
  using (exists (select 1 from cards c where c.id = card_id and (c.status = 'public' or c.creator_id = auth.uid())));
create policy "own jobs" on forge_jobs for select using (player_id = auth.uid());
create policy "own obtained" on card_obtained for select using (player_id = auth.uid());
create policy "own votes" on votes for select using (player_id = auth.uid());
create policy "own reports" on reports for select using (reporter_id = auth.uid());
create policy "own appeals" on appeals for select using (creator_id = auth.uid());
create policy "rules readable" on rules_versions for select using (true);
-- mod_queue, card_stats_daily, wishes: service role only (no policy = no client access).

-- Weighted report total that makes a card a hide candidate (§5.2). Threshold lives in the caller.
create view card_report_weight as
  select card_id, sum(weight) as weight, count(*) as reporters
  from reports where status = 'open' and reason <> 'illegal'
  group by card_id;
