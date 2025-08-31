I'll scan the DeepBook and margin_trading source trees to extract how matching and margin work, then draft a precise change plan for our modules.

[5 tools called]

- I looked through DeepBook’s book module and your margin_trading package to align semantics. Here’s a concise, concrete plan.

### What DeepBook does (for reference)
- Taker matches immediately in the same tx; unfilled remainder rests as maker.
- Non‑crossing insertion: resting book always keeps best_bid < best_ask; if an order would cross, it executes as taker now.
- Both sides are escrowed so settlement is same‑tx (no claim step).
- Margin is account/pool‑based; health/liquidation are centralized.

### Changes to make for instant UX everywhere

- Synthetics (`packages/unxversal/sources/synthetics.move`)
  - Enforce non‑crossing insertion (already effectively true via compute_fill_plan + commit).
  - Replace deferred maker claim with instant payout:
    - In taker BUY fills (buyer pays, seller burns): pay seller maker net‑of‑fees directly to maker address during the loop (use `market.maker_addrs[maker_id]`), not to `escrow.pending`. Keep fees routed to Treasury as today.
    - In taker SELL fills (seller receives from bids): keep “prefunded bids” but make it mandatory per market; pay seller taker immediately from the bid’s prefund (we implemented this).
  - Ask-side reserving (optional symmetry): introduce an ask reserve map to prove seller maker has debt units to burn:
    - Add `reserved_burn_units: Table<u128, u64>` to the escrow object.
    - On posting an ask leftover, move units from the maker’s vault debt to `reserved_burn_units[order_id]` (reduces outstanding debt now; on cancel, restore; on match, burn from reserve).
    - Health: verify reserve doesn’t violate min CR (check with current oracle).
  - TIF/IOC/FOK and taker‑only:
    - Add price/time‑in‑force params and a `place_synth_taker_only_with_escrow` (commit with `post_remainder=false`) to guarantee no leftover maker order in flash‑loan PTBs.
  - Governance toggles:
    - Add admin setter to flip `prefund_bids` and (optionally) to require ask reserves per market.
  - Events: swap `MakerClaimed` path for direct payout events and continue emitting matched/trade fee events as now.

- Dex (`packages/unxversal/sources/dex.move`)
  - Already escrowed and instant. Keep:
    - Non‑crossing insertion, taker‑only variants (added), and immediate settlement.
  - Add explicit TIF/IOC/FOK flags (we already have min_price/max_price; add order‑type params to avoid any leftover when needed).

### Margin, leverage, and funding (DeepBook‑style)
- DeepBook‑like margin = central pool + account health + unified liquidation.
- Integrate your `packages/margin_trading`:
  - Introduce a unified `MarginPool`/`PositionManager` as the authority for:
    - Locking/unlocking quote collateral on order post/cancel.
    - Health checks before post/modify.
    - Same‑tx variation margin on fill (perps/futures), fees, and auto‑liquidation.
  - Replace scattered per‑module margin logic with calls into `margin_trading`:
    - Provide adapters in `synthetics`, `perpetuals`, `futures`, and `options` to lock/release funds through the pool.

### Module‑by‑module deltas to be DeepBook‑like

- Synthetics
  - Settlement: direct maker payout on taker BUY; mandatory prefunded bids on SELL; optional ask reserves for symmetry.
  - Kill “claim later” flows where we can; keep bonds/GC for expiry only.
  - Add taker‑only/IOC/FOK; admin setter for `prefund_bids`.

- Dex
  - Keep escrow model (already immediate). Add formal order‑type flags (IOC/FOK/GTD) and explicit non‑crossing guard on insertion (it’s functionally there via book, but make it explicit).

- Options (`packages/unxversal/sources/options.move`)
  - Premium trades already escrow both sides; payout is immediate to writer (net‑of‑fee) and Treasury gets fee. Keep this, but:
    - If you want a CLOB for option premiums, route through `dex.move` (coin‑coin escrow) and remove test‑only OTC matching as the main path.
  - Migrate margin for shorts to `margin_trading` pool so health/liquidation are centralized, with same‑tx fee/payout on match.

- Futures (`packages/unxversal/sources/futures.move`)
  - Today: off‑chain matching + on‑chain record_fill; positions have margin and same‑tx fee flows.
  - If you want on‑chain matching like DeepBook:
    - Add a per‑contract CLOB integration (via `dex.move` or DeepBook proper); use taker placement with immediate settlement; lock variation margin through `margin_trading`.
  - Replace ad‑hoc margin accounting with pool calls (lock/unlock, VM, liquidation), preserving the same‑tx UX.

- Perpetuals (`packages/unxversal/sources/perpetuals.move`)
  - Similar to futures: currently record_fill style. For on‑chain CLOB, integrate with `dex.move` or DeepBook; feed fills into margin pool for VM and funding accrual.
  - Funding and VM should be applied via the central margin pool (positions remain owned objects, but collateral comes from pool).

### Compare/contrast with DeepBook margin
- DeepBook: pure escrow + account/balance bookkeeping; taker settle is always same‑tx; margin and health are centralized.
- Plan here:
  - Synthetics’ “debt ledger” means base is not a transferable token; we solve payout instantaneity by paying coin legs immediately and adjusting debt ledgers per fill (buyer increases, seller decreases).
  - Where a direct maker vault credit needs &mut, pay to maker address instead (wallet credit); optionally expose a maker “payout store” per account if you want custody inside protocol.
  - Centralize collateral locking/health in `margin_trading` to mirror centralized margin.

### Phased rollout
- Phase 1 (low risk):
  - Synthetics: direct maker payout on taker BUY; mandatory prefunded bids on SELL; admin setter for `prefund_bids`; taker‑only entry.
  - Dex: IOC/FOK order‑type flags.
- Phase 2 (margin unification):
  - Wire synthetics/futures/perps/options to `margin_trading` pool: lock/release on post/cancel; VM/liquidation; same‑tx fees.
- Phase 3 (CLOB everywhere):
  - Route options premium, perps, and futures to on‑chain CLOB (Dex or DeepBook); keep record_fill only as a fallback/testing path.

If you want, I can add the admin setter for `prefund_bids` and the synthetics taker‑only entry next, then start the margin pool adapters.