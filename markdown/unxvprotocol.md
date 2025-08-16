## Unxversal Protocol – Architecture and Module Guide

Unxversal is a modular on-chain trading protocol on Sui built around shared objects and minimal custody leakage. Protocol governance is centralized through the `unxversal::synthetics::SynthRegistry` which provides the authoritative admin allow-list for all Unxversal products.

### Design Principles
- Minimal custodial leakage: shared order/vault objects always return funds to the caller-provided stores.
- Explicit authority: admin gating across modules is enforced by checking `SynthRegistry` allow-list.
- Oracle sanity: prices normalized to micro-USD via Switchboard aggregators through the `oracle` module.
- Fee clarity: all fees route to `treasury` with optional UNXV-based discounts and maker rebates.
- Bot-driven execution: permissionless on-chain objects, with off-chain matchers, listers, liquidators, and settlement processors.

### Core On-chain Modules
- `synthetics.move`: Registry, admin allow-list, collateralized `CollateralVault<C>`, synthetic asset listing, mint/burn, stability accrual, liquidation, and a synth orderbook (`Order`).
- `dex.move`: Escrowed coin orderbook and vault-safe order variants for `LiquidityVault`, with taker fees, UNXV discounts, and maker rebates.
- `options.move`: Options registry and markets, OTC matching objects, margin, and cash/physical settlement flows.
- `futures.move`: Dated futures registry and contracts, open/close/settlement events, fee accounting hooks.
- `gas_futures.move`: Gas-price based futures with RGP×SUI micro-USD pricing and position management.
- `perpetuals.move`: Perpetuals with funding index and per-position accrual; off-chain bot refreshes funding rates.
- `vaults.move`: Vaults for liquidity provisioning and asset management:
  - `LiquidityVault<Base, C>` integrates with `dex` for base/quote markets.
  - Synth LP wrappers integrate with `synthetics` order/matching.
  - `TraderVault<C>`: collateral-only share vault with HWM performance fees and manager stake gating.

### Cross-cutting Modules
- `oracle.move`: Provides normalized micro-USD price retrieval with staleness gating (Switchboard aggregators).
- `treasury.move`: Universal sink for fees and losses; supports both collateral and UNXV intake.
- `unxv.move`: UNXV token type and discount conventions.

---

## End-to-end Architecture

### On-chain
- Shared objects: orders, offers, positions, vaults, configs. These enable permissionless participation and bot orchestration.
- Events: all modules emit rich events for indexers and the off-chain runner to ingest. Examples: `CoinOrderPlaced`, `OrderMatched`, `SyntheticMinted`, `FuturesTrade`, `GasFillRecorded`, `OptionMatched`, `LiquidationExecuted`, etc.
- Invariants: authority via `SynthRegistry`, price scaling via `oracle`, fee routing to `treasury`.

### Off-chain (CLI server + API + bots)
The Unxversal node is a single process that embeds:
- HTTP API server exposing read-only and transaction-building endpoints.
- Bot runners (pluggable) for market listing, order matching, liquidation, settlement, GC, and display registration.
- A local indexer that subscribes to events and shared-object updates via Sui RPC/websocket.

Recommended package layout (TypeScript):
- `@unxversal/node` (CLI entry): starts API server and bot supervisor.
- `@unxversal/sdk` (TS client SDK): Move call wrappers, types, and builders.
- `@unxversal/bots` (bot implementations): composable classes with idempotent loops.

### Frontend UX
- Connect wallet → discover shared objects via registry endpoints.
- Guided flows for creating and managing orders/vaults/positions.
- Opt-in bot orchestration: surfaces pending actions (e.g., cancel expired orders, pay fees) and one-click triggers.

---

## HTTP API (proposed)

Base URL: `/api/v1`

- Health & config
  - `GET /health`
  - `GET /config/runtime` → aggregates trade/settlement params per product

- Registry and listings
  - `GET /synthetics/assets` → list assets and params from `SynthRegistry`
  - `GET /dex/config/:id` → current DEX config
  - `GET /options/underlyings` → from `OptionsRegistry`
  - `GET /futures/contracts` → from `FuturesRegistry`
  - `GET /gas/contracts` → from `GasFuturesRegistry`

- Orders (DEX)
  - `GET /dex/orders/:id` → resolve order details
  - `POST /dex/place` → build tx for `place_*_order` (coin or vault-safe)
  - `POST /dex/cancel` → build tx for cancel functions
  - `POST /dex/match` → build tx for `match_*`

- Synth Vaults and Orders
  - `GET /synth/vault/:id` → balances/debts
  - `POST /synth/vault/create` → `create_vault<C>`
  - `POST /synth/mint` / `POST /synth/burn`
  - `POST /synth/order/place` → `place_limit_order`
  - `POST /synth/order/cancel` → `cancel_order`
  - `POST /synth/order/match` → `match_orders`

- Options
  - `GET /options/markets`
  - `POST /options/market/create`
  - `POST /options/offer/place` / `POST /options/escrow/place`
  - `POST /options/match`
  - `POST /options/settle`

- Futures / Gas Futures
  - `GET /futures/contracts` / `GET /gas/contracts`
  - `POST /futures/settle` / `POST /gas/settle`
  - `POST /futures/recordFill` / `POST /gas/recordFill`
  - `POST /futures/position/open|close` / `POST /gas/position/open|close`

- Vaults (Liquidity & Trader)
  - `POST /vaults/liquidity/create`
  - `POST /vaults/liquidity/deposit|withdraw`
  - `POST /vaults/liquidity/dex/place|cancel|match`
  - `POST /vaults/liquidity/synth/place|cancel|match`
  - `POST /vaults/trader/create|deposit|withdraw|stake|unstake|fees`

All POST endpoints accept JSON inputs and return a serialized transaction (e.g., BCS or base64) ready for wallet signing, plus dry-run gas estimates.

---

## TS SDK Sketch

Namespaces map to on-chain modules with strongly typed generics where possible.

- `DexClient`
  - `placeCoinSell`, `placeCoinBuy`, `placeVaultSell`, `placeVaultBuy`
  - `cancel*`, `matchCoin`, `matchVault`
  - Helpers: `decodeCoinOrder`, `getConfig`

- `SyntheticsClient`
  - Vaults: `createVault`, `deposit`, `withdraw`, `mint`, `burn`
  - Orders: `placeLimit`, `cancel`, `match`
  - Health/liq: `checkVaultHealth`, `liquidate`

- `OptionsClient`
  - `createMarket`, `placeShortOffer`, `placePremiumEscrow`, `matchOfferEscrow`
  - `exerciseAmerican`, `settleMarket`, GC helpers

- `FuturesClient` and `GasFuturesClient`
  - `listContract` (admin/bot), `recordFill`, `openPosition`, `closePosition`, `settleContract`, `settlePosition`

- `VaultsClient`
  - Liquidity vault lifecycle, DEX and Synth LP wrappers
  - Trader vault lifecycle, HWM fees payout

All clients expose `buildTx()` variants for unsigned transactions and `send()` helpers when a signer is injected.

---

## API and Bot Interfaces (TypeScript)

### Core runtime types
```ts
export type ObjectId = string;
export type Address = string;

export interface NetworkConfig {
  fullnodeUrl: string;
  faucetUrl?: string;
  packageId: string;
}

export interface TxBuildResult {
  txBytesB64: string;
  gasEstimate: bigint;
}

export interface PriceBounds { minPrice: bigint; maxPrice: bigint; }
```

### HTTP server skeleton
```ts
import { FastifyInstance } from 'fastify';

export interface ApiContext {
  network: NetworkConfig;
  signer?: { address: Address; signAndSend(txB64: string): Promise<string>; };
  sdk: SdkBundle;
}

export interface SdkBundle {
  dex: DexClient;
  synth: SyntheticsClient;
  options: OptionsClient;
  futures: FuturesClient;
  gas: GasFuturesClient;
  lending: LendingClient;
  vaults: VaultsClient;
}

export async function registerRoutes(app: FastifyInstance, ctx: ApiContext) {
  app.get('/api/v1/health', async () => ({ ok: true }));
  app.get('/api/v1/config/runtime', async () => ctx.network);
  // Add per-module routers below
}
```

### API contracts: examples
```ts
// DEX: place vault buy
export interface DexPlaceVaultBuyRequest {
  cfgId: ObjectId;
  liquidityVaultId: ObjectId;
  price: bigint;
  sizeBase: bigint;
  expiryMs: bigint;
}
export interface DexPlaceVaultBuyResponse extends TxBuildResult {}

// Synthetics: mint
export interface SynthMintRequest {
  registryId: ObjectId;
  collateralVaultId: ObjectId;
  symbol: string;
  amountUnits: bigint;
  unxvPaymentCoins?: ObjectId[]; // input coin object ids for UNXV discount
}
export interface SynthMintResponse extends TxBuildResult {}

// Options: market create
export interface OptionsCreateMarketRequest {
  registryId: ObjectId;
  underlying: string;
  optionType: 'CALL' | 'PUT';
  strikePrice: bigint; // micro-USD
  expiryMs: bigint;
  settlementType: 'CASH' | 'PHYSICAL' | 'BOTH';
  treasuryId: ObjectId;
  unxvPaymentCoins?: ObjectId[];
  creationFeeCoin?: ObjectId;
}
export interface OptionsCreateMarketResponse extends TxBuildResult {}
```

### SDK client interfaces
```ts
export interface DexClient {
  placeVaultBuy(req: DexPlaceVaultBuyRequest): Promise<TxBuildResult>;
  placeVaultSell(params: { cfgId: ObjectId; liquidityVaultId: ObjectId; price: bigint; sizeBase: bigint; expiryMs: bigint; }): Promise<TxBuildResult>;
  cancelVaultBuy(params: { orderId: ObjectId; liquidityVaultId: ObjectId; }): Promise<TxBuildResult>;
  cancelVaultSell(params: { orderId: ObjectId; liquidityVaultId: ObjectId; }): Promise<TxBuildResult>;
  matchVault(params: { cfgId: ObjectId; buyId: ObjectId; sellId: ObjectId; maxFillBase: bigint; takerIsBuyer: boolean; unxvPayment?: ObjectId[]; bounds: PriceBounds; buyerVaultId: ObjectId; sellerVaultId: ObjectId; }): Promise<TxBuildResult>;
}

export interface SyntheticsClient {
  createVault(params: { cfgId: ObjectId; registryId: ObjectId; }): Promise<TxBuildResult>;
  deposit(params: { vaultId: ObjectId; coinId: ObjectId; amount: bigint; }): Promise<TxBuildResult>;
  withdraw(params: { vaultId: ObjectId; amount: bigint; symbolHint?: string; }): Promise<TxBuildResult>;
  mint(params: { registryId: ObjectId; vaultId: ObjectId; symbol: string; amountUnits: bigint; unxvCoins?: ObjectId[]; }): Promise<TxBuildResult>;
  burn(params: { registryId: ObjectId; vaultId: ObjectId; symbol: string; amountUnits: bigint; unxvCoins?: ObjectId[]; }): Promise<TxBuildResult>;
  placeOrder(params: { registryId: ObjectId; vaultId: ObjectId; symbol: string; side: 0 | 1; price: bigint; size: bigint; expiryMs: bigint; }): Promise<TxBuildResult>;
  cancelOrder(params: { orderId: ObjectId; }): Promise<TxBuildResult>;
  matchOrders(params: { registryId: ObjectId; buyId: ObjectId; sellId: ObjectId; takerIsBuyer: boolean; bounds: PriceBounds; buyerVaultId: ObjectId; sellerVaultId: ObjectId; unxvCoins?: ObjectId[]; }): Promise<TxBuildResult>;
}

export interface OptionsClient {
  createMarket(req: OptionsCreateMarketRequest): Promise<TxBuildResult>;
  placeShortOffer(params: { marketId: ObjectId; qty: bigint; minPremium: bigint; collateralCoin: ObjectId; }): Promise<TxBuildResult>;
  placePremiumEscrow(params: { marketId: ObjectId; qty: bigint; premium: bigint; collateralCoin: ObjectId; cancelAfterMs: bigint; }): Promise<TxBuildResult>;
  matchOfferEscrow(params: { registryId: ObjectId; marketId: ObjectId; offerId: ObjectId; escrowId: ObjectId; maxFillQty: bigint; unxvCoins?: ObjectId[]; treasuryId: ObjectId; }): Promise<TxBuildResult>;
  settleMarket(params: { registryId: ObjectId; marketId: ObjectId; oracleCfgId: ObjectId; priceAggId: ObjectId; }): Promise<TxBuildResult>;
}

export interface FuturesClient {
  listContract(params: { registryId: ObjectId; underlying: string; symbol: string; contractSize: bigint; tickSize: bigint; expiryMs: bigint; initMarginBps: number; maintMarginBps: number; }): Promise<TxBuildResult>;
  recordFill(params: { registryId: ObjectId; contractId: ObjectId; price: bigint; size: bigint; takerIsBuyer: boolean; maker: Address; unxvCoins?: ObjectId[]; unxvAggId: ObjectId; oracleCfgId: ObjectId; clockId: ObjectId; feeCoin: ObjectId; treasuryId: ObjectId; oiIncrease: boolean; minPrice: bigint; maxPrice: bigint; }): Promise<TxBuildResult>;
  openPosition(params: { contractId: ObjectId; side: 0 | 1; size: bigint; entryPrice: bigint; marginCoin: ObjectId; }): Promise<TxBuildResult>;
  closePosition(params: { registryId: ObjectId; contractId: ObjectId; posId: ObjectId; price: bigint; qty: bigint; treasuryId: ObjectId; }): Promise<TxBuildResult>; // tick-size enforced; close fee includes optional bot split
}

export interface GasFuturesClient {
  listContract(params: { registryId: ObjectId; symbol: string; contractSizeGas: bigint; tickSizeMicroUsdPerGas: bigint; expiryMs: bigint; initMarginBps?: number; maintMarginBps?: number; }): Promise<TxBuildResult>;
  recordFill(params: { registryId: ObjectId; contractId: ObjectId; priceMicroUsdPerGas: bigint; size: bigint; takerIsBuyer: boolean; maker: Address; unxvCoins?: ObjectId[]; suiUsdAggId: ObjectId; unxvUsdAggId: ObjectId; oracleCfgId: ObjectId; clockId: ObjectId; feeCoin: ObjectId; treasuryId: ObjectId; oiIncrease: boolean; bounds: { min: bigint; max: bigint }; }): Promise<TxBuildResult>;
  openPosition(params: { contractId: ObjectId; side: 0 | 1; size: bigint; entryPriceMicroUsdPerGas: bigint; marginCoin: ObjectId; }): Promise<TxBuildResult>;
  closePosition(params: { registryId: ObjectId; contractId: ObjectId; posId: ObjectId; priceMicroUsdPerGas: bigint; qty: bigint; treasuryId: ObjectId; }): Promise<TxBuildResult>; // fee includes optional bot split
}
export interface LendingClient {
  openAccount(): Promise<TxBuildResult>;
  createPool(params: { assetSymbol: string; publisherId: ObjectId }): Promise<TxBuildResult>;
  supply(params: { poolId: ObjectId; accountId: ObjectId; coinId: ObjectId; amount: bigint }): Promise<TxBuildResult>;
  withdraw(params: { poolId: ObjectId; accountId: ObjectId; amount: bigint; oracleCfgId: ObjectId; clockId: ObjectId; priceSelfAggId: ObjectId; symbols: string[]; prices: bigint[]; supplyIndexes: bigint[]; borrowIndexes: bigint[] }): Promise<TxBuildResult>;
  borrow(params: { poolId: ObjectId; accountId: ObjectId; amount: bigint; oracleCfgId: ObjectId; clockId: ObjectId; priceDebtAggId: ObjectId; symbols: string[]; prices: bigint[]; supplyIndexes: bigint[]; borrowIndexes: bigint[] }): Promise<TxBuildResult>;
  repay(params: { poolId: ObjectId; accountId: ObjectId; paymentCoin: ObjectId }): Promise<TxBuildResult>;
  liquidate(params: { debtPoolId: ObjectId; collPoolId: ObjectId; debtorId: ObjectId; oracleCfgId: ObjectId; clockId: ObjectId; debtAggId: ObjectId; collAggId: ObjectId; paymentCoin: ObjectId; repayAmount: bigint; symbols: string[]; prices: bigint[]; supplyIndexes: bigint[]; borrowIndexes: bigint[] }): Promise<TxBuildResult>;
}

export interface VaultsClient {
  createLiquidityVault(params: { registryId: ObjectId; baseSymbol: string; clockId: ObjectId; }): Promise<TxBuildResult>;
  lpDeposit(params: { vaultId: ObjectId; registryId: ObjectId; oracleCfgId: ObjectId; clockId: ObjectId; basePriceAggId: ObjectId; coin: ObjectId; }): Promise<TxBuildResult>;
  lpWithdraw(params: { vaultId: ObjectId; registryId: ObjectId; oracleCfgId: ObjectId; clockId: ObjectId; basePriceAggId: ObjectId; shares: bigint; }): Promise<TxBuildResult>;
  dexPlace(params: { cfgId: ObjectId; vaultId: ObjectId; side: 'buy' | 'sell'; price: bigint; sizeBase: bigint; expiryMs: bigint; }): Promise<TxBuildResult>;
  synthPlace(params: { registryId: ObjectId; vaultId: ObjectId; collateralVaultId: ObjectId; symbol: string; side: 0 | 1; price: bigint; size: bigint; expiryMs: bigint; }): Promise<TxBuildResult>;
}
```

### Bot interfaces and base class
```ts
export interface BotLogger { info(msg: string, ctx?: any): void; warn(msg: string, ctx?: any): void; error(msg: string, ctx?: any): void; }

export interface BotDeps {
  sdk: SdkBundle;
  network: NetworkConfig;
  logger: BotLogger;
  signer: { address: Address; signAndSend(txB64: string): Promise<string>; };
}

export abstract class BotBase {
  protected readonly deps: BotDeps;
  protected running = false;
  constructor(deps: BotDeps) { this.deps = deps; }
  async start(intervalMs = 1000) { this.running = true; while (this.running) { await this.tickSafe(); await new Promise(r => setTimeout(r, intervalMs)); } }
  stop() { this.running = false; }
  private async tickSafe() { try { await this.tick(); } catch (e) { this.deps.logger.error('tick error', e); } }
  protected abstract tick(): Promise<void>;
}

export class MarketListerBot extends BotBase {
  protected async tick() {
    // Read governance schedules, oracle readiness; submit list txs if due
  }
}

export class DexMatcherBot extends BotBase {
  protected async tick() {
    // Scan for crossed coin/vault orders, enforce bounds, submit match txs
  }
}

export class SynthMatcherBot extends BotBase {
  protected async tick() {
    // Scan synthetics orders and match eligible pairs
  }
}

export class LiquidationBot extends BotBase {
  protected async tick() {
    // Evaluate CCR and maintenance health across products; liquidate when eligible
  }
}

export class ExpiryAndGCWorker extends BotBase {
  protected async tick() {
    // Cancel expired orders; process settlement queues after dispute windows
  }
}
```

### Event indexing (lightweight)
```ts
export interface EventCursor { checkpoint: number; eventSeq: number; }
export interface EventHandler<T> { type: string; on(evt: T): Promise<void>; }

export class Indexer {
  constructor(private rpcUrl: string, private handlers: EventHandler<any>[]) {}
  async run(from?: EventCursor) { /* subscribe to Sui events and dispatch */ }
}
```

## Bot Processes (proposed classes)

- `MarketListerBot`
  - Lists futures/gas futures/options based on governance schedule and feed readiness.
  - Uses `oracle` liveness; emits admin-signed txs.

- `DexMatcherBot`
  - Scans `CoinOrder*` and `VaultOrder*` pairs; enforces slippage bounds; submits `match_*` txs.

- `SynthMatcherBot`
  - Scans `synthetics::Order` pairs; validates vault ownership; submits `match_orders`.

- `LiquidationBot`
  - Synthetics: monitors `CollateralVault` CCR; calls `liquidate_vault`.
  - Options: short margin health; triggers liquidation flows.
  - Futures/Gas: monitors positions and triggers `liquidate_*` when equity < maint.

- `ExpiryAndGCWorker`
  - Cancels expired orders (DEX, Synth, Options) with the `*_if_expired` functions or local cleanups.
  - Processes settlement queues (options, futures, gas) after dispute windows.

- `DisplayRegistrar`
  - Ensures type displays are registered post-upgrade for indexer UX.

- `TreasuryReporter`
  - Aggregates fee events and publishes human-friendly dashboards.

All bots should be idempotent (safe to re-run) and operate on shared-object cursors to avoid duplicative matches.

---

## Module Overview and Interactions

- DEX and LiquidityVaults: `vaults::LiquidityVault` integrates with `dex` for coin markets via `public(package)` wrappers; manager-gated placement, cancellation, and matching.
- LiquidityVaults and Synth: wrappers call through to `synthetics` for placing/canceling/matching `Order` against `CollateralVault<C>` balances.
- TraderVaults: investor share accounting, manager stake bps enforcement, HWM performance fee crystallization and payout to `treasury`.
- System authority: `SynthRegistry` is the authoritative admin list for DEX, Options, Futures, Gas Futures (all check allow-list via registry reference where admin actions occur).
- Fees: module-specific trade/settlement fees, optional UNXV discounts and maker rebates; all fees route to `treasury` objects.

---

## Security & Operations

- Admin: only addresses inside the `SynthRegistry` allow-list may execute privileged actions. UX `AdminCap` is decorative; on-chain checks use sender address.
- Oracle: Switchboard aggregators with normalized micro-USD; callers provide `Clock` for staleness; modules apply their own sanity bounds.
- Upgrades: post-upgrade displays must be re-registered; wrappers (`public(package)`) allow intra-package calls without widening external API.
- Indexing: all critical state changes emit events; bots should recover state from chain deterministically.

---

## Next Steps

- Implement the Node (CLI+API) and SDK skeletons outlined above.
- Add comprehensive integration tests per module; e2e harness for bot orchestration.
- Extend `perpetuals.move` with funding, risk, and liquidation akin to dated futures.


