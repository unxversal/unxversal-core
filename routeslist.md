### Server endpoints (proposed, comprehensive)

- Conventions
  - All write endpoints build a PTB and sign using `wallet.privateKey` from settings.
  - IDs refer to on-chain object IDs (strings). Symbols are strings. Amounts in smallest units (u64-compatible).
  - Responses return `{ ok: boolean, txDigest?: string, error?: string, ... }` plus any useful data.

### Core/health/settings
- [x] GET /health
  - Return server + DB health: `{ ok, db: true|false }`
- [x] GET /status
  - High-level status: indexers/keepers running, ports, cursor ages
- [x] GET /config
  - Current config JSON (redacted privateKey)
- [x] PUT /config
  - Update structured config (supports partial)
  - Body: partial of app config
- [x] POST /settings/wallet
  - Body: `{ address?: string, privateKey?: string }`
- [x] POST /settings/network
  - Body: `{ rpcUrl?: string, network?: 'localnet'|'devnet'|'testnet'|'mainnet' }`

### Indexer control (synthetics and lending)
- [x] GET /indexer/synth/health
- [x] POST /indexer/synth/start
  - Body: `{ sinceMs?: number, types?: string[], windowDays?: number }`
- [x] POST /indexer/synth/stop
- [x] GET /indexer/synth/cursor
- [x] POST /indexer/synth/backfill
  - Body: `{ sinceMs: number, types?: string[], windowDays?: number }`
- [x] GET /indexer/lend/health
- [x] POST /indexer/lend/start
  - Body: `{ sinceMs?: number }`
- [x] POST /indexer/lend/stop
- [x] GET /indexer/lend/cursor
- [x] POST /indexer/lend/backfill
  - Body: `{ sinceMs: number }`

### Keeper control (bots)
- [x] GET /bots/synth/health
- [x] POST /bots/synth/start
  - Body: `{ intervalsMs?: { match?: number, gc?: number, accrue?: number, liq?: number }, priceBandBps?: number }`
- [x] POST /bots/synth/stop
- [x] PATCH /bots/synth/config
  - Body: same as start; updates config live
- [x] GET /bots/lend/health
- [x] POST /bots/lend/start
  - Body: `{ intervalMs?: number }` (periodic update rates/accrual)
- [x] POST /bots/lend/stop

### Synthetics: markets/orders (CLOB)
- [x] GET /synth/markets
  - List markets with IDs, ticks, activity stats
- [x] GET /synth/markets/:symbol
- [x] POST /synth/markets/:symbol/match
  - Body: `{ maxSteps?: number, priceBandBps?: number }`
- [x] POST /synth/markets/:symbol/gc
  - Body: `{ maxRemovals?: number }`
- [x] GET /synth/orders?symbol=XYZ&status=open|filled|canceled
- [x] POST /synth/orders
  - Place order with escrow
  - Body:
    - `{ symbol: string, takerIsBid: boolean, price: string|number, size: string|number, expiryMs?: number, marketId: string, escrowId: string, registryId: string, vaultId: string, treasuryId: string }`
- [x] POST /synth/orders/:orderId/modify
  - Body: `{ newQty: string|number, nowMs?: number, registryId: string, marketId: string, escrowId: string, vaultId: string }`
- [x] POST /synth/orders/:orderId/cancel
  - Body: `{ marketId: string, escrowId: string, vaultId: string }`
- [x] POST /synth/orders/:orderId/claim
  - Body: `{ registryId: string, marketId: string, escrowId: string, vaultId: string }`

### Synthetics: vaults/debt
- [x] GET /synth/vaults
  - From DB: recent vaults, collateral, last_update
- [x] GET /synth/vaults/:id
  - From DB + RPC: collateral, debts per symbol, ratio
- [x] POST /synth/vaults
  - Create vault
  - Body: `{ collateralCfgId: string, registryId: string }`
- [x] POST /synth/vaults/:id/deposit
  - Body: `{ coinId: string }`
- [x] POST /synth/vaults/:id/withdraw
  - Body: `{ amount: string|number, symbol: string, priceObj: string }`
- [x] POST /synth/vaults/:id/mint
  - Body: `{ symbol: string, amount: string|number, priceObj: string, unxvPriceObj: string, treasuryId: string, unxvCoins?: string[] }`
- [x] POST /synth/vaults/:id/burn
  - Body: `{ symbol: string, amount: string|number, priceObj: string, unxvPriceObj: string, treasuryId: string, unxvCoins?: string[] }`
- [x] POST /synth/vaults/:id/liquidate
  - Body: `{ symbol: string, repay?: string|number }` (keeper-like sizing if not provided)

### Synthetics: oracles/admin
- [x] GET /synth/oracles
  - List configured aggregator IDs per symbol from config/registry
- [x] GET /synth/oracles/:symbol/price
  - Current price (micro-USD), staleness
- [x] Admin routes excluded (CLI-only)

### Synthetics: data/analytics
- [x] GET /synth/events?type=...&limit=...
- [x] GET /synth/fees
- [x] GET /synth/rebates
- [x] GET /synth/liquidations
- [x] GET /synth/candles/:market
  - Returns minute buckets of fee-derived “volume” (or later switch to order flow)

### Lending: pools/accounts
- [x] GET /lend/pools
- [x] GET /lend/pools/:poolId
- [x] POST /lend/pools/:poolId/update-rates
- [x] POST /lend/pools/:poolId/accrue
- [x] POST /lend/accounts
  - Open account (returns tx + created ID from effects)
- [x] GET /lend/accounts/:accountId
  - Balances (supply/borrow) by asset
- [x] POST /lend/accounts/:accountId/supply
  - Body: `{ poolId: string, coinId: string, amount: string|number }`
- [x] POST /lend/accounts/:accountId/withdraw
  - Body: `{ poolId: string, amount: string|number, oracleRegistryId: string, oracleConfigId: string, priceSelfAggId: string, symbols: string[], pricesSetId: string, supplyIdx: number[], borrowIdx: number[] }`
- [x] POST /lend/accounts/:accountId/borrow
  - Body: `{ poolId: string, amount: string|number, oracleRegistryId: string, oracleConfigId: string, priceDebtAggId: string, symbols: string[], pricesSetId: string, supplyIdx: number[], borrowIdx: number[] }`
- [x] POST /lend/accounts/:accountId/repay
  - Body: `{ poolId: string, paymentCoinId: string }`

### Lending: data/analytics
- [x] GET /lend/events?type=...&limit=...
- [x] GET /lend/fees
- [x] GET /lend/candles/:asset
  - Similar minute bucket aggregation (e.g., from fees/reserves_added)

### Bots/UX management
- GET /ui/summary
  - Aggregate card data (counts, top markets, vol, cursor ages)
- GET /ui/synthetics/overview
  - Orders open, maker bonds, top markets
- GET /ui/lending/overview
  - Pools rates, utilization, top fees

### Security notes
- Admin endpoints should be limited to localhost by default or require a shared token in headers (configurable).
- PTB write endpoints should log the action type and target IDs; do not echo privateKey.

If you want, I can implement these routes in `server.ts` progressively:
- Phase 1 (high-value): orders, vaults, pools, accounts, keeper/indexer controls, and core admin (pause/resume, set treasury).
- Phase 2: candles and granular admin endpoints.