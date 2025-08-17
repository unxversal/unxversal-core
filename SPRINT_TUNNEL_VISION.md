## UNXVERSAL: Straight‑Shot Plan to Production Robustness (Sprint Tunnel Vision)

This plan enumerates concrete, ordered tasks to bring the protocol to production‑grade robustness. Follow the dependency order requested: `unxv` → `oracle` → `treasury` → `synthetics` → `lending` → `options` → `futures` → `gas_futures` → `perpetuals` → `vaults`. Each section lists: must‑fix items (P0), hardening (P1), and acceptance checks.

### Cross‑cutting (do first)
- **Oracle allow‑list + bindings (P0)**: Implement symbol → aggregator ID registry and enforce across all modules. Replace arbitrary `Aggregator` params with bound lookups or bound verifiers. Add staleness guard via `oracle::max_age_sec`.
- **Arithmetic safety (P0→P1)**: Promote all notional/fee/ratio math to u128 with safe clamps before converting to u64. Add input caps (tick, size, notional) to prevent abort‑on‑overflow DoS.
- **Admin centralization (P0)**: Introduce `unxversal::admin::AdminRegistry` as the single source of truth for admin addresses. Gate all admin entry functions across modules via this registry and remove/bypass bespoke caps (bridge where unavoidable). For `synthetics`, migrate from `DaddyCap/AdminCap + admin_addrs` to authoritative checks via `AdminRegistry` (preserve caps for UX/backcompat and mirror sets until fully deprecated).
- **Time source normalization (P0)**: Use `sui::clock::Clock` `timestamp_ms(clock)` in entry paths/events instead of `sui::tx_context::epoch_timestamp_ms` to standardize time semantics, per project preference.
- **UNXV discount parity (P0)**: Standardize UNXV fee‑discount flow: fetch UNXV/USD via bound oracle; compute `unxv_needed = ceil(discount_usd / px_unxv)`; require and escrow it; refund leftovers. Apply uniformly across DEX, options, futures, gas_futures, perps.
- **Bot rewards treasury + points system (P1)**: Add a dedicated `BotRewardsTreasury` shared object and a `BotPointsRegistry` that maps protocol function keys (e.g., list_market, refresh_funding) to point weights. Monthly, distribute the bot rewards treasury pro‑rata to addresses by points earned. Treasury gains a config to auto‑transfer X% of every fee it receives into the bot rewards treasury. Immediate split flows (e.g., liquidations) continue to pay out instantly; the points system covers non‑fee or delayed‑fee tasks.

#### Bot Rewards Treasury + Points System — Detailed design (P1)

- Purpose
  - Immediate‑reward functions (e.g., liquidations) keep paying out directly at call time and may also emit points.
  - Non‑fee tasks (e.g., rate/accrual updates, listings, risk scans) earn points; bots claim a monthly share of a dedicated rewards treasury based on points share.

- Core objects and configs
  - `BotRewardsTreasury` (shared object): holds funds earmarked for monthly pro‑rata distribution to bots.
  - `BotPointsRegistry` (shared object):
    - Stores a registry of protocol function keys → point weights (u64), admin‑configurable.
    - Tracks per‑address accumulated points per epoch/month window.
    - Emits canonical events on point awards and on distributions.
  - `Treasury` integration:
    - Add `auto_bot_rewards_bps` config. On every deposit into `Treasury`, automatically route that percentage to `BotRewardsTreasury` and retain the remainder.
    - Must be idempotent, with conservation checks (retained + routed + immediate split == input deposit).

- Awarding points
  - Each protocol function that is “bot‑callable” defines a stable function key string (e.g., `lending.update_pool_rates`, `lending.accrue_pool_interest`, `synthetics.init_synth_market`).
  - On successful execution, emit a standardized `BotPointsAwarded { task, points, actor, timestamp }` event AND call `BotPointsRegistry::award_points(actor, task_key)` which looks up `task_key` weight and accrues to `actor`.
  - Admins manage weights centrally in `BotPointsRegistry` (set, update, disable).

- Epoch‑based, bot‑initiated claims (no batch distributor)
  - Admin sets epoch schedule once: `epoch_zero_ms` (origin) and `epoch_duration_ms` (e.g., 30d). Current epoch = floor((now - zero)/duration).
  - Points are tracked per epoch: `points_by_epoch[epoch][actor]` and `total_points_by_epoch[epoch]` inside `BotPointsRegistry`.
  - Treasury funds reserved per epoch: `epoch_collateral[epoch]` and `epoch_unxv` inside `BotRewardsTreasury`.
  - Any bot can call `claim_rewards_for_epoch(epoch)` for itself, but only for a closed epoch (`epoch < current_epoch`). Claim pays pro‑rata from the epoch’s reserved funds, zeros the actor’s epoch points, and decrements the epoch reserve.
  - Rounding leaves dust; a small “sweep epoch dust” admin tool may move leftovers after a grace period.

