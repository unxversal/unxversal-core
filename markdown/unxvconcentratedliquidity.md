## Unxversal Concentrated Liquidity on the On‑Chain CLOB (Non‑Vault)

This guide explains how to provide “concentrated liquidity” using Unxversal’s on‑chain orderbook without using `vaults.move`. Instead of AMM ranges, you provision liquidity by placing a ladder of limit orders across a price band on the CLOB. This works for both the DEX and Synthetics modules under the escrow‑only settlement model.

### Why a CLOB instead of a CLMM?

- **Exact price control**: You quote specific tick‑aligned prices and sizes, not a curve.
- **No impermanent loss math**: You hold inventory; fills happen at your chosen prices.
- **Composable**: Quotes are regular orders stored and matched fully on‑chain; bots only trigger matching and GC.

### Escrow‑only: what it means

- When you place a quote, you escrow assets for the unfilled remainder and post a small maker bond.
- Takers are settled immediately from escrow; your maker proceeds accumulate in `escrow.accrual_*` until you claim.
- You claim proceeds with a dedicated entry and receive coins to your wallet; you can then redeploy or withdraw.

## Strategy: “Range LP” via order ladders

Providing liquidity over a range is done by placing a grid of resting limit orders between `p_min` and `p_max`.

- **Inputs**
  - **side**: buy (bids) or sell (asks)
  - **p_min / p_max**: inclusive price band
  - **step_ticks**: gap in ticks between ladder levels
  - **total_size**: total base exposure to distribute across levels
  - **weighting**: uniform, geometric, or custom function of distance to mid
  - **expiry_ms**: per‑order expiry to force refresh cadence

- **Book constraints**
  - `tick_size`, `lot_size`, `min_size` come from the on‑chain book; every order must align to them.
  - Round price to the nearest tick; round size to a multiple of lot size and ≥ min size.

- **Order lifecycle**
  - Place ladder ➜ fills accrue ➜ claim proceeds periodically ➜ refresh/roll orders on expiry or when price drifts.

## DEX flow (coins vs coins)

- **Place**
  - Bid: `Dex::place_dex_limit_with_escrow_bid<Base, C>(cfg, market, escrow, price, size_base, expiry_ms, &mut taker_collateral, ctx)`
  - Ask: `Dex::place_dex_limit_with_escrow_ask<Base, C>(cfg, market, escrow, price, size_base, expiry_ms, &mut taker_base, ctx)`
  - You can call these repeatedly to create a ladder.

- **Claim**
  - Maker proceeds accrue in `escrow.accrual_base` (for asks) and `escrow.accrual_collateral` (for bids).
  - Call `Dex::claim_dex_maker_fills(market, escrow, order_id, ctx)` to receive coins to your wallet.

- **Cancel**
  - `Dex::cancel_dex_clob_with_escrow(market, escrow, order_id, ctx)` refunds your pending escrow and bond.

## Synthetics flow (coins vs synthetic units)

- **Place**
  - `Synthetics::place_synth_limit_with_escrow<C>(registry, market, escrow, side, price, size_units, expiry_ms, maker_vault, ctx)`
  - Same ladder concept; prices are in collateral per synth unit.

- **Claim**
  - Call `Synthetics::claim_maker_fills(market, escrow, order_id, maker_vault, ctx)` to move proceeds into the maker vault and release bond when fully done.

- **Cancel**
  - `Synthetics::cancel_synth_clob_with_escrow(market, escrow, order_id, maker_vault, ctx)` returns bond/escrow.

## Keepers and liveness

- **match_step_auto**: Advances best levels atomically; anyone can call, small caller reward is configured.
- **gc_step**: Removes expired orders and slashes bonds; fraction goes to caller; remainder to treasury.
- Neither function needs off‑chain order storage; they operate on the on‑chain book.

## Risk management and operations

- **Inventory drift**: Filled bids increase base inventory; filled asks increase collateral. Rebalance policy is needed.
- **Range maintenance**: As price moves, cancel stale far‑off orders; re‑place around the new mid.
- **Expiry discipline**: Use expiries to keep quotes fresh and to enable GC of stale orders.
- **Bond sizing**: `maker_bond_bps` is small but non‑zero; ensure wallets hold enough collateral to post bonds.

## Bot architecture (off‑chain) for range placement

Below are clean TypeScript interfaces you can use in a CLI/server/bot to implement a laddered strategy. These operate without custody — they just construct and send PTBs that call the on‑chain entries.

```ts
export type Side = 'bid' | 'ask';

export interface RangeStrategyConfig {
  marketId: string;          // on-chain market object ID
  escrowId: string;          // on-chain escrow object ID
  side: Side;
  pMin: bigint;              // u64 price in quote per 1 base, as bigint
  pMax: bigint;
  stepTicks: bigint;         // integer number of ticks between quotes
  totalBase: bigint;         // total base exposure to distribute (lot-aligned)
  weighting: 'uniform' | 'geometric' | 'custom';
  weightK?: number;          // parameter for geometric weighting
  expiryMs: bigint;          // per-order expiry
  maxLevels?: number;        // cap ladder size
}

export interface BookParams {
  tickSize: bigint;  // from on-chain book
  lotSize: bigint;
  minSize: bigint;
}

export interface OrderIntent {
  price: bigint;
  sizeBase: bigint;
  expiryMs: bigint;
}

export interface ExchangeClient {
  fetchBookParams(marketId: string): Promise<BookParams>;
  placeDexBid(intent: OrderIntent): Promise<string>; // returns order_id
  placeDexAsk(intent: OrderIntent): Promise<string>;
  claimDex(orderId: string): Promise<void>;
  cancelDex(orderId: string): Promise<void>;
}

export interface LadderPlanner {
  plan(config: RangeStrategyConfig, book: BookParams, midPrice?: bigint): OrderIntent[];
}

export interface LpBot {
  start(config: RangeStrategyConfig): Promise<void>;
  refresh(): Promise<void>;         // roll expiries / cancel & re-place around mid
  claimAll(): Promise<void>;        // claim accrued maker proceeds
  stop(): Promise<void>;
}
```

Planning logic (sketch):

```ts
function alignToTick(p: bigint, tick: bigint): bigint {
  return (p / tick) * tick; // floor to tick
}

function alignSize(sz: bigint, lot: bigint, min: bigint): bigint {
  const aligned = (sz / lot) * lot;
  return aligned < min ? min : aligned;
}

function planUniform(config: RangeStrategyConfig, book: BookParams): OrderIntent[] {
  const { pMin, pMax, stepTicks, totalBase, expiryMs } = config;
  const levelTick = book.tickSize * stepTicks;
  const intents: OrderIntent[] = [];
  let p = alignToTick(pMin, book.tickSize);
  const nLevels = Number((pMax - pMin) / levelTick) + 1;
  const perLevel = alignSize(totalBase / BigInt(nLevels), book.lotSize, book.minSize);
  for (let i = 0; p <= pMax; i++, p += levelTick) {
    intents.push({ price: p, sizeBase: perLevel, expiryMs });
  }
  return intents;
}
```

## Suggested API (if you wrap in a server for a frontend)

- **POST** `/lp/range/start` — body: `RangeStrategyConfig`; returns created order_ids
- **POST** `/lp/range/stop` — cancels managed orders in the range
- **POST** `/lp/range/refresh` — rolls expiries and recenters
- **POST** `/lp/claim` — claims accrued maker proceeds for a list of order_ids
- **GET** `/lp/status` — returns active orders, accruals, pending, bonds, PnL summary

## Examples

- USDC/BASE market with `tick_size = 10`, `lot_size = 1`, `min_size = 1`
  - Plan bids from 10,000 to 10,500 with `step_ticks = 5`
  - Total base = 1,000 units → 100 units across 10 levels
  - Place via repeated `place_dex_limit_with_escrow_bid`

## Security and permissions

- Orders and claims are on‑chain; the bot only automates entry calls.
- Keep wallet collateral for bonds and refresh costs.
- Never expose private keys in UIs; use local signers or wallet adapters.

## Future enhancements

- Single‑call “claim into vault” helper by adjusting Dex claim to return coins to a provided store.
- Built‑in range helpers on‑chain for vaults (pre‑approved manager only), with order tracking in `active_orders`.
- Auto‑hedging or inventory targeting strategies that react to fills.


