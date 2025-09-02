## Unxversal Lending – Production Readiness Audit (Trackable Checklist)

Status legend: [Pending] not started, [In‑Progress] being implemented, [Done] completed and verified.

1) [Pending] Accrual correctness and conservation (LEND‑01)
   - Problem: Verify borrow/supply index math and reserve accrual conserves value across time steps.
   - Evidence:
```1074:1129:packages/unxversal/sources/lending.move
    public fun accrue_pool_interest<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, clock: &Clock, ctx: &TxContext) {
        let now = sui::clock::timestamp_ms(clock);
        if (now <= pool.last_update_ms) { return };
        let mut dt = now - pool.last_update_ms;
        let clamp = reg.global_params.max_accrual_dt_ms;
        if (clamp > 0 && dt > clamp) { event::emit(AccrualClampApplied { ... }); dt = clamp; };
        ... // compute borrow/supply factors in 1e6 fixed-point, update indexes/totals
        event::emit(InterestAccrued { ... });
    }
```
   - Remediation: Re-derive factor math, ensure no leakage; plan fuzz suite (post‑code step).

2) [Pending] Fail‑closed posture: paused guards on all mutating paths (LEND‑02)
   - Problem: Some constructors/mutators may miss `reg.paused` checks.
   - Evidence:
```831:842:packages/unxversal/sources/lending.move
    public fun open_account(ctx: &mut TxContext) { ... transfer::share_object(acct); }
```
   - Remediation: Decide policy: allow account open while paused, or gate; align across functions like `new_price_set`.

3) [Pending] Comments cleanup: remove “Phase 1”/legacy references (LEND‑03)
   - Problem: Header still says “Phase 1”.
   - Evidence:
```1:9:packages/unxversal/sources/lending.move
    * Unxversal Lending – Phase 1
```
   - Remediation: Update header to neutral module description.

4) [Pending] Config pruning: drop unused legacy fields (LEND‑04)
   - Problem: `GlobalParams` includes synth‑era points; confirm usage.
   - Evidence:
```63:77:packages/unxversal/sources/lending.move
    points_accrue_synth: u64,  // points awarded on accrue_synth_market (unused after synth removal)
```
   - Remediation: Remove field and adjust initializers/setters if not used elsewhere.

5) [Pending] Admin gating: consistency and single source of truth (LEND‑05)
   - Problem: Legacy local admin set mirrored with `AdminRegistry`.
   - Evidence:
```581:591:packages/unxversal/sources/lending.move
    public fun grant_admin(...){ vec_set::insert(&mut reg.admin_addrs, new_admin); }
```
   - Remediation: Keep mirror minimal; ensure all privileged flows assert via `AdminRegistry`.

6) [Done] Oracle/time handling policy (LEND‑06)
   - Problem: Enforce ZERO‑TRUST prices. Never accept user‑supplied prices; always read from Switchboard aggregators with staleness/positivity checks and feed‑hash binding.
   - Evidence:
```129:143:packages/unxversal/sources/lending.move
    let px = get_price_scaled_1e6(cfg, clock, agg); table::add(&mut ps.prices, symbol, px);
```
   - Remediation: Enforced ZERO‑TRUST across lending: replaced `PriceSet` params in `withdraw`, `borrow`, `compute_ltv_capacity_usd_bound`, `check_account_health_coins_bound`, and `liquidate_coin_position` with aggregator vectors validated via `expected_feed_id`, reading prices via `get_price_scaled_1e6`.

7) [Pending] Event coverage across core flows (LEND‑07)
   - Problem: Ensure supply/withdraw/borrow/repay/accrue/skim/liquidate emit events with sufficient detail.
   - Evidence:
```153:170:packages/unxversal/sources/lending.move
    public struct AssetSupplied ...; AssetWithdrawn ...; AssetBorrowed ...; DebtRepaid ...; InterestAccrued ...; ReservesSkimmed ...
```
   - Remediation: Add/adjust events as needed (e.g., liquidation events for clarity).

8) [Pending] Caps and per‑tx limits enforcement (LEND‑08)
   - Problem: Validate per‑asset caps and per‑tx limits enforced in supply/borrow/withdraw.
   - Evidence:
```848:871:packages/unxversal/sources/lending.move
    if (ac.max_tx_supply_units > 0) { assert!(amount <= ac.max_tx_supply_units, E_VIOLATION); };
    if (ac.supply_cap_units > 0) { assert!(pool.total_supply + amount <= ac.supply_cap_units, E_INSUFFICIENT_LIQUIDITY); };
```
   - Remediation: Ensure symmetric checks in borrow and withdraw; add missing asserts if any.

9) [Pending] Accrual clamp behavior and emissions (LEND‑09)
   - Problem: Ensure clamp both emits and uses clamped `dt`.
   - Evidence: See LEND‑01 snippet; `dt` replaced by `clamp` when applied.
   - Remediation: Verified nominally.

10) [Pending] Flash‑loan safety (LEND‑10)
   - Problem: Enforce same‑PTB repay with explicit proof; ensure fee routed.
   - Evidence:
```1386:1431:packages/unxversal/sources/lending.move
    initiate_flash_loan ...; repay_flash_loan ... deposit fee via deposit_collateral_with_rewards_for_epoch(...)
```
   - Remediation: Consider replacing proof_* params with a typed proof object for stricter API.

11) [Pending] Treasury routing and bot rewards (LEND‑11)
   - Problem: Ensure epoch‑aware deposits used and reasons consistent.
   - Evidence: Skim/liquidation/flash fee use epoch‑aware deposits.
   - Remediation: Harmonize reason strings.

12) [Pending] Views/API consistency (LEND‑12)
   - Problem: Minimal getters; cohesive PriceSet accessors.
   - Evidence: `get_symbol_price_from_set` exists.
   - Remediation: Add views if needed; remove dead code.

13) [Pending] Test scaffolding helpers (LEND‑13)
   - Problem: Ensure robust test constructors and readers exist.
   - Evidence: `new_*_for_testing` for registry, account, pool, price set; mirror for events.
   - Remediation: Likely sufficient.

14) [Pending] Input coverage: LTV checks, liquidation priority (LEND‑14)
   - Problem: Validate liquidation targets top‑ranked debt and price inputs present.
   - Evidence:
```1249:1286:packages/unxversal/sources/lending.move
    rank_coin_debt_order ... assert!(eq_string(top, &debt_sym), E_VIOLATION);
```
   - Remediation: Verify ranking edge cases; ensure full symbol/price coverage in PriceSet.

—

Notes

- Oracle stack (ZERO‑TRUST): Switchboard On‑Demand via `get_price_scaled_1e6` with feed‑hash verification. Do not accept user‑provided prices.
- Treasury semantics: protocol fees/reserves go to Treasury; user PnL is coin‑based within pools.


