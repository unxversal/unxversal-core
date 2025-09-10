### Unxversal Keeper Cron

This service performs on-chain maintenance across Unxversal protocols using a single loop with clear logs and configurable cadence. Only the admin private key comes from env; all IDs and behavior come from `src/config.ts`.

### Responsibilities
- Oracle price upkeep
  - Futures: `futures::update_index_price` (with inline Pyth update)
  - Gas Futures: `gas_futures::update_index_price`
- Liquidations (price-driven, throttled)
  - Futures: `futures::liquidate`
  - Perpetuals: `perpetuals::liquidate`
  - Gas Futures: `gas_futures::liquidate`
  - Lending: `lending::liquidate2` (non-flash variant using keeper Debt coin)
- Expiry/settlement
  - Futures: `futures::snap_settlement_price`
  - Gas Futures: `gas_futures::snap_settlement_price`
- Options orderbook upkeep
  - `options::sweep_expired_orders` per market/series
- Perps funding
  - `perpetuals::apply_funding_update` with configured delta
- Lending reserves sweep (optional)
  - `lending::sweep_debt_reserves_to_fee_vault`

### Scheduling model
- Single loop with configurable sleep (`config.cron.sleepMs`). Inside each loop the cron:
  - Refreshes index prices
  - Attempts settlement snaps (if past expiry)
  - Sweeps expired option orders
  - Applies perps funding update (if configured)
  - Sweeps lending reserves (if configured)
  - Runs liquidation scans for futures/perps/gas futures/lending

Liquidation scans are throttled per market via in-memory timestamps. Each market is fully scanned at most once per `config.cron.fullSweepMs`. Use devInspect prechecks to avoid reverts and limit candidates to `config.cron.healthChecks` per sweep. Batch liquidations per tx are limited by `config.cron.liqBatch`.

### Configuration (src/config.ts)
- Core IDs
  - `network`: `mainnet` | `testnet`
  - `pkgId`: Unxversal package ID
  - `adminRegistryId`, `oracleRegistryId`
  - `feeConfigId`, `feeVaultId`, `rewardsId`, `stakingPoolId`
- Pyth
  - `pyth.stateId`, `pyth.wormholeStateId`
- Futures
  - `futures.markets: string[]`
  - `futures.priceIdByMarket: Record<marketId,string>`
  - `futures.expiryMsByMarket?: Record<marketId,number>` (non-zero to enable snapping)
- Gas Futures
  - `gasFutures.markets: string[]`
  - `gasFutures.expiryMsByMarket?: Record<marketId,number>`
- Perps
  - `perps.markets: string[]`
  - `perps.priceIdByMarket: Record<marketId,string>`
  - `perps.fundingDelta1e6?: number` (optional per-loop funding delta)
  - `perps.longsPay?: boolean`
- Options
  - `options.markets: string[]`
  - `options.seriesByMarket: Record<marketId,string[]>` (u128 keys as strings)
  - `options.sweepMax: number` (per-tx sweep cap)
- Lending
  - `lending.feeVaultId: string`
  - `lending.priceIdByMarket?: Record<marketId,string>` (oracle for Collat symbol)
  - `lending.defaultSweepAmount?: number` (reserves sweep amount fallback)
  - `lending.markets: Array<{ marketId, collat, debt, sweepAmount?, keeperDebtCoinId? }>`
    - `keeperDebtCoinId` (optional): `Coin<Debt>` object owned by keeper wallet for non-flash liquidations
- Cron tuning
  - `cron.sleepMs: number`
  - `cron.liqBatch?: number` (default 5)
  - `cron.healthChecks?: number` (default 200)
  - `cron.fullSweepMs?: number` (default 180_000)

### Environment
- Only the admin/keeper key comes from env:
  - `UNXV_ADMIN_MNEMONIC` preferred, or `UNXV_ADMIN_SEED_B64`

### Logs
- All operations log with compact, namespaced messages:
  - Price updates: `futures.update_index_price`, `gas_futures.update_index_price`
  - Settlement: `futures.snap_settlement_price`, `gas_futures.snap_settlement_price`
  - Options sweep: `options.sweep_expired_orders`
  - Funding: `perpetuals.apply_funding_update`
  - Reserves: `lending.sweep_debt_reserves_to_fee_vault`
  - Liquidations: `*.liquidate` with victim counts
  - Scan summaries per market with `scanned` and `candidates` counts

### Notes
- Liquidations are price-driven and scan tables periodically; you can add event-driven hot sets later to reduce scans further.
- For lending flash-liquidations with in-tx swaps, provide DEX pool IDs and we can extend the cron to borrow `Debt`, run `lending::liquidate2`, swap seized `Collat` → `Debt`, and `flash_repay_debt` in the same tx.


