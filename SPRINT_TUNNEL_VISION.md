## UNXVERSAL: Straight‑Shot Plan to Production Robustness (Sprint Tunnel Vision)

This plan enumerates concrete, ordered tasks to bring the protocol to production‑grade robustness. Follow the dependency order requested: `unxv` → `oracle` → `treasury` → `synthetics` → `lending` → `options` → `futures` → `gas_futures` → `perpetuals` → `vaults`. Each section lists: must‑fix items (P0), hardening (P1), and acceptance checks.

### Cross‑cutting (do first)
- **Oracle allow‑list + bindings (P0)**: Implement symbol → aggregator ID registry and enforce across all modules. Replace arbitrary `Aggregator` params with bound lookups or bound verifiers. Add staleness guard via `oracle::max_age_sec`.
- **Arithmetic safety (P0→P1)**: Promote all notional/fee/ratio math to u128 with safe clamps before converting to u64. Add input caps (tick, size, notional) to prevent abort‑on‑overflow DoS.
- **Admin centralization (P0)**: Gate all admin operations via `synthetics::SynthRegistry` (AdminCap/DaddyCap) as the single source of truth; remove per‑module bespoke admin caps where feasible (or bridge them to synth registry checks).
- **Time source normalization (P0)**: Use `sui::clock::Clock` `timestamp_ms(clock)` in entry paths/events instead of `sui::tx_context::epoch_timestamp_ms` to standardize time semantics, per project preference.
- **UNXV discount parity (P0)**: Standardize UNXV fee‑discount flow: fetch UNXV/USD via bound oracle; compute `unxv_needed = ceil(discount_usd / px_unxv)`; require and escrow it; refund leftovers. Apply uniformly across DEX, options, futures, gas_futures, perps.
- **Bot reward policy (P1)**: Harmonize bot reward bps and routing across products; document invariants.

### 1) `unxv.move`
- **P0**: None. Confirm SupplyCap holder operational processes and event coverage.
- **P1**: Add Display metadata if missing icons/links. Ensure burn/mint events include reason/context.
- **Acceptance**: Cap enforced; mint/burn events present; no u64 overflows.

### 2) `oracle.move`
- **P0**:
  - Implement `OracleRegistry` shared object: `symbol: String → aggregator_id: ID` map, `max_age_sec` config.
  - Add `set_feed(symbol, aggregator)` admin path (gated via SynthRegistry).
  - Provide `price_for_symbol(clock, symbol)` that fetches aggregator by ID, verifies staleness, returns micro‑USD u64.
- **P1**: Optional Display; add deviation checks hooks (EMA) for later.
- **Acceptance**: All downstream modules depend on this API; unit tests use bounded staleness.

### 3) `treasury.move`
- **P0**: None critical. Keep as central fee sink with admin‑gated withdrawals.
- **P1**: Add optional rate‑limit controls; unify bot reward routing helpers.
- **Acceptance**: Deposits from all modules succeed; UNXV burn path via SupplyCap works.

### 4) `synthetics.move`
- **P0**:
  - Ensure all single‑asset paths call oracle‑bound price helpers.
  - For multi‑asset flows that use `PriceSet`, enforce that `PriceSet` is constructed via module helper that binds aggregator IDs and timestamps; validate within entry to reject foreign/forged `PriceSet` (symbol exist, feed match, staleness within `max_age_sec`). If this cannot be enforced cleanly, deprecate multi‑asset entrypoints and migrate to single‑asset loops.
  - Promote CCR, fee, and liquidation math to u128.
  - Align events to `Clock` timestamps.
- **P1**: Revisit liquidation incentive split vs treasury; add reconciliation hooks/events for integration with lending (expose per‑vault debt/CCR deltas).
- **Acceptance**: Mint/burn/liquidate cannot proceed with spoofed prices; no overflows; consistent events.

