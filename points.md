### Unxversal Testnet Rewards (On‑chain Points + Faucet)

This document explains how rewards accrue and how faucet access works during testnet. All accounting is on-chain and USD-normalized.

- **Goal**: reward useful trading, liquidity, and risk work; bound daily faucet spend; resist wash trading.
- **Time**: days/weeks are computed on-chain via `sui::clock::Clock::timestamp_ms(clock)`.

### What earns points

- **Trading (Perps + Gas Futures)**
  - **Volume (sqrt)**: `sqrt(trade_volume_usd_1e6_today)`
  - **Maker quality**: `maker_volume_usd_1e6_today × maker_improve_bps / 10_000`
  - **Realized PnL (positive only)**: `max(0, realized_pnl_usd_today)`
  - **Funding participation**: `abs(funding_paid_usd_today) / F_SCALE`
  - Counterparty concentration penalty: if top counterparty > 60% of your volume today, a flat penalty is applied to trading points.
- **Options**
  - **Premium volume**: taker premium paid (USD) and maker premium received (USD).
- **Lending**
  - **Borrow usage**: `interest_paid_usd_today × util_bps_at_borrow / 10_000`
  - **Lend quality**: increments when utilization > kink at supply/withdraw: `Δ(score) = supplied_usd × max(0, util - kink)`
- **Liquidations**
  - **Saves**: `debt_repaid_usd_today` (capped per day)

Weights are admin-set (1e6 scale). Suggested start:
- **Trading**: wV=230k, wM=180k, wP=120k, wF=80k
- **Lending**: wB=180k, wL=100k
- **Liquidations**: wQ=40k

Daily points = sum(weight × component). A 7-slot ring buffer tracks the rolling 7‑day total.

### Faucet access (USDU)

- **Per-day mint cap**: e.g., 100,000 USDU/day/user.
- **Per-day loss budget (by tier)**: A=$300, B=$1,000, C=$3,000, D=$10,000.
- **Cooldown**: if your realized loss today ≥ budget, faucet is blocked today and for 1 next day.
- **Tiers**: auto-upgrade by 7‑day points thresholds (example: A→B=25k, B→C=150k, C→D=1M). Optional downgrade on large drawdowns or repeated cooldowns.

A user may mint up to the daily cap only while their realized loss today is below their tier budget.

### How USD is computed (on-chain, per module)

- **`futures.move`**: per-fill notional USD uses `price_1e6 × contract_size × qty` (you already compute this).
- **`gas_futures.move`**: treat `price_1e6 × contract_size` as Collat units; if Collat is a USD stable, this is USD.
- **`options.move`**: USD is the Quote premium paid/received (assumed stable).
- **Lending**: convert coin amounts to USD using `OracleRegistry` + `Aggregator` at interaction time.

### Anti‑abuse (cheap on-chain)

- Penalty if >60% of daily volume is vs one counterparty.
- Zero lending points for “borrow→immediate re‑supply same asset” within a short window.
- Optional minimum hold-time (perps) before taker volume scores, unless price_move × size exceeds a threshold.
- Self-match blocked at the CLOB; if detected, strong penalty.

---

### Numerical examples

- **Futures trade (taker and maker)**
  - Market: price = 10.00 (1e6), `contract_size = 100`.
  - Fill: 50 contracts. Notional = 50 × 10 × 100 = $50,000.
  - Taker:
    - Volume term V = sqrt(50,000) ≈ 223.6.
    - Realized PnL today +$200 → P = 200.
  - Maker:
    - Maker volume = $50,000.
    - Fill improves mid by 5 bps → M_raw = 50,000 × 0.0005 = 25.
  - With weights (wV=0.23, wP=0.12, wM=0.18 as fractions for illustration):
    - Taker points ≈ 0.23×223.6 + 0.12×200 = 51.4 + 24 = 75.4
    - Maker points ≈ 0.18×25 = 4.5
    - If top counterparty > 60%, apply penalty (e.g., −5 points).

- **Options trade**
  - Buyer takes 10 units at premium $2.00 each → premium = $20.
  - Points (buyer and maker) accrue using premium USD with their respective weights; e.g., with wV-like 0.23 for premium:
    - Buyer points ≈ 0.23×sqrt(20) ≈ 1.0
    - Maker premium quality (optional) can be added later; initially count premium USD symmetrically.

- **Lending (borrow + supply)**
  - Borrow: user borrows 2,000 USDC when utilization is 70% (kink=60%).
    - Pays $6 interest today. Borrow usage ≈ 6 × 0.70 = 4.2; points with wB=0.18 → 0.756.
  - Supply: user supplies $5,000 USDC at 80% utilization (> kink).
    - Lend quality increment = 5,000 × (0.80 − 0.60) = 1,000.
    - With wL=0.10 and scale factor, day points reflect this increment (admin-tuned).

- **Liquidation**
  - Liquidator repays $1,000 debt; with wQ=0.04 → 40 points (if uncapped). Daily cap applies.

- **Faucet day flow**
  - Caps: 100,000 USDU/day; Tier A budget = $300/day.
  - 10:00 — Mint 60,000 USDU; trade; realized loss so far $150 → can continue.
  - 14:00 — Mint 40,000 USDU (hits 100k cap); later realized loss reaches $350.
    - Since $350 ≥ $300, faucet blocks further claims today and sets a 1‑day cooldown.
    - Next day: cannot mint due to cooldown; day after next: can mint again (still Tier A unless upgraded).

- **Tier upgrade**
  - Over 7 days, user accumulates 180,000 points → crosses B→C (150k) → Tier C.
  - New daily loss budget = $3,000; user can scale activity without increasing faucet spend if profitable.

---

### Implementation notes (all on-chain)

- `futures.move`, `gas_futures.move`, `options.move`, `lending.move` call a small `points` module on fills/interest/supply/liq with precomputed USD_1e6.
- `points` keeps per-user daily accumulators + 7‑day ring buffer; computes day points; maintains tier.
- `faucet` enforces per-day mint cap, tiered loss budgets, and cooldown using realized loss tracked in `points`.