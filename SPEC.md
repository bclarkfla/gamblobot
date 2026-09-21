# Gambl-o-bot — Phase 1 Spec (paper trading, Kalshi economics & climate)
 
Status: draft for build. Target: a Dockerized agent loop on Billy's machine (WSL2).
Phase 1 places **no real money and no real orders**. Real market data, simulated fills.
 
---
 
## 1. Objective
 
Build a research → position → track → evaluate loop against Kalshi's economics and
climate markets, and learn the agent-engineering patterns: scheduled autonomous runs,
tool-restricted LLM calls, a durable ledger, guardrails, and honest evaluation.
 
Profit is not an objective. Calibration and clean plumbing are.
 
## 2. Scope boundary (keep this in the repo README)
 
- **Allowed market categories:** economics, climate/weather, financial indicators.
- **Excluded:** sports, politics, entertainment, culture, tech/science event contracts.
  These are geofenced out of Washington by court order (Aug 2026), so the agent should
  not even be able to name them as candidates. Enforce with a category allowlist in code,
  not in a prompt.
- **Phase 1 is paper only.** No production order endpoints are wired up at all — the
  production API key, if used, is read-only market data.
## 3. Architecture
 
Four containers via `docker compose`:
 
| Service | Purpose |
|---|---|
| `db` | Postgres 16. Source of truth. Named volume for persistence. |
| `app` | Python 3.12. FastAPI for a small read UI + manual triggers. |
| `scheduler` | APScheduler (or a separate cron container) running the loop jobs. |
| `adminer` *(optional)* | Browser DB inspection while developing. |
 
Same image for `app` and `scheduler`, different entrypoints.
 
**Jobs:**
 
| Job | Cadence | Does |
|---|---|---|
| `sync_markets` | hourly | Pull open markets in allowed categories; upsert metadata. |
| `snapshot_prices` | every 15 min | Record yes_bid/yes_ask/last/volume for every market we hold or are watching. This table is what CLV is computed from. |
| `research_and_decide` | daily, 08:00 PT | The agent run. Produces zero or more decisions. |
| `settle` | hourly | Detect settled markets, resolve positions, write outcomes. |
| `evaluate` | daily, 23:00 PT | Recompute CLV, Brier, ROI, calibration buckets. |
 
## 4. The loop
 
1. **Candidate generation** — pull open markets in allowed categories, filter for liquidity
   (nonzero volume, bid/ask spread under some threshold) and a resolution date inside a
   configured horizon.
2. **Research** — for each candidate, the agent gathers evidence (web search, public data
   APIs: FRED for economics, NWS/NOAA for climate) and outputs a **probability estimate
   plus a confidence and a rationale**. The model outputs a number, not a bet.
3. **Decide** — deterministic code compares the model's probability to the market's
   implied probability, applies the fee model, and sizes the position. The LLM does not
   size bets and does not decide whether to trade.
4. **YOLO branch** — before each decision, a seeded RNG draws with p = 0.20. On a hit, the
   decision is tagged `yolo`: skip the edge test, use a flat minimum stake, and let the
   rationale be whatever the agent wants, including "YOLO". Store the RNG seed and draw so
   the split is auditable.
5. **Simulated fill** — see §6.
6. **Track** — positions stay open; `snapshot_prices` keeps building their price history.
7. **Settle and evaluate** — §9.
## 5. Kalshi integration notes
 
Verified against the live docs at docs.kalshi.com as of 2026-09-20 (see below for what
changed from the original secondary-sourced draft). Re-verify before coding against
anything not covered here — Kalshi has been changing things.
 
- **Production base URL:** `https://external-api.kalshi.com/trade-api/v2` (the earlier
  `api.elections.kalshi.com` URL in this doc was stale/wrong).
- **Demo base URL:** `https://external-api.demo.kalshi.co/trade-api/v2`.
- **Auth:** RSA-PSS (MGF1-SHA256, salt length = digest length) request signing. Headers
  `KALSHI-ACCESS-KEY` (key id), `KALSHI-ACCESS-SIGNATURE`, `KALSHI-ACCESS-TIMESTAMP` (ms).
  Signature covers `timestamp + METHOD + path`, path only (no query string).
- **Public market data needs no auth at all.** `GET /markets`, `/series/{ticker}`,
  `/series` (list), `/events/{ticker}` are unauthenticated. RSA-PSS signing is only needed
  for private endpoints (portfolio, orders) — still worth building and smoke-testing against
  something like `/portfolio/balance` even though `sync_markets`/`snapshot_prices` won't
  need it.
