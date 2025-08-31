# Unxversal CLI (Light Node)

Interactive light node for the Unxversal protocol built with React Ink. It runs:
- Indexers (protocol events → Postgres)
- Keepers (bot flows)
- Clients (interactive actions)

The default UX is a TUI with menus; flags are optional for power users.

## Requirements

- Node.js >= 16
- npm
- PostgreSQL (local or remote)
  - Ensure the database is reachable; a default `postgres://localhost:5432/unxversal` is assumed if not configured.

Optional environment variables (also set via Settings UI):
- `SUI_RPC_URL` (default: `https://fullnode.testnet.sui.io:443`)
- `DATABASE_URL` (Postgres connection string)
- `UNXV_WALLET_PRIVATE_KEY` (base64 ed25519 secret key for keepers/client)
- `UNXV_SYNTH_PACKAGE_ID`, `UNXV_SYNTH_REGISTRY_ID`, `UNXV_TREASURY_ID`
- `UNXV_ORACLE_CONFIG_ID`, `UNXV_BOT_POINTS_ID`, `UNXV_UNXV_AGGREGATOR_ID`
- `UNXV_MARKETS_JSON` (symbol→{marketId,escrowId}), `UNXV_AGGREGATORS_JSON` (symbol→aggregatorId)

## Install

```bash
npm install --global unxversal
```

## Usage

```bash
unxversal          # Launch main dashboard
unxversal --settings  # Open Settings / onboarding

# Alternative command alias (same binary)
unxversal-settings
```

### First run / Onboarding
The Settings UI writes `~/.unxversal/config.json` with:
- RPC URL and network
- Postgres URL
- Protocol-specific options (e.g., synthetics packageId)

## Architecture

- TUI: Ink-based dashboard; dolphin ASCII on the left, protocol title on the right.
- Config: Stored at `~/.unxversal/config.json`; environment variables via `dotenv` are respected.
- Indexer: Poll-based event listener using `@mysten/sui` cursors (exact-once via PK (tx_digest, event_seq)).
- Indexer runner: `unxversal --start-indexer` starts backfill-then-follow using `synthetics.packageId`. Configure `indexer.backfillSinceMs`, `indexer.windowDays`, and optional `indexer.types` in settings.
- Keeper: Periodic bot loops (match, GC, accrual) – skeleton included; wire to Move calls as needed.
- Client: Convenience wrappers for protocol interactions.

## Settings

The TUI settings writes `~/.unxversal/config.json`. Fields:

- rpcUrl, network, postgresUrl, autoStart
- wallet: { privateKey, address }
- synthetics:
  - packageId, registryId, treasuryId, oracleConfigId, botPointsId, collateralType
  - unxvAggregatorId
  - markets: { [symbol]: { marketId, escrowId } }
  - aggregators: { [symbol]: aggregatorId }
  - vaultIds: string[]
- lending:
  - packageId, registryId, oracleRegistryId, oracleConfigId
  - pools: { [assetSymbol]: { poolId, asset } }

## RPC Best Practices

- For production, prefer dedicated RPC providers with SLAs and redundancy.
- Throttle polling, use cursors, and implement backoff on 429/5xx.

## Development

```bash
npm run dev    # TypeScript watch build
npm run build  # Compile to dist
```

## Database Schemas

Below are the tables created by the indexers. Primary keys and common indexes are indicated.

### Synthetics

```
Table: synthetic_events
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| tx_digest           | text         | PK part   |
| event_seq           | text         | PK part   |
| type                | text         |           |
| timestamp_ms        | bigint       |           |
| parsed_json         | jsonb        |           |
+---------------------+--------------+-----------+
PK: (tx_digest, event_seq)
```

```
Table: orders
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| order_id            | text         | PK        |
| symbol              | text         | IDX       |
| side                | smallint     |           |
| price               | bigint       |           |
| size                | bigint       |           |
| remaining           | bigint       |           |
| owner               | text         |           |
| created_at_ms       | bigint       |           |
| expiry_ms           | bigint       |           |
| status              | text         | IDX       |
+---------------------+--------------+-----------+
PK: order_id
IDX: (symbol), (status)
```

```
Table: maker_bonds
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| order_id            | text         | PK        |
| bond                | bigint       |           |
| updated_at_ms       | bigint       |           |
+---------------------+--------------+-----------+
PK: order_id
```

```
Table: fees
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| tx_digest           | text         | PK part   |
| event_seq           | text         | PK part   |
| amount              | bigint       |           |
| payer               | text         |           |
| market              | text         |           |
| reason              | text         |           |
| timestamp_ms        | bigint       | IDX       |
+---------------------+--------------+-----------+
PK: (tx_digest, event_seq)
IDX: (timestamp_ms)
```

```
Table: rebates
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| tx_digest           | text         | PK part   |
| event_seq           | text         | PK part   |
| amount              | bigint       |           |
| taker               | text         |           |
| maker               | text         |           |
| market              | text         |           |
| timestamp_ms        | bigint       | IDX       |
+---------------------+--------------+-----------+
PK: (tx_digest, event_seq)
IDX: (timestamp_ms)
```

```
Table: maker_claims
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| tx_digest           | text         | PK part   |
| event_seq           | text         | PK part   |
| order_id            | text         |           |
| market              | text         |           |
| maker               | text         |           |
| amount              | bigint       |           |
| timestamp_ms        | bigint       | IDX       |
+---------------------+--------------+-----------+
PK: (tx_digest, event_seq)
IDX: (timestamp_ms)
```

```
Table: vaults
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| vault_id            | text         | PK        |
| owner               | text         | IDX       |
| last_update_ms      | bigint       |           |
| collateral          | bigint       |           |
+---------------------+--------------+-----------+
PK: vault_id
IDX: (owner)
```

```
Table: vault_debts
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| vault_id            | text         | PK part   |
| symbol              | text         | PK part   |
| units               | bigint       |           |
+---------------------+--------------+-----------+
PK: (vault_id, symbol)
IDX: (symbol)
```

```
Table: collateral_flows
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| tx_digest           | text         | PK part   |
| event_seq           | text         | PK part   |
| vault_id            | text         |           |
| amount              | bigint       |           |
| kind                | text         |           |
| actor               | text         |           |
| timestamp_ms        | bigint       | IDX       |
+---------------------+--------------+-----------+
PK: (tx_digest, event_seq)
IDX: (timestamp_ms)
```

```
Table: liquidations
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| tx_digest           | text         | PK part   |
| event_seq           | text         | PK part   |
| vault_id            | text         |           |
| liquidator          | text         |           |
| liquidated_amount   | bigint       |           |
| collateral_seized   | bigint       |           |
| liquidation_penalty | bigint       |           |
| synthetic_type      | text         |           |
| timestamp_ms        | bigint       | IDX       |
+---------------------+--------------+-----------+
PK: (tx_digest, event_seq)
IDX: (timestamp_ms)
```

```
Table: params_updates
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| tx_digest           | text         | PK part   |
| event_seq           | text         | PK part   |
| updater             | text         |           |
| timestamp_ms        | bigint       |           |
+---------------------+--------------+-----------+
PK: (tx_digest, event_seq)
```

```
Table: pause_toggles
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| tx_digest           | text         | PK part   |
| event_seq           | text         | PK part   |
| new_state           | boolean      |           |
| by_addr             | text         |           |
| timestamp_ms        | bigint       |           |
+---------------------+--------------+-----------+
PK: (tx_digest, event_seq)
```

```
Table: synthetics_assets
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| symbol              | text         | PK        |
| name                | text         |           |
| decimals            | int          |           |
| created_at_ms       | bigint       |           |
+---------------------+--------------+-----------+
PK: symbol
```

```
Table: synthetics_info
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| symbol              | text         | PK        |
| created_at_ms       | bigint       |           |
+---------------------+--------------+-----------+
PK: symbol
```

```
Table: cursors
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| id                  | text         | PK        |
| tx_digest           | text         |           |
| event_seq           | text         |           |
+---------------------+--------------+-----------+
PK: id
```

### Lending