### 5) `lending.move`
- **P0**:
  - Replace caller‑supplied `symbols`/`prices` vectors in LTV/health/liquidation with oracle‑bound price reads per asset, or require a verified `PriceSet` built via oracle module and validate it internally.
  - Fix liquidation math to convert scaled balances to units for comparisons; write back scaled via index helpers.
  - Restrict `accrue_synth_market`: gate via admin/bot; derive `dt` from on‑chain time; store last accrual in market state.
  - Centralize admin via SynthRegistry; deprecate bespoke `LendingAdminCap` if possible, or enforce `assert_is_admin_via_synth` wrapper.
- **P1**: Migrate all u64 notional math to u128; add per‑asset caps; standardize events to `Clock`.
- **Acceptance**: Health checks immune to spoofed inputs; liquidation math correct; accrual unexploitable.

### 6) `options.move`
- **P0**:
  - Fix creation‑fee UNXV discount: require sufficient UNXV by oracle valuation before applying discount; refund leftovers.
  - Bind settlement/exercise aggregators to stored per‑underlying feed identity; validate on call.
  - Promote payouts/fees to u128.
- **P1**: Evaluate physical settlement orchestration hooks; ensure bot reward consistency.
- **Acceptance**: No free discounts; settlement/exercise reject wrong feeds; no overflow aborts.

### 7) `futures.move`
- **P0**:
  - Keep good practice: settlement already binds feed by object ID. Extend binding to any price‑dependent admin ops.
  - Standardize UNXV discount flow and u128 math in `record_fill` and fee routing.
- **P1**: Add input caps and consistent bot reward policy.
- **Acceptance**: Trades/settlement safe from overflow; discounts priced correctly.

### 8) `gas_futures.move`
- **P0**:
  - Bind SUI/USD and UNXV/USD aggregator IDs in registry; reject arbitrary aggregators.
  - Migrate notional/fees to u128; standardize discount flow.
- **P1**: Confirm RGP×SUI math bounds; document units rigorously.
- **Acceptance**: Fills/settlement safe; discounts correct; unit math documented.

### 9) `perpetuals.move`
- **P0**:
  - Bind index price to oracle: replace caller‑supplied index price with oracle fetch; pass symbol or market→feed binding.
  - Standardize discount flow and u128 math.
- **P1**: Funding computation caps already present; ensure direction and cap logic tested under bounds.
- **Acceptance**: Funding cannot be skewed by callers; fills safe; events consistent.

### 10) `vaults.move`
- **P0**:
  - Promote `need = per * p` and similar notional math to u128; pre‑check against u64 max before splitting balances.
  - Ensure all manager actions check stake registry; they do—add unit tests.
- **P1**: Add optional vault risk limits (per‑order cash buffer enforcement already present).
- **Acceptance**: Range ladder cannot overflow; manager gating enforced.

### Deliverables & sequencing
- Week 1: Oracle allow‑list + bindings; discount parity implementation; time‑source normalization; arithmetic upgrade skeleton and helper library.
- Week 2: Synthetics enforcement on `PriceSet` and multi‑asset decision; Lending health/liquidation refactor + accrual gating + admin centralization.
- Week 3: Options creation‑fee fix + settlement binding; Futures/Gas/Perps discount and math upgrades; bot reward policy harmonization.
- Week 4: Vaults math hardening; cross‑module event/schema polish; documentation and operational runbooks.

### Acceptance checklist (must all be green)
- All price reads are oracle‑bound (symbol→aggregator ID) with staleness checks.
- All notional/fee/ratio arithmetic uses u128 intermediates with clamps and input caps.
- Single admin list enforced via SynthRegistry across modules.
- UNXV discount flow consistent and priced by oracle everywhere.
- Time source standardized on `sui::clock::Clock` in entry paths/events.
- Liquidations/settlements cannot be triggered or blocked by user‑supplied price vectors.
- No linter warnings introduced; builds clean; on‑chain invariants documented.
