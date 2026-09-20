# Gambl-o-bot — house rules

Read `SPEC.md` first. It is the source of truth for architecture, schema and scope.
If something here conflicts with SPEC.md, SPEC.md wins — but say so rather than silently picking one.

## What this project is

A paper-trading agent loop against Kalshi's **economics and climate** markets. It is a
learning exercise in agent engineering. Profit is not a goal; calibration and clean
plumbing are.

## Hard rules

1. **No real orders, ever, in this phase.** No code path may call a Kalshi order endpoint
   against production. The production client is read-only market data. If you find yourself
   writing order submission, stop and ask.
2. **Category allowlist.** Only markets in economics, climate/weather and financial
   indicators. Sports, politics, entertainment, culture and tech/science event contracts are
   out of scope for legal reasons and must be filtered in code — never merely in a prompt —
   and re-checked at position creation.
3. **The LLM outputs a probability estimate and a rationale. Nothing else.** It does not
   size positions, does not decide whether to trade, and has no database write access and no
   order tool. Deterministic Python does the edge test, sizing and ledger writes.
4. **Fees are part of every calculation.** A paper trader that ignores Kalshi's fee schedule
   produces fake edge. If the fee schedule is unknown, stop and ask rather than guessing.
5. **Secrets never enter the image, an env var, a prompt, or a log.** The RSA private key is
   mounted read-only as a file. `.env` is git-ignored.

## Working style

- **Milestone at a time.** M0 → M4 per SPEC.md §12. Each milestone must run before moving on.
  Don't scaffold M3 while building M1.
- **Plan before you build.** For anything touching more than two files, propose the approach
  and wait. I'd rather redirect a plan than a diff.
- **Ask instead of assuming.** Unknown API shape, unclear requirement, missing fee schedule:
  ask. Do not invent a plausible endpoint, field name or formula. Verify Kalshi's API against
  the live docs — the spec's URLs and auth notes came from secondary sources and may be stale.
- **Tests where logic lives.** The fill simulator, the edge test, Kelly sizing, the YOLO draw
  and the CLV calculation all get unit tests with hand-computed expected values. API clients
  and glue don't need them.
- **Small commits, one concern each.** Conventional commit messages.
- **Migrations are plain SQL files**, applied in order on startup. No ORM-generated schema.

## Conventions

- Python 3.12, `uv` for dependency management, `ruff` for lint and format, `pytest`.
- Type hints on anything crossing a module boundary. `mypy` clean in `src/gamblobot/policy/`
  and `src/gamblobot/fills/` at minimum.
- All money in **integer cents**. Never floats for money. Probabilities are floats in [0, 1];
  Kalshi prices are ints in [1, 99].
- All times stored as `timestamptz` in UTC. Display in America/Los_Angeles.
- Structured logging (JSON) — every log line from a run carries `run_id`.

## Things that have bitten this kind of project before

- Retried jobs creating duplicate positions. Every decision has a deterministic key of
  `(run_id, ticker)`; the DB enforces it with a unique constraint.
- Rate limits. Kalshi's token budget is small on the basic tier. Snapshot only held and
  watchlist markets, and back off on 429.
- Filling at the mid instead of the ask, which manufactures edge out of the spread.
- Treating the demo environment's order book as real prices. It isn't. Real production data
  in, locally simulated fills out.
