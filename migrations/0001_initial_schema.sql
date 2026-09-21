create table markets (
  ticker            text primary key,
  event_ticker      text not null,
  series_ticker     text,
  category          text not null,          -- allowlist-checked
  title             text not null,
  close_time        timestamptz not null,
  status            text not null,          -- open | closed | settled
  result            text,                   -- yes | no | void
  first_seen        timestamptz not null default now(),
  last_synced       timestamptz not null default now()
);

create table price_snapshots (
  id            bigserial primary key,
  ticker        text not null references markets(ticker),
  observed_at   timestamptz not null,
  yes_bid       int, yes_ask int, last_price int,   -- cents
  volume        bigint, open_interest bigint
);
create index on price_snapshots (ticker, observed_at desc);

create table decisions (
  id                 uuid primary key,
  created_at         timestamptz not null default now(),
  run_id             uuid not null,
  ticker             text not null references markets(ticker),
  bet_type           text not null check (bet_type in ('quant','yolo')),
  rng_seed           bigint not null,
  rng_draw           double precision not null,
  side               text not null check (side in ('yes','no')),
  model_probability  double precision,       -- null allowed for yolo
  market_probability double precision not null,
  edge_cents         double precision,
  rationale_short    text not null,          -- one or two sentences, always written
  rationale_long     text,
  evidence           jsonb,                  -- urls, data points, model version
  acted              boolean not null,       -- did it become a position
  skip_reason        text
);

create table positions (
  id               uuid primary key,
  decision_id      uuid not null references decisions(id),
  ticker           text not null references markets(ticker),
  side             text not null,
  contracts        int not null,
  entry_price      int not null,             -- cents, the simulated fill
  entry_quote      jsonb not null,           -- full top-of-book at decision time
  fees_paid_cents  int not null,
  opened_at        timestamptz not null,
  status           text not null,            -- open | settled | closed_early
  exit_price       int,
  closed_at        timestamptz,
  pnl_cents        int
);

create table evaluations (
  id                uuid primary key,
  position_id       uuid not null references positions(id),
  computed_at       timestamptz not null default now(),
  closing_price     int,                     -- last price before close_time
  clv_cents         double precision,        -- signed, in our favor is positive
  brier             double precision,
  won               boolean
);

create table runs (
  id           uuid primary key,
  started_at   timestamptz not null,
  ended_at     timestamptz,
  status       text not null,                -- ok | halted | error
  notes        text
);
