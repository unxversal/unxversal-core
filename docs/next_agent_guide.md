## Unxversal Protocol – Engineering Guide for New Agents

This document gives you the minimum context and concrete rules to continue the implementation of the remaining protocol modules (Futures, Gas Futures, Perpetuals, cross-liquidation engine) in this codebase.

### Repository map (relevant paths)

- `packages/unxversal/Move.toml`: root manifest for Unxversal Move package
- `packages/unxversal/sources/`
  - `admin.move`: AdminRegistry shared object; gate all admin entry functions
  - `unxv.move`: UNXV token type and supply cap
  - `fees.move`: Global fee config, staking tier table, fee vault, staking/UNXV discount helpers, admin USDC conversions
  - `staking.move`: Weekly-epoch staking pool for UNXV (rewards deposited weekly)
  - `oracle.move`: Switchboard oracle allow-list registry and price reads with staleness checks
  - `book.move`, `utils.move`: Local orderbook utilities compatible with DeepBook semantics
  - `dex.move`: DeepBook integration + Unxversal protocol fee logic + permissionless pool creation
  - `lending.move`: Isolated lending pools with staking-based CF boost and origination fee
  - `options.move`: European options with per-series orderbooks, physical settlement

DeepBook integration (read-only, do not modify): `deepbookv3packages/deepbook/`.

### Non-negotiable guidelines

- Do not modify anything under `packages/sui/` (user policy).
- Use `sui::clock::Clock` for all time; do not use `std::time`.
- Keep lints ON. Do not disable the linter; fix errors properly.
- Write Move doc comments with `///`, not block comments.
- Follow existing code style: early asserts, clear naming, events for mutating flows.
- Admin gating: every parameter change or privileged operation must require `unxversal::admin::AdminRegistry` proof.

### Core primitives you will use

1) Admin registry
- `unxversal::admin::AdminRegistry` with `is_admin` checks. Use for all `entry` admin functions.

2) Fees and staking (centralized)
- `fees.move` has `FeeConfig` (shared) and `FeeVault` (shared):
  - Separate taker/maker protocol fee bps: `dex_taker_fee_bps`, `dex_maker_fee_bps`.
  - UNXV payment discount (`unxv_discount_bps`) and staking-tier discounts (admin-configured thresholds and bps).
  - Permissionless DeepBook pool creation fee in UNXV (`pool_creation_fee_unxv`).
  - Lending knobs: `lending_borrow_fee_bps`, `lending_collateral_bonus_bps_max`.
  - Admin USDC conversion: `admin_convert_fee_balance_via_pool<Base, Quote>(...)` to convert fee assets via DeepBook and deposit back to vault.
- Discount helpers:
  - `apply_discounts(taker_bps, maker_bps, pay_with_unxv, staking_pool, user, cfg) -> (taker_eff_bps, maker_eff_bps)`
  - Use this everywhere you assess protocol fees. No volume-based tiers; staking or UNXV-payment only.

3) Staking
- `staking.move` defines `StakingPool` (weekly epochs) and `active_stake_of(pool, user)` view.
- Fees paid in UNXV are split by `fees.accrue_unxv_and_split(...)`, then staker rewards are deposited to staking via `staking::add_weekly_reward` by the caller.

4) Oracle
- `oracle.move` manages a symbol → Switchboard Aggregator allow-list with staleness checks.
- Use `get_price_for_symbol` with `Clock` and Aggregator reference; admin must set feeds first.

### DEX layer (what exists and how to use)

- Protocol taker fee is charged in the input token for swaps; bps come from `fees.apply_discounts(..., pay_with_unxv, staking_pool, user, cfg)`.
- If user supplies UNXV, the UNXV discount is applied and fee proceeds are split (stakers/treasury/burn).
- Permissionless pool creation: `dex.create_permissionless_pool<Base, Quote>(registry, cfg, vault, unxv_fee, tick, lot, min, staking_pool, clock, ctx)` – collects UNXV fee, deposits stakers’ share to staking, sends treasury share, then calls DeepBook create.
- No maker rebates (explicitly removed).

### Lending (status and rules)

