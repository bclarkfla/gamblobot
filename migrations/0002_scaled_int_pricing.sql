-- Kalshi's live API returns sub-penny prices and fractional contract counts
-- (fixed-point dollar strings, up to 6 decimals; contract counts down to 0.01),
-- not the whole-cent integers SPEC.md §8 assumed. Money stays integer per
-- house rules, just at finer scale: prices in millionths of a dollar
-- (*_micros), contract/volume counts in hundredths (*_hundredths).

alter table price_snapshots rename column yes_bid to yes_bid_micros;
alter table price_snapshots rename column yes_ask to yes_ask_micros;
alter table price_snapshots rename column last_price to last_price_micros;
alter table price_snapshots rename column volume to volume_hundredths;
alter table price_snapshots rename column open_interest to open_interest_hundredths;

comment on column price_snapshots.yes_bid_micros is 'millionths of a dollar, e.g. $0.56 = 560000';
comment on column price_snapshots.yes_ask_micros is 'millionths of a dollar';
comment on column price_snapshots.last_price_micros is 'millionths of a dollar';
comment on column price_snapshots.volume_hundredths is 'hundredths of a contract, e.g. 2.50 contracts = 250';
comment on column price_snapshots.open_interest_hundredths is 'hundredths of a contract';

alter table positions rename column contracts to contracts_hundredths;
alter table positions rename column entry_price to entry_price_micros;
alter table positions rename column exit_price to exit_price_micros;
alter table positions rename column fees_paid_cents to fees_paid_micros;
alter table positions rename column pnl_cents to pnl_micros;

comment on column positions.contracts_hundredths is 'hundredths of a contract';
comment on column positions.entry_price_micros is 'millionths of a dollar, the simulated fill';
comment on column positions.exit_price_micros is 'millionths of a dollar';
comment on column positions.fees_paid_micros is 'millionths of a dollar';
comment on column positions.pnl_micros is 'millionths of a dollar';

alter table evaluations rename column closing_price to closing_price_micros;

comment on column evaluations.closing_price_micros is 'millionths of a dollar, last trade or mid within the hour before close_time';