- **Category lives on the series, not the market.** `GET /markets` returns `event_ticker` /
  `series_ticker` but no category field. Category (`category` primary + `categories[]`
  discovery list) lives on `GET /series/{ticker}` and `GET /series` (filterable by
  `category=`, matches against the `categories` list). To build the category allowlist:
  resolve category via series and join down to markets by `series_ticker`. **The valid
  category strings are not enumerated in the docs** — call `GET /series` live and inspect
  real values before hardcoding the allowlist; don't guess strings for a legal-compliance
  filter.
- **Market status is a richer enum than open/closed/settled:** `initialized, inactive,
  active, closed, determined, disputed, amended, finalized`. Needs an explicit mapping to
  whatever simplified status model the jobs use.
- **Pricing is sub-penny, not whole-cent.** Market fields are fixed-point dollar *strings*
  with up to 6 decimal places (e.g. `yes_bid_dollars: "0.5600"`), and contract counts are
  fractional with 0.01 minimum granularity (`volume_fp`, etc.) — there is no legacy
  integer-cents field. See §8: stored as scaled integers, not floats.
- Python SDK: `kalshi_python_sync` (async variant `kalshi_python_async`). The older
  `kalshi-python` is deprecated. Writing the ~30 lines of signing by hand is also a
  reasonable learning exercise and removes a dependency.
- Rate limits are a token-bucket system with tiers; basic tier is small. Snapshotting every
  open market every 15 minutes will hit it — restrict snapshots to held + watchlist markets.
- Fees matter. Kalshi's trading fee is roughly proportional to `P × (1 − P)` per contract,
  which is largest at 50¢ — exactly where most "edge" appears. Pull the current fee schedule
  and implement it in the fill model. A paper trader that ignores fees will look profitable
  and teach you nothing.
**Demo environment vs simulated fills:** the demo environment has its own thin, artificial
order book, so prices there are not real. Prefer **real production market data + a local
fill simulator**. Use the demo environment only to exercise the order-placement code path
without risk. Keep the two behind one interface so Phase 2 is a config change.
 
## 6. Fill model (be pessimistic)
 
Kalshi quotes in cents = implied probability, which makes this pleasantly simple.
 
- A buy fills at the **ask**, a sell at the **bid**. Never at the mid.
- Cap size at the quantity resting at the touch at decision time. If we want more, either
  take the next level or truncate — pick one and record it.
- Apply the fee at fill.
- Record the full top-of-book quote at decision time alongside the fill, so you can audit
  the simulation later.
- No fill if the spread exceeds a configured max, or if volume is zero.
## 7. Position policy
 
- Fake bankroll starts at $1,000, tracked in the ledger, not a config constant.
- **Quant positions:** require estimated edge greater than fee + a margin (say 3 cents of
  probability) before trading. Size by fractional Kelly (¼ Kelly), hard-capped at 2% of
  bankroll per position and 10% per market category per day.
- **YOLO positions:** flat $5, no edge test, capped at one per run.
- Daily loss limit: if realized + unrealized drawdown exceeds 10% of bankroll in a day, the
  scheduler skips the decide job and writes a `halted` row.
## 8. Schema
 
Money and contract-count columns are scaled integers, not floats or whole-cent ints —
Kalshi's live API returns sub-penny prices and fractional contract counts (see §5).
Prices are millionths of a dollar (`*_micros`); contract/volume counts are hundredths of a
contract (`*_hundredths`). Applied as migrations `0001_initial_schema.sql` (this block, in
its original whole-cent form) and `0002_scaled_int_pricing.sql` (the rename to scaled
integers below) — the SQL here reflects current state, not the literal migration history.
 
```sql
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
  id                        bigserial primary key,
  ticker                    text not null references markets(ticker),
  observed_at               timestamptz not null,
  yes_bid_micros            int, yes_ask_micros int, last_price_micros int,  -- millionths of a dollar
  volume_hundredths         bigint, open_interest_hundredths bigint         -- hundredths of a contract
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
  id                     uuid primary key,
  decision_id            uuid not null references decisions(id),
  ticker                 text not null references markets(ticker),
  side                   text not null,
  contracts_hundredths   int not null,             -- hundredths of a contract
  entry_price_micros     int not null,             -- millionths of a dollar, the simulated fill
  entry_quote            jsonb not null,           -- full top-of-book at decision time
  fees_paid_micros       int not null,
  opened_at              timestamptz not null,
  status                 text not null,            -- open | settled | closed_early
  exit_price_micros      int,
  closed_at              timestamptz,
  pnl_micros             int
);
 
create table evaluations (
  id                    uuid primary key,
  position_id           uuid not null references positions(id),
  computed_at           timestamptz not null default now(),
  closing_price_micros  int,                     -- millionths of a dollar, last price before close_time
  clv_cents             double precision,        -- signed, in our favor is positive (not yet moved to micros — flagged open question, see §13)
  brier                 double precision,
  won                   boolean
);
 
create table runs (
  id           uuid primary key,
  started_at   timestamptz not null,
  ended_at     timestamptz,
  status       text not null,                -- ok | halted | error
  notes        text
);
```
 