- Pool fields include `collateral_factor_bps` and `liquidation_collateral_bps`.
- `borrow_with_fee` applies an admin-set origination fee and uses `effective_collateral_factor_bps(...)` to increase CF by staking bonus, clamped so `eff_cf_bps > liquidation_collateral_bps`. Never allow min CR to be less than liquidation CR.
- Interest accrual uses utilization and a kinked model; reserves realized on repayment.

### Options (status)

- European options with per-series orderbooks; writers lock exact collateral (calls: Base units; puts: Quote = strike*units).
- Buyers pay premium to makers; exercise is physical using Switchboard price. Writer claim functions settle pool proceeds pro-rata.
- Fee hooks are in place to extend with protocol fees if desired.

### What remains to build

1) Futures (`futures.move`)
- Contracts with struct { expiry, contract_size, tick_size }.
- `open_position` / `close_position` with limit/market semantics (can use `book` or DeepBook for matching premium/hedging as needed).
- Mark-to-market keeper that settles PnL periodically (daily). Use `oracle` prices.
- Liquidation flow if margin < maintenance; integrate staking/UNXV fee discounts the same way as DEX: compute protocol fees via `apply_discounts` and accrue to `FeeVault` or split UNXV when paid in UNXV.
- Emit events for all state changes.

2) Gas Futures (`gasfutures.move`)
- Contracts keyed by expiry, notional.
- Update reference gas price each epoch using `sui::tx_context::reference_gas_price` in cron function.
- Settlement on expiry vs TWAP of epoch prices.
- Same fee pattern as above.

3) Perpetuals (`perpetuals.move`)
- Position struct with size, entry_price, margin, accumulated_funding, last_funding_time.
- Funding rate calculation cron (8h interval) using oracle and/or spot pool mid-prices.
- Liquidation flow. Insurance fund (Quote) maintained in the market object.
- Same fee pattern and staking discounts.

4) Cross-protocol liquidation engine
- A shared entry (in a small module, e.g., `liquidation.move`) that computes cross-account health using balances from lending + derivatives and triggers liquidations across modules. Guard rails and eventing required.

### Fee integration checklist (apply everywhere you add fees)

- Taker/maker bps: start with `cfg.dex_taker_fee_bps` / `cfg.dex_maker_fee_bps`.
- Compute `(taker_eff_bps, maker_eff_bps) = apply_discounts(..., pay_with_unxv, staking_pool, user, cfg)`.
- If fee is paid in input token: accrue with `fees.accrue_generic<T>(vault, coin, clock, ctx)`.
- If paid in UNXV: split with `fees.accrue_unxv_and_split(...)`, then deposit stakers’ share to `staking::add_weekly_reward(...)` and transfer treasury share to `fees.treasury_address(cfg)`.
- Emit events for transparency.

### Oracles

- Use Switchboard On-Demand Aggregator objects; `oracle.move` already enforces allow-list + staleness.
- Admins must set feeds before markets use them.

### Security & invariants

- Always use `Clock` timestamps.
- Prefer checked math; ensure no under/overflows; clamp ratios within (0, 10000).
- For collateral/margin logic ensure: `min_collateral_ratio > liquidation_collateral_ratio` at all times, including with staking bonuses.
- Cleanly emit events for all external impacts; avoid silent state changes.

### Build & tests

- Build: from repo root, `sui move build`.
- Unit tests can live alongside modules; follow the project preference to implement tests after code completion.

### Style and patterns

- Name types and functions descriptively. Keep functions single-responsibility.
- Add short doc comments (`///`) at module, struct, and function level.
- Use early asserts for preconditions.
- Keep admin entry functions minimal and eventful.

### Contact points in code

- Fee config surface: see `fees.move` functions at bottom (views and helpers).
- Staking views: `staking.active_stake_of(pool, user)`.
- DEX examples: `swap_exact_base_for_quote`, `create_permissionless_pool`.
- Lending examples: `borrow_with_fee`, `effective_collateral_factor_bps`.

Implement new modules by following the patterns above, gate all admin ops via `AdminRegistry`, integrate fees through `fees.apply_discounts` and `accrue_*`, and use the oracle + staking systems consistently.