```
Table: lending_events
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| tx_digest           | text         | PK part   |
| event_seq           | text         | PK part   |
| type                | text         |           |
| timestamp_ms        | bigint       |           |
| parsed_json         | jsonb        |           |
+---------------------+--------------+-----------+
PK: (tx_digest, event_seq)
```

```
Table: lending_accounts
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| account_id          | text         | PK        |
| owner               | text         |           |
| last_update_ms      | bigint       |           |
+---------------------+--------------+-----------+
PK: account_id
```

```
Table: lending_pools
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| pool_id             | text         | PK        |
| asset               | text         |           |
| total_supply        | bigint       |           |
| total_borrows       | bigint       |           |
| total_reserves      | bigint       |           |
| last_update_ms      | bigint       |           |
+---------------------+--------------+-----------+
PK: pool_id
```

```
Table: lending_balances
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| account_id          | text         | PK part   |
| asset               | text         | PK part   |
| supply_scaled       | bigint       |           |
| borrow_scaled       | bigint       |           |
+---------------------+--------------+-----------+
PK: (account_id, asset)
```

```
Table: lending_fees
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| tx_digest           | text         | PK part   |
| event_seq           | text         | PK part   |
| asset               | text         |           |
| amount              | bigint       |           |
| timestamp_ms        | bigint       |           |
+---------------------+--------------+-----------+
PK: (tx_digest, event_seq)
```

```
Table: cursors
+---------------------+--------------+-----------+
| Column              | Type         | Notes     |
+---------------------+--------------+-----------+
| id                  | text         | PK        |
| tx_digest           | text         |           |
| event_seq           | text         |           |
+---------------------+--------------+-----------+
PK: id
```

## HTTP Endpoints (List)

// Core
/health (GET)
/status (GET)
/config (GET)
/config (PUT)
/settings/wallet (POST)
/settings/network (POST)

// Indexer (synthetics)
/indexer/synth/health (GET)
/indexer/synth/start (POST)
/indexer/synth/stop (POST)
/indexer/synth/cursor (GET)
/indexer/synth/backfill (POST)

// Indexer (lending)
/indexer/lend/health (GET)
/indexer/lend/start (POST)
/indexer/lend/stop (POST)
/indexer/lend/cursor (GET)
/indexer/lend/backfill (POST)

// Bots (synthetics)
/bots/synth/health (GET)
/bots/synth/start (POST)
/bots/synth/stop (POST)
/bots/synth/config (PATCH)

// Bots (lending)
/bots/lend/health (GET)
/bots/lend/start (POST)
/bots/lend/stop (POST)

// Synthetics (markets)
/synthetics/markets (GET)
/synthetics/markets/:symbol (GET)
/synthetics/markets/:symbol/match (POST)
/synthetics/markets/:symbol/gc (POST)

// Synthetics (data)
/synthetics/orders (GET)
/synthetics/vaults (GET)
/synthetics/liquidations (GET)
/synthetics/fees (GET)
/synthetics/rebates (GET)
/synthetics/candles/:market (GET)

// Synthetics (PTBs)
/synth/orders (POST)
/synth/orders/:orderId/modify (POST)
/synth/orders/:orderId/cancel (POST)
/synth/orders/:orderId/claim (POST)
/synth/vaults (POST)
/synth/vaults/:id/deposit (POST)
/synth/vaults/:id/withdraw (POST)
/synth/vaults/:id/mint (POST)
/synth/vaults/:id/burn (POST)
/synth/vaults/:id/liquidate (POST)

// Oracles
/synth/oracles (GET)
/synth/oracles/:symbol/price (GET)

// Lending (data)
/lending/pools (GET)
/lending/pools/:poolId (GET)
/lending/accounts/:accountId (GET)
/lending/fees (GET)
/lending/candles/:asset (GET)

// Lending (PTBs)
/lending/accounts (POST)
/lending/accounts/:accountId/supply (POST)
/lending/accounts/:accountId/withdraw (POST)
/lending/accounts/:accountId/borrow (POST)
/lending/accounts/:accountId/repay (POST)
/lending/pools/:poolId/update-rates (POST)
/lending/pools/:poolId/accrue (POST)

For detailed schemas and live try-it-out, visit Swagger UI at `/docs`.