- Per‑protocol split configs (immediate rewards)
  - Functions that already collect fees/notional at call time (e.g., `lending.liquidate_coin_position`, `synthetics.liquidate_vault`) maintain their own per‑function split configs (direct bot payout share vs treasury share). These do NOT rely on `BotRewardsTreasury` but may still award points.
  - Non‑fee tasks rely on monthly rewards via points.

- **Synthetics downstream reconciliation (P0)**: Define canonical, stable events for `mint_synthetic`, `burn_synthetic`, and `liquidate_vault` (per‑symbol amounts, vault id, payer/liquidator). Provide read‑only helpers for current vault debt/collateral values. Document and implement consumption paths in lending/options/futures/perps (bots/indexers) so cross‑protocol health, margin, or exposure is reconciled after synth liquidations.

### 1) `unxv.move` ✅
- **P0**: None. Confirm SupplyCap holder operational processes and event coverage.
- **P1**: Add Display metadata if missing icons/links. Ensure burn/mint events include reason/context.
- **Acceptance**: Cap enforced; mint/burn events present; no u64 overflows.

### 2) `oracle.move` ✅
- **P0**:
  - Implement `OracleRegistry` shared object: `symbol: String → aggregator_id: ID` map, `max_age_sec` config.
  - Add `set_feed(symbol, aggregator)` admin path (gated via `unxversal::admin::AdminRegistry`).
  - Provide `price_for_symbol(clock, symbol)` that fetches aggregator by ID, verifies staleness, returns micro‑USD u64.
- **P1**: Optional Display; add deviation checks hooks (EMA) for later. Also emit standardized bot‑task events to award points (e.g., feed maintenance tasks) into the central points registry.
- **Acceptance**: All downstream modules depend on this API; unit tests use bounded staleness; bot‑task events integrate with points registry.

### 3) `treasury.move` ✅
- **P0**: None critical. Keep as central fee sink with admin‑gated withdrawals.
- **P1**: Add optional rate‑limit controls; unify bot reward routing helpers. Add `auto_bot_rewards_bps` to divert a percentage of all incoming fees to `BotRewardsTreasury`. Expose settlement function to distribute pro‑rata by points each epoch/month.
- **Acceptance**: Deposits from all modules succeed; UNXV burn path via SupplyCap works; auto_bot_rewards_bps routes funds; monthly pro‑rata distribution from BotRewardsTreasury is deterministic and idempotent.

Implementation notes:
- Add `auto_bot_rewards_bps` config to `Treasury` and route on every deposit.
- Add per‑epoch reserves in `BotRewardsTreasury<C>`: `epoch_collateral: Table<u64,u64>`, `epoch_unxv: Table<u64,u64>`.
- Add deposit variants that take `epoch_id`: `deposit_collateral_with_rewards_for_epoch`, `deposit_unxv_with_rewards_for_epoch` that split into bot share and increment epoch reserves.
- Conservation: bot share + retained + (optional burn) equals input; epoch sums must be ≤ bot treasury balances.

### 4) `synthetics.move` ✅
- **P0**:
  - Ensure all single‑asset paths call oracle‑bound price helpers.
  - For multi‑asset flows that use `PriceSet`, enforce that `PriceSet` is constructed via module helper that binds aggregator IDs and timestamps; validate within entry to reject foreign/forged `PriceSet` (symbol exist, feed match, staleness within `max_age_sec`). If this cannot be enforced cleanly, deprecate multi‑asset entrypoints and migrate to single‑asset loops.
  - Promote CCR, fee, and liquidation math to u128.
  - Align events to `Clock` timestamps.
-  Emit canonical events for mint/burn/liquidation with per‑symbol amounts and participants; provide reconciliation helpers for downstream consumers.
- **P1**: Revisit liquidation incentive split vs treasury; add reconciliation hooks/events for integration with lending (expose per‑vault debt/CCR deltas). Add per‑function bot split config and points‑awarding hooks, integrated with `BotRewardsTreasury` (immediate split where applicable; points for non‑fee tasks like risk scans).
  - Migrate admin gating to `unxversal::admin::AdminRegistry` (authoritative). Keep `AdminCap/DaddyCap` for UX only and add a thin bridge to mirror `AdminRegistry` updates into `SynthRegistry.admin_addrs` until callers are updated.
