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

## RPC Best Practices

- For production, prefer dedicated RPC providers with SLAs and redundancy.
- Throttle polling, use cursors, and implement backoff on 429/5xx.

## Development

```bash
npm run dev    # TypeScript watch build
npm run build  # Compile to dist
```