Every decision writes a row whether or not it becomes a position. The skipped ones are
half the learning.
 
## 9. Metrics
 
- **CLV (primary).** `closing_price − entry_price` in cents, signed so positive means the
  market moved toward us. Define "closing price" as the last trade or mid within the hour
  before `close_time`. Also compute CLV at +1h and +24h after entry so you can see whether
  edge shows up immediately or slowly.
- **Brier score.** `(model_probability − outcome)²`, averaged. Measures whether the
  agent's numbers mean anything. Compare against a baseline of just using the market price
  — if the agent can't beat the market's own Brier score, it has no edge, which is the
  expected and perfectly interesting result.
- **Calibration buckets.** Group predictions in 10% bands, compare stated probability to
  realized frequency.
- **Absolute P&L, hit rate, ROI** — tracked as requested, reported with a sample-size
  caveat. At a handful of positions a week these are noise for months.
- **Split every metric by `bet_type`.** The quant-vs-YOLO comparison is the fun part, and
  the honest prior is that they'll be indistinguishable for a long time.
## 10. Guardrails
 
- **Category allowlist enforced in code**, checked again at position creation.
- **Idempotency:** every decision carries a deterministic key of `(run_id, ticker)`. A
  retried run cannot create a second position for the same market.
- **Tool separation:** the researching LLM call has web access but no database write and no
  order tool. A separate, non-LLM step writes positions. Web content is untrusted input —
  instructions found in a fetched page must not be able to reach the order path, because
  there is no order path reachable from there.
- **Kill switch:** a `halted` flag in the DB that the scheduler checks first, plus
  `docker compose stop scheduler`.
- **Secrets:** `.env` git-ignored; the RSA private key mounted read-only as a file, never
  baked into the image, never in an env var, never in a prompt.
- **Spend:** track Anthropic API token spend per run in the `runs` table. This is the only
  real money Phase 1 spends, and you want the habit before Phase 2.
## 11. Repo layout
 
```
gamblobot/
  docker-compose.yml
  Dockerfile
  .env.example
  CLAUDE.md                 # house rules for Claude Code in this repo
  migrations/               # plain SQL, applied on startup
  src/gamblobot/
    kalshi/                 # auth, client, models (swappable prod/demo)
    data/                   # fred.py, noaa.py
    research/               # the LLM call, prompt, output schema
    policy/                 # edge test, kelly sizing, yolo draw
    fills/                  # simulator
    jobs/                   # sync, snapshot, decide, settle, evaluate
    db/                     # sqlalchemy models, repo functions
    api/                    # fastapi read views
  tests/
```
 
## 12. Milestones
 
- **M0** — Compose up: Postgres + a container that connects and runs migrations.
- **M1** — Kalshi read client: auth working, market sync, price snapshots landing in the DB.
- **M2** — Fill simulator + policy + ledger, driven by hand-written fake decisions. No LLM yet.
- **M3** — The research/decide agent call, with the YOLO draw wired in.
- **M4** — Settlement, evaluation, and a plain FastAPI page showing open positions, CLV
  to date, and the quant/YOLO split.
Each milestone is a working system. Don't skip M2 — most of the interesting engineering
(idempotency, sizing, fees, the ledger) lives there, and it's testable without any model in
the loop.
 
## 13. Open questions
 
- Which economics markets have enough liquidity to be worth modeling? (CPI, Fed decisions
  and jobs numbers are the usual ones.)
- Do you want the daily run to notify you — email, or just the web page?
- Phase 2 (real money, small) is out of scope here, but the fill interface should be
  written as though it's coming.
- `decisions.edge_cents` and `evaluations.clv_cents` are still `double precision`, same as
  the original draft — not moved to scaled integers like the rest of §8 was. Worth deciding
  before M2/M4 whether these should also become `*_micros` ints for consistency with the
  no-floats-for-money rule, given they're derived directly from prices that are now scaled
  ints.
- Kalshi's valid series `category` values aren't enumerated in the docs (see §5) — need to
  hit `GET /series` live during M1 and confirm the exact strings before hardcoding the
  economics/climate/financial-indicators allowlist.
