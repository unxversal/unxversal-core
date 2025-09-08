### Unxversal Testnet Rewards (On‑chain Points, Faucet, Referrals, Leaderboards)

This doc defines how users earn points and access faucet liquidity across Unxversal’s on-chain testnet.

- Protocols in-scope: options, gas futures, futures, perps, lending.
- Collateral/quote: USDU for all except lending (lending converts to USD via oracle).
- Timekeeping: day/week computed on-chain from sui::clock::Clock::timestamp_ms(clock).

## How you earn points (daily, rolled into weekly totals)

- Trading (perps, futures, gas futures; USDU)
  - Volume: sqrt(trade_volume_usd_today)
  - Maker quality: maker_volume_usd_today × maker_improve_bps / 10_000
  - Realized PnL: max(0, realized_pnl_usd_today)
  - Funding participation: abs(funding_paid_usd_today) / F_SCALE
  - Counterparty concentration penalty if top counterparty > 60% of your daily volume
- Options (USDU-quoted premium)
  - Buyer: premium_paid_usd_today
  - Maker: premium_received_usd_today
- Lending (USD via oracle at interaction time)
  - Borrow usage: interest_paid_usd_today × util_bps_at_borrow / 10_000
  - Lend quality: on supply/withdraw, add supplied_usd × max(0, util − kink)
  - Liquidations: debt_repaid_usd_today (capped/day)

Weights (1e6 scale; suggested start)
- Trading: wV=230k, wM=180k, wP=120k, wF=80k
- Lending: wB=180k, wL=100k
- Liquidations: wQ=40k

Daily points = weighted sum of the above minus penalties. Weekly points = sum of 7 daily points.

## Referrals (on-chain, multi-level)

- Levels: Primary (L1), Secondary (L2), Tertiary (L3)
- Suggested rates: L1 = 10%, L2 = 3%, L3 = 1% of referee’s earned points (post-penalties); credited in real time to referrers’ daily totals
- Constraints
  - A user picks one referrer once; immutable thereafter
  - Self-referral and cycles rejected
  - Referral points do not themselves trigger more referral points (no infinite chains)
  - Per-week referral cap: at most 100% of the referrer’s own earned points (to curb sybils)

## Faucet (USDU) policy

- Per-day mint cap: 100,000 USDU per user
- Tiered daily loss budgets: A=$300, B=$1,000, C=$3,000, D=$10,000
- Cooldown: hitting budget blocks faucet for the remainder of today + next day
- Tier upgrades: based on rolling 7‑day points (example thresholds: A→B=25k, B→C=150k, C→D=1M). Optional downgrades for large 7‑day drawdowns or repeated cooldowns

Users can mint up to the daily cap only while realized_loss_today < their tier’s budget.

## Windows, storage, and leaderboards (on-chain)

- Day id: floor(ms / 86_400_000); Week id: floor(day_id / 7)
- Storage
  - Per-user daily accumulators and 7-slot ring buffer (week rollup)
  - Per-week totals per user
  - Per-week Top-K (e.g., 1,000) exact leaderboard and a coarse histogram for percentile estimates
- Leaderboards
  - Past week: current week_id Top‑K + user scores
  - Past month: sum of last 4 weeks
  - All time: sum of all weeks since genesis (maintain an “all-time” running total)

Read functions (views; examples)
```text
points.view_week_points(user, week_id) -> u128
points.view_month_points(user, end_week_id, num_weeks=4) -> u128
points.view_alltime_points(user) -> u128

points.view_week_rank_exact(user, week_id) -> Option<u32>          // exact if in Top‑K
points.view_week_percentile(user, week_id) -> u16                  // 0–10_000 bps via histogram
points.view_topk_week(week_id) -> vector<(address, u128)>          // paged if needed
```

## USD normalization per product (all on-chain)

- Perps/Futures/Gas futures: notional_usd = price_1e6 × contract_size × qty / 1e6 (already computed at fill time)
- Options: USD = premium in Quote (USDU)
- Lending: convert amounts with on-chain oracle on each interaction (supply/withdraw/borrow/repay)

## Numerical examples

- Trading (perps)
  - Price = 10.00, contract_size=100, fill qty=50 → notional=$50,000
  - Taker: V = sqrt(50,000) ≈ 223.6; P=+200 (profit today)
    - Points ≈ 0.23×223.6 + 0.12×200 = 51.4 + 24 = 75.4
  - Maker: maker_volume=$50,000; improve=5 bps → M_raw=25 → 0.18×25=4.5
  - If top counterparty > 60%, subtract penalty (e.g., −5)
- Options
  - Buyer takes 10 units at $2.00 premium → $20 premium; buyer gets points on $20; maker too for received premium
- Lending
  - Borrow 2,000 USDC at 70% util, interest today $6 → borrow usage = 6×0.70=4.2; points = 0.18×4.2=0.756
  - Supply $5,000 at 80% util (kink 60%) → lend quality += 5,000×(0.80−0.60)=1,000; points scale with wL
- Referrals
  - Alice (L1 referrer) of Bob: Bob earns 2,000 points this week
    - Alice gets +200 (10% of 2,000), capped so Alice’s referral bonus ≤ Alice’s own-earned points that week
  - Carol (L2) above Alice gets +60 (3% of Bob’s 2,000); Dave (L3) above Carol gets +20 (1%)

- Faucet flow
  - Tier A user: budget $300/day; mints 100k USDU; loses $350 realized today → faucet blocked now + tomorrow
  - After upgrade to Tier C ($3k/day), same user can withstand larger daily loss before cooldown

## Anti-abuse (cheap, on-chain)

- Counterparty concentration penalty (>60%)
- Reject self-referral, cycles, and referral edits
- Zero lending points for borrow→immediate re‑supply same asset within a short window
- Optional min hold-time for taker volume unless price_move×size exceeds a threshold
- Daily caps for liquidation and referral credits

## Admin knobs (on-chain)

- Weights and scales, faucet caps and tier budgets, referral rates and caps, Top‑K size, histogram bucket edges

## Rank retrieval (week window)

- Exact if in Top‑K: use points.view_week_rank_exact(user, week_id)
- Otherwise: percentile via histogram with points.view_week_percentile(user, week_id)
- Frontends can show both: “Rank #237” (if exact) or “Top 8.4%” (percentile) with the raw weekly points value

- Added referrals (L1/L2/L3) with suggested rates and caps.
- Clarified USD normalization per protocol; lending uses oracle conversion.
- Defined weekly storage, leaderboards for week/month/all-time, and rank read functions.
- Kept faucet policy succinct and tied to weekly points tiers.