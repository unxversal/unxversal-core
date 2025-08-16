## UNXVERSAL Protocol Security Review (Move sources)

This document enumerates critical security issues and risk areas found across all modules in `packages/unxversal/sources/`. For each file, we outline:
- Issues and impact
- Evidence (references to current code)
- Guardrails currently present
- Remediations (specific, actionable)

### Global cross-cutting issues
- Caller-supplied prices and symbols: Multiple core checks accept caller-provided `symbols`/`prices` instead of binding to on-chain feeds. This allows spoofed prices to bypass LTV/CCR/liquidation checks.
- Oracle feed binding: `oracle.move` does not maintain or enforce a per-asset allow-list; most modules accept arbitrary `Aggregator` references. We must implement a symbol→aggregator ID mapping and enforce it on every price read.
- Unit-scaling and accounting: Mixing scaled vs unit balances causes incorrect limits/liquidations.
- Arithmetic overflow/DoS: Widespread u64 multiplications on notional and fees without u128 promotion can abort transactions, blocking liquidations or trading.
- Incentive inconsistencies: Liquidation proceeds routed differently by product (sometimes to treasury, sometimes to liquidator) may under-incentivize critical actions.
- Unprivileged accrual: Some accrual functions accept arbitrary `dt`/`apr` from callers.

---

## File: `synthetics.move`

- Issues
  - Single-asset paths use strict bound price helpers; remaining multi-asset paths rely on `PriceSet`. We must ensure `PriceSet` is constructed via oracle-bound helpers (feed identity + staleness) and verified within entries. If not enforceable cleanly, deprecate the remaining multi-asset entrypoints.
  - Overflow risk in CCR computations: `debt_usd = units * price_u64` uses u64; promote to u128.
  - Liquidation incentive to treasury unchanged—policy needs alignment across products.
  - No reconciliation hooks with lending yet.

- Evidence
```1888:1966:packages/unxversal/sources/synthetics.move
public fun liquidate_vault<C>(...) { price_u64 = assert_and_get_price_for_symbol(...); }
```
```116:141:packages/unxversal/sources/synthetics.move
// Added E_ORACLE_FEED_NOT_SET, E_ORACLE_MISMATCH, E_DEPRECATED
```
```121:141:packages/unxversal/sources/synthetics.move
fun assert_and_get_price_for_symbol(...) // binds aggregator.feed_hash to registry.oracle_feeds[symbol]
```
```1182:1235:packages/unxversal/sources/synthetics.move
public fun withdraw_collateral_multi<C>(...)
```

- Guardrails present
  - Oracle binding enforced for single-asset paths via `assert_and_get_price_for_symbol`. Multi-asset uses `PriceSet` but must be verified.
  - Collateral ratio thresholds and staleness checks.

- Remediations
  - Enforce oracle-bound `PriceSet` verification or remove multi-asset flows; promote notional to u128; add reconciliation hooks; align liquidation incentives.

---

## File: `lending.move`

- Issues
  - Price spoofing: LTV and health checks rely on caller vectors. Replace with oracle-bound reads (or verified `PriceSet`).
  - Liquidation scaling: convert scaled<->units correctly before comparisons and writes.
  - Accrual access: `accrue_synth_market` must be admin/bot only; derive `dt` on-chain from last timestamp.
  - Overflow risk in notional/fee calculations—promote to u128.

- Evidence
```656:682:packages/unxversal/sources/lending.move
public fun compute_ltv_capacity_usd(... symbols, prices ...)
```
```687:721:packages/unxversal/sources/lending.move
public fun check_account_health_coins(... symbols, prices ...)
```
```772:790:packages/unxversal/sources/lending.move
// SCALED vs UNITS mixed in liquidate_coin_position
```
```1118:1136:packages/unxversal/sources/lending.move
public entry fun accrue_synth_market(... dt_ms, apr_bps ...)
```

- Guardrails present
  - Per-asset LTV/liquidation thresholds; pool pause; index helpers exist.

- Remediations
  - Bind risk checks to oracle; fix liquidation math; restrict accrual; u128 promotion.

---

## File: `dex.move`

- Issues
  - Arithmetic overflow/DoS: notional and fees computed as `u64 price * u64 size` without u128 promotion.
  - Oracle discount path accepts arbitrary `Aggregator` for UNXV price; no binding to allow-list.

- Evidence
```339:386:packages/unxversal/sources/dex.move
// collateral_owed = trade_price * fill; fee math in u64
```

- Guardrails present
  - Per-market pause; maker bonds; min/max price bounds; UNXV discount requires price > 0 and sufficient UNXV.

- Remediations
  - Promote notional/fee math to u128; clamp before cast; bind UNXV price feed via oracle registry.

---

## File: `book.move`

- Issues
  - Data-structure logic only; no protocol-facing issues beyond arithmetic bounds.

- Remediations
  - None.

---

## File: `big_vector.move`

- Issues
  - Storage/traversal only; no protocol-facing issues identified.

- Remediations
  - None.

---

## File: `gas_futures.move`

- Issues
  - Oracle binding: takes arbitrary `Aggregator` for SUI/USD; no allow-list per market.
  - Arithmetic overflow: notional and fee math in u64.
  - Discount path: UNXV/SUI price fallback can misprice discounts; no allow-list.

- Evidence
```200:210:packages/unxversal/sources/gas_futures.move
fun compute_micro_usd_per_gas(...)
```
```334:369:packages/unxversal/sources/gas_futures.move
// trade_fee and discount math in u64; arbitrary aggregators
```

- Guardrails present
  - Registry pause; dispute windows; tick/intervals.

- Remediations
  - Bind SUI/USD and UNXV/USD aggregators per registry; u128 math.

---

## File: `futures.move`

- Issues
  - Good: `settle_futures` binds aggregator by object ID.
  - Arithmetic overflow: u64 products for notional/fees.
  - Off-chain min/max price reliance is acceptable; watch spam.

- Remediations
  - u128 math and input caps in trade paths.

---

## File: `perpetuals.move`

- Issues
  - Funding/index price: `refresh_market_funding` accepts caller-provided price; must bind to oracle.
  - Arithmetic overflow: u64 products.
  - Discount path accepts arbitrary UNXV aggregator.

- Remediations
  - Bind index price to oracle; promote arithmetic; standardize discount path.

---

## File: `options.move`

- Issues
  - Creation fee UNXV discount underpriced; must require sufficient UNXV by oracle valuation.
  - Oracle binding: enforce stored feed for settlement/exercise.
  - Arithmetic overflow: u64 products for notional, fees, payouts.

- Remediations
  - Fix discount valuation; bind feeds; promote arithmetic to u128.

---

## File: `oracle.move`

- Issues
  - Doc/implementation mismatch: claims allow-list but only has `max_age_sec`; no feed registry.
  - Downstream modules pass arbitrary `Aggregator` references.

- Remediations
  - Implement per-asset feed registry and bound price helper; update all modules to call it.

---

## File: `treasury.move`

- Issues
  - None critical.

- Remediations
  - Align fee routing policies; consider optional rate limits.

---

## File: `unxv.move`

- Issues
  - None critical; capped supply tracked.

- Remediations
  - None.

---

## File: `vaults.move`

- Issues
  - Manager stake checks present; ensure all manager paths are gated.
  - Overflow risk in range ladder helpers (`need = per * p`).

- Remediations
  - Promote notional math to u128; bound before cast.

---

## File: `dex.move` CLOB substructures (`DexMarket`, `DexEscrow`)

- Issues
  - Economic DoS via large orders causing upstream overflows.

- Remediations
  - Same as DEX: u128 math and input caps.

---

## File: `book.move` and `utils.move`

- Issues
  - None security-critical; ensure caller modules validate inputs.

- Remediations
  - None.

---

## File: `gas_futures.move`, `futures.move`, `perpetuals.move`, `options.move` (fees/discount common)

- Common issues
  - UNXV discount flows must: use bound oracle price; compute `unxv_needed`; require it before applying discount; refund leftovers.
  - Arithmetic to u128; clamp before u64 conversion; input caps to avoid overflow DoS.

---

## Prioritized remediation plan
- P0: Oracle allow-list + enforce bindings everywhere; remove/validate caller price vectors.
- P0: Lending liquidation scaling fix; gate accrual with on-chain time; admin centralization via SynthRegistry.
- P0: Options creation-fee UNXV discount valuation fix; settlement/exercise feed binding.
- P1: Promote all notional/fee/CCR arithmetic to u128; add input caps; unify bot reward policy.
- P1: Align liquidation incentives across products.
- P2: Cross-module reconciliation hooks/events for synthetics↔lending.

This review is exhaustive per file; implementing the above will materially reduce protocol risk across synthetics, lending, and integrated products.