- **Acceptance**: Mint/burn/liquidate cannot proceed with spoofed prices; no overflows; canonical events emitted with per‑symbol amounts; reconciliation helpers available; bot split config present; points emitted for non‑fee tasks.

Implementation notes:
- Maintain immediate split logic (liquidations, maker rebates). Add per‑function split config knobs.
- Emit `BotPointsAwarded` and call into `BotPointsRegistry::award_points` (now requires `ctx`) for non‑fee tasks (listing, accrual).
- For fee deposits contributing to bot rewards, use epoch‑aware deposit variants with `epoch_id = BotRewards::current_epoch(clock, points_registry)`.
- Provide reconciliation events/helpers to downstream modules.

### 5) `lending.move` ✅
- **P0**:
  - Replace caller‑supplied `symbols`/`prices` vectors in LTV/health/liquidation with oracle‑bound price reads per asset, or require a verified `PriceSet` built via oracle module and validate it internally.
  - Fix liquidation math to convert scaled balances to units for comparisons; write back scaled via index helpers.
  - Restrict `accrue_synth_market`: gate via admin/bot; derive `dt` from on‑chain time; store last accrual in market state.
  - Centralize admin via `unxversal::admin::AdminRegistry`; deprecate bespoke `LendingAdminCap` if possible, or add a thin adapter that checks `AdminRegistry`.
- **P1**: Migrate all u64 notional math to u128; add per‑asset caps; standardize events to `Clock`. Add bot split config and points awarding for maintenance tasks (e.g., accrual, rate updates, health scanning), wired into `BotRewardsTreasury`. Implement/read reconciliation path that re‑evaluates account health when synthetics emits mint/burn/liquidation events. Per‑tx input caps added; liquidation bonus can auto‑route treasury share via `liq_bot_treasury_bps`.
- **Acceptance**: Health checks immune to spoofed inputs; liquidation math correct; accrual unexploitable; reacts to synthetics events for health recomputation; bot split config present; points emitted for maintenance tasks; admin gating via `unxversal::admin::AdminRegistry` in all admin paths.

Implementation notes:
- Keep immediate split logic for liquidations; add per‑function split configs.
- Award points on non‑fee tasks (e.g., `update_pool_rates`, `accrue_pool_interest`, health scans) and call `BotPointsRegistry::award_points` (now requires `ctx`).
- For fee deposits into treasury that should fund bot rewards, call epoch‑aware deposit variant with `epoch_id`.
- Use `PriceSet` for secure on‑chain price validation.

### 6) `options.move`
- **P0**:
  - Fix creation‑fee UNXV discount: require sufficient UNXV by oracle valuation before applying discount; refund leftovers.
  - Bind settlement/exercise aggregators to stored per‑underlying feed identity; validate on call.
  - Centralize admin via `unxversal::admin::AdminRegistry` (replace Synth‑admin checks).
  - Promote payouts/fees to u128.
- **P1**: Evaluate physical settlement orchestration hooks; ensure bot reward consistency. Add bot split config and points for non‑fee tasks (e.g., market listing/orchestration), with treasury auto‑allocation in place. Reconcile or restrict use of synthetics as collateral/underlying with clear behavior on synth liquidation (e.g., indexer‑driven closes or margin checks).
- **Acceptance**: No free discounts; settlement/exercise reject wrong feeds; no overflow aborts; synthetics‑downstream behavior documented and implemented; bot split config present; points emitted for non‑fee tasks.

Implementation notes:
- Enforce UNXV discount pricing; add per‑function split configs where fees are collected.
- Emit bot points for non‑fee orchestration tasks (e.g., listings); integrate with `BotPointsRegistry`.

### 7) `futures.move`
- **P0**:
  - Keep good practice: settlement already binds feed by object ID. Extend binding to any price‑dependent admin ops.
  - Centralize admin via `unxversal::admin::AdminRegistry`.
  - Standardize UNXV discount flow and u128 math in `record_fill` and fee routing.
- **P1**: Add input caps and consistent bot reward policy. Add per‑function bot split config and points hooks (e.g., queue processing, settlement requests) integrated with bot rewards treasury. If a futures market references a synthetic underlying, document and implement reconciliation of funding/mark/reference on synth liquidation events.
- **Acceptance**: Trades/settlement safe from overflow; discounts priced correctly; reacts to synthetics events where applicable; bot split config present; points emitted for non‑fee tasks.

Implementation notes:
- Bind fee routing and per‑function split configs; standardize discount math.
- Emit points for maintenance tasks (e.g., funding refresh) and integrate with `BotPointsRegistry`.

