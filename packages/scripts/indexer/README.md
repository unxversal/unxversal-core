# Unxversal Indexer (sui-indexer-alt-framework)

Production-grade custom indexer for the Unxversal Move protocols using Mysten's `sui-indexer-alt-framework`.

## Features

- Concurrent pipeline indexing of all Unxversal events into PostgreSQL
- Robust backpressure, watermarking, and metrics via the framework
- Diesel migrations bundled; DB is auto-migrated on startup

## Workspace layout

- `crates/schema`: Diesel models, schema.rs, and migrations
- `crates/indexer`: Binary and handlers

## Prerequisites

- Rust toolchain (stable)
- PostgreSQL client libraries (libpq)
  - macOS: `brew install postgresql@14` (or newer) then ensure pkg-config sees it: `export PKG_CONFIG_PATH="$(brew --prefix)/opt/libpq/lib/pkgconfig:$PKG_CONFIG_PATH"`
  - Linux (Debian/Ubuntu): `sudo apt-get install -y libpq-dev`

## Build

```bash
cd packages/scripts/indexer
cargo build
```

If you see a linker error like `ld: library 'pq' not found`, install libpq as shown above.

## Run

The indexer streams checkpoints from Mysten remote checkpoint stores by default. Provide your DB URL and environment (mainnet or testnet):

```bash
./target/debug/unxv-indexer \
  --database-url postgres://postgres:postgrespw@localhost:5432/unxv_indexer \
  --env mainnet
```

Flags:
- `--database-url`: PostgreSQL DSN
- `--env`: `mainnet` or `testnet` (controls remote store URL)
- All `sui-indexer-alt-framework` `IndexerArgs` and DB pool `DbArgs` flags are supported via CLI/env

## Schema

Events are captured raw into a single wide table for flexibility:

- `unxv_events(event_digest PRIMARY KEY, digest, sender, checkpoint, checkpoint_timestamp_ms, package, module, event_type, type_params JSONB, contents_bcs BYTEA)`

You can derive specialized, denormalized tables later for analytics.

## Notes

- This initial pipeline captures all events emitted by Unxversal modules (e.g. `futures`, `perpetuals`, `x*`, `staking`, `lending`, `rewards`, `dex`, `options`).
- For stricter filtering by on-chain package ID(s), add a package allowlist check in `handlers/unxv_events_handler.rs` once your packages are published.

