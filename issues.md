## UNXVERSAL Protocol Security Review (Move sources)

This document enumerates critical security issues and risk areas found across all modules in `packages/unxversal/sources/`. For each file, we outline:
- Issues and impact
- Evidence (references to current code)
- Guardrails currently present
- Remediations (specific, actionable)

### Global cross-cutting issues
- Caller-supplied prices and symbols: Multiple core checks accept caller-provided `symbols`/`prices` instead of binding to on-chain feeds. This allows spoofed prices to bypass LTV/CCR/liquidation checks.
- Oracle feed binding: `oracle.move` does not maintain or enforce a per-asset allow-list; most modules accept arbitrary `Aggregator` references.
- Unit-scaling and accounting: Mixing scaled vs unit balances causes incorrect limits/liquidations.
- Arithmetic overflow/DoS: Widespread u64 multiplications on notional and fees without u128 promotion can abort transactions, blocking liquidations or trading.
- Incentive inconsistencies: Liquidation proceeds routed differently by product (sometimes to treasury, sometimes to liquidator) may under-incentivize critical actions.
- Unprivileged accrual: Some accrual functions accept arbitrary `dt`/`apr` from callers.

---

## File: `synthetics.move`

- Issues
  - Price spoofing in multi-asset paths: aggregate mint/health/liquidation previously used caller-supplied `symbols`/`prices` (no binding to registry feeds). Fixed by deprecating multi-asset entry points and enforcing bound oracle reads per symbol.
  - Overflow in CCR computations: uses u64 for `debt_usd = new_debt * price_u64` and other notional math in several places. Risk remains; will be addressed in the P1 overflow hardening pass.
  - Liquidation incentive to treasury: `liquidate_vault` routes bulk collateral to treasury with bot cut. Policy review pending; unchanged in this step.
  - Cross-module divergence: No reconciliation hooks with lending yet; unchanged in this step.

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
public fun withdraw_collateral_multi<C>(...) { abort E_DEPRECATED }
```
```1462:1531:packages/unxversal/sources/synthetics.move
public fun mint_synthetic_multi<C>(...) { refund UNXV; abort E_DEPRECATED }
```
```1669:1676:packages/unxversal/sources/synthetics.move
public fun check_vault_health_multi<C>(...) { abort E_DEPRECATED }
```
```1942:1953:packages/unxversal/sources/synthetics.move
public fun rank_vault_liquidation_order<C>(...) { abort E_DEPRECATED }
```
```1896:1901:packages/unxversal/sources/synthetics.move
public fun get_vault_values<C>(...) uses assert_and_get_price_for_symbol
```

- Guardrails present
  - Oracle binding enforced for single-asset paths via `assert_and_get_price_for_symbol` ensuring aggregator identity matches `registry.oracle_feeds[symbol]`. Multi-asset, caller-priced functions are deprecated and abort with `E_DEPRECATED`.
  - Global/per-asset min collateral ratio and liquidation threshold; Switchboard staleness checks via `get_price_scaled_1e6` in single-asset paths; `CollateralConfig` binding enforced.

- Remediations
  - Completed: Removed reliance on caller-supplied prices by deprecating `*_multi` functions and binding all price reads to on-chain feeds per symbol.
  - Next: Promote notional math to u128; add cross-protocol reconciliation hooks; revisit liquidation incentive policy.

---

## File: `lending.move`

- Issues
  - Price spoofing: LTV and health checks use caller-supplied `symbols`/`prices` vectors; borrowers can over-borrow or avoid liquidations.
  - Critical unit-scaling bug in liquidation: compares and subtracts UNITS against SCALED balances, corrupting accounting and enabling or blocking liquidations incorrectly.
  - Unprivileged accrual for synth market: `accrue_synth_market` allows any caller to increase `total_borrow_units` with arbitrary `dt_ms`/`apr_bps` (debt inflation griefing).
  - Overflow risk: many notional/fee calculations use u64 products without u128 promotion.

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
  - Per-asset LTV and liquidation thresholds; pool pause; simple rate model; index helpers exist to convert scaled<->units but not consistently used in liquidation.

- Remediations
  - Bind all LTV/health/liquidation calculations to on-chain oracle reads per asset; remove caller price vectors.
  - Fix liquidation math: convert scaled to units before comparisons/mutations; write back scaled using `scaled_from_units`.
  - Restrict `accrue_synth_market` to admin/bot with bounded `dt_ms` computed from on-chain time; prefer deriving `dt` from last accrual timestamp.
  - Audit all u64 multiplications; use u128 intermediates.

---

## File: `dex.move`

- Issues
  - Arithmetic overflow/DoS: notional and fees computed as `u64 price * u64 size` without u128 promotion; large orders can abort matches and block books.
  - Oracle discount path accepts arbitrary `Aggregator` objects for UNXV price; no binding to an allow-list.

- Evidence
```339:386:packages/unxversal/sources/dex.move
// collateral_owed = trade_price * fill; fee math in u64
```

- Guardrails present
  - Per-market pause; maker bonds with GC slashing; explicit min/max price bounds on matching; UNXV discount requires price > 0 and sufficient UNXV.

- Remediations
  - Promote all notional/fee math to u128; clamp at safe bounds before converting to u64.
  - Bind UNXV price feed to a configured on-chain aggregator ID; reject unknown feeds.

---

## File: `book.move`

- Issues
  - Primarily data-structure logic. No critical security issues found beyond typical u64 arithmetic bounds; relies on callers for price/time fairness.

- Guardrails present
  - Max fills/iteration guards; expiry checks; tick/lot/min-size validations handled by caller modules.

- Remediations
  - None critical. Keep interfaces pure; ensure caller modules validate tick/lot/expiry.

---

## File: `big_vector.move`

- Issues
  - Storage and traversal logic only. No protocol-facing security issues identified.

- Remediations
  - None.

---

## File: `gas_futures.move`

- Issues
  - Oracle binding: takes arbitrary `Aggregator` for SUI/USD; no allow-list per market.
  - Arithmetic overflow: notional and fee math in u64.
  - Discount path: UNXV/SUI price fallback logic can misprice discounts if UNXV feed is invalid; no allow-list.

- Evidence
```200:210:packages/unxversal/sources/gas_futures.move
fun compute_micro_usd_per_gas(...)
```
```334:369:packages/unxversal/sources/gas_futures.move
// trade_fee and discount math in u64; arbitrary aggregators
```

- Guardrails present
  - Registry pause; dispute windows for settlement queue; min tick/intervals.

- Remediations
  - Bind SUI/USD and UNXV/USD aggregators per registry with ID checks; promote notional math to u128.

---

## File: `futures.move`

- Issues
  - Good: `settle_futures` binds aggregator by object ID to whitelisted underlying.
  - Arithmetic overflow: widespread u64 products for notional/fees; potential aborts.
  - Off-chain price reliance in `record_fill` bounds (caller sets min/max) acceptable but beware spam.

- Evidence
```507:523:packages/unxversal/sources/futures.move
// Enforce feed matches whitelisted underlying by aggregator object ID
```

- Guardrails present
  - Underlying allow-list and aggregator binding; registry pause; listing throttles.

- Remediations
  - Promote notional/fee math to u128; cap inputs to avoid overflow.

---

## File: `perpetuals.move`

- Issues
  - Funding and index price: `refresh_market_funding` accepts caller-supplied `index_price_micro_usd` (no on-chain oracle read). Attackers can skew funding direction/magnitude.
  - Arithmetic overflow: u64 products for notional, funding deltas, fees.
  - Oracle discount path accepts arbitrary UNXV aggregator.

- Evidence
```366:380:packages/unxversal/sources/perpetuals.move
public entry fun refresh_market_funding(... index_price_micro_usd: u64 ...)
```

- Guardrails present
  - Registry/market pause; funding rate caps; min listing intervals.

- Remediations
  - Bind index price to on-chain oracle; move funding computation to use oracle price directly. Promote all arithmetic to u128.

---

## File: `options.move`

- Issues
  - Creation fee UNXV discount bug: accepts any non-zero UNXV and applies full discount without pricing the UNXV amount. Lets callers underpay creation fees.
  - Oracle binding: exercise/settlement take arbitrary aggregators; per-underlying feed bytes stored but not enforced in `expire_and_settle_market_cash`.
  - Arithmetic overflow: u64 products for notional, fees, payouts.

- Evidence
```538:555:packages/unxversal/sources/options.move
// Creation fee discount: sets discount_applied if any UNXV provided; no valuation
```
```950:969:packages/unxversal/sources/options.move
// Settlement uses price_info aggregator without binding it to underlying
```

- Guardrails present
  - Registry pause; per-market caps; tick/contract size validations.

- Remediations
  - Require UNXV discount valuation (oracle-bound) and enforce `unxv_needed` before applying discount (mirror DEX flow). Bind exercise/settlement aggregators to stored oracle feed per underlying. Promote math to u128.

---

## File: `oracle.move`

- Issues
  - Documentation mismatch: claims an allow-list, but module only stores `max_age_sec`; no allow-list or feed binding API exposed/used by other modules.
  - Modules pass arbitrary `Aggregator` references; this module does not verify identity.

- Evidence
```1:21:packages/unxversal/sources/oracle.move
// Docstring vs implementation (no allow-list)
```

- Guardrails present
  - Staleness and positivity checks; overflow guard when scaling.

- Remediations
  - Implement per-asset feed registry (symbol → aggregator ID) and provide helper that rejects non-registered aggregators. Update all modules to call the bound helper.

---

## File: `treasury.move`

- Issues
  - None critical; deposit/withdraw pathways package-gated/admin-gated appropriately.
  - Consider rate-limiting or policy controls for bot reward splits across products to avoid inconsistent incentives.

- Remediations
  - None mandatory; align fee routing policies across modules.

---

## File: `unxv.move`

- Issues
  - None critical; capped mint/burn tracked. Ensure SupplyCap holder security off-chain.

- Remediations
  - None.

---

## File: `vaults.move`

- Issues
  - Manager stake registry is sound; ensure `assert_manager_active` called on all manager paths (it is).
  - Arithmetic overflow risk in range ladder helpers when computing `need = per * p`.

- Evidence
```223:263:packages/unxversal/sources/vaults.move
// vault_place_dex_range_bid: need = per * p in u64
```

- Remediations
  - Promote `need`/notional math to u128; pre-check bounds.

---

## File: `dex.move` CLOB substructures (`DexMarket`, `DexEscrow`)

- Issues
  - Economic DoS possible via very large orders causing overflows upstream; see DEX section.

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
  - UNXV discount flows should consistently: (1) fetch UNXV price from a bound oracle; (2) compute `unxv_needed`; (3) require it before applying discount; (4) refund leftovers.
  - Arithmetic to u128; clamp before u64 conversion.

---

## Prioritized remediation plan
- P0: Remove caller-supplied price vectors and bind all risk checks to on-chain oracles; implement oracle allow-list and enforce by symbol/market.
- P0: Fix lending liquidation scaling math; add privileged accrual (derive `dt` on-chain) and block arbitrary accrual.
- P0: Fix options market creation UNXV discount logic to require sufficient UNXV by oracle valuation.
- P1: Promote all notional/fee/CCR arithmetic to u128 across modules; add input caps to prevent overflow aborts.
- P1: Unify liquidation incentive policy to ensure robust participation for synthetics.
- P2: Add cross-module reconciliation hooks/events for synthetics debt used by lending.

This review is exhaustive per file; implementing the above will materially reduce protocol risk across synthetics, lending, and integrated products.