### 8) `gas_futures.move`
- **P0**:
  - Bind SUI/USD and UNXV/USD aggregator IDs in registry; reject arbitrary aggregators.
  - Centralize admin via `unxversal::admin::AdminRegistry`.
  - Migrate notional/fees to u128; standardize discount flow.
- **P1**: Confirm RGP×SUI math bounds; document units rigorously. Add bot split config and points hooks (e.g., gas settlement queue processing, listings) with rewards treasury integration. N/A for synth downstream unless gas products reference synths; if they do, align reconciliation similar to futures.
- **Acceptance**: Fills/settlement safe; discounts correct; unit math documented; (if applicable) synth reconciliation paths documented; bot split config present; points emitted for non‑fee tasks.

Implementation notes:
- Bind SUI/UNXV oracle feeds and admin centralization.
- Add split configs for fee paths; emit points for non‑fee tasks (e.g., settlement queue upkeep).

### 9) `perpetuals.move`
- **P0**:
  - Bind index price to oracle: replace caller‑supplied index price with oracle fetch; pass symbol or market→feed binding.
  - Standardize discount flow and u128 math.
  - Centralize admin via `unxversal::admin::AdminRegistry`.
- **P1**: Funding computation caps already present; ensure direction and cap logic tested under bounds. Add bot split config and points hooks (e.g., funding refresh, risk checks) tied to rewards treasury. If perps reference synth index prices, ensure indexer/bot applies reconciliation on synth liquidation to avoid stale risk.
- **Acceptance**: Funding cannot be skewed by callers; fills safe; events consistent; (if applicable) synth reconciliation implemented; bot split config present; points emitted for non‑fee tasks.

Implementation notes:
- Bind index price to oracle; add split configs for any fee‑collecting tasks.
- Emit points for non‑fee tasks (funding refresh, risk checks); integrate with `BotPointsRegistry`.

### 10) `vaults.move`
- **P0**:
  - Promote `need = per * p` and similar notional math to u128; pre‑check against u64 max before splitting balances.
  - Ensure all manager actions check stake registry; they do—add unit tests.
- **P1**: Add optional vault risk limits (per‑order cash buffer enforcement already present). Add bot split config and points hooks for non‑fee tasks (e.g., range ladder upkeep), with rewards treasury integration.
- **Acceptance**: Range ladder cannot overflow; manager gating enforced; bot split config present; points emitted for non‑fee tasks.

Implementation notes:
- Promote notional math to u128; enforce manager/stake constraints.
- Emit points for non‑fee maintenance tasks (e.g., ladder upkeep); integrate with `BotPointsRegistry`.

### Deliverables & sequencing
- Week 1: Oracle allow‑list + bindings; discount parity implementation; time‑source normalization; arithmetic upgrade skeleton and helper library.
- Week 2: Synthetics enforcement on `PriceSet` and multi‑asset decision; Lending health/liquidation refactor + accrual gating + admin centralization.
- Week 3: Options creation‑fee fix + settlement binding; Futures/Gas/Perps discount and math upgrades; bot reward policy harmonization; epoch‑based rewards plumbing (per‑epoch reserves and claims).
- Week 4: Vaults math hardening; cross‑module event/schema polish; documentation and operational runbooks.

### Acceptance checklist (must all be green)
- All price reads are oracle‑bound (symbol→aggregator ID) with staleness checks.
- All notional/fee/ratio arithmetic uses u128 intermediates with clamps and input caps.
- Single admin list enforced via `unxversal::admin::AdminRegistry` across modules (until all migrations are complete, bridges may mirror AdminRegistry into legacy allow‑lists).
- UNXV discount flow consistent and priced by oracle everywhere.
- Time source standardized on `sui::clock::Clock` in entry paths/events.
- Liquidations/settlements cannot be triggered or blocked by user‑supplied price vectors.
- BotRewardsTreasury deployed and funded via `auto_bot_rewards_bps`; epoch‑based pro‑rata claim is deterministic, idempotent per actor/epoch, and evented.
- BotPointsRegistry exists with admin‑configurable point weights per task; points tracked per epoch; non‑immediate tasks emit points; immediate‑reward functions have per‑protocol split configs.
- Treasury fee conservation holds per deposit: immediate splits + auto bot transfer + retained equals fees in.
- Events exist for points accrual and distributions; indexable for off‑chain accounting.
- Synthetics emits canonical mint/burn/liquidation events; downstream modules (lending/options/futures/perps) have documented reconciliation paths and tests to validate state consistency after synth liquidation.
- No linter warnings introduced; builds clean; on‑chain invariants documented.
