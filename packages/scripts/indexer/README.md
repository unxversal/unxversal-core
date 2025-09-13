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

## Binaries

- `unxversalindexer`: primary CLI with defaults and banner (recommended)
- `unxvindexer`: legacy alias (same behavior), kept for convenience

## Quick start

Installed (recommended):

```bash
unxversalindexer
```

Select network via positional arg:

```bash
unxversalindexer mainnet
unxversalindexer testnet
```

Override database or metrics if needed:

```bash
unxversalindexer \
  --database-url postgres://postgres:postgrespw@localhost:5432/unxv_indexer \
  --metrics-address 0.0.0.0:9184
```

Dev-run (without install):

```bash
./target/debug/unxversalindexer
```

All `sui-indexer-alt-framework` `IndexerArgs` and DB pool `DbArgs` flags are also supported via CLI/env.

## Install the CLI globally

Option A (recommended): install into `~/.cargo/bin` and add to PATH

```bash
cd packages/scripts/indexer
cargo install --path crates/indexer --force
echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
# now you can run
unxvindexer
unxversalindexer
```

Option B (dev): add `target/debug` to PATH

```bash
cd packages/scripts/indexer
echo 'export PATH="$(pwd)/target/debug:$PATH"' >> ~/.zshrc
source ~/.zshrc
unxvindexer
```

## Defaults

- Banner: printed on startup (ASCII Unxversal title), then logs and metrics info
- Network: defaults to `mainnet` (change via positional arg or `--env`)
- Database: `postgres://postgres:postgrespw@localhost:5432/unxv_indexer`
- Metrics: `0.0.0.0:9184`
- Module filter: indexes events from Unxversal modules only (`dex`, `futures`, `gas_futures`, `lending`, `options`, `perpetuals`, `rewards`, `staking`, `unxv`, `usdu`, `xfutures`, `xoptions`, `xperps`)

All `sui-indexer-alt-framework` `IndexerArgs` and DB pool `DbArgs` flags are also supported via CLI/env.

## Configuration

### Set the Unxversal package address

By default, the handler accepts any package address. To restrict indexing to your deployed Unxversal package(s), set a comma-separated allowlist in `UNXV_PACKAGE_IDS`.

Examples:

```bash
# One package id
export UNXV_PACKAGE_IDS=0xabc123...

# Multiple package ids (comma-separated)
export UNXV_PACKAGE_IDS=0xabc123...,0xdef456...

# Run
unxversalindexer mainnet
```

Notes:
- Values are compared as lowercase 0x hex strings.
- Keep this set in your shell profile if you always want to filter to your prod packages.

### Set the Postgres URL

Default DSN is:

```
postgres://postgres:postgrespw@localhost:5432/unxv_indexer
```

Override via flag:

```bash
unxversalindexer --database-url postgres://USER:PASS@HOST:PORT/DBNAME
```

Or environment variable (works because the flag is defined with `env`):

```bash
export DATABASE_URL=postgres://USER:PASS@HOST:PORT/DBNAME
unxversalindexer
```

If you use a managed Postgres with SSL or parameters, include them in the DSN.

## Schema

Events are captured raw into a single wide table for flexibility:

- `unxv_events(event_digest PRIMARY KEY, digest, sender, checkpoint, checkpoint_timestamp_ms, package, module, event_type, type_params JSONB, contents_bcs BYTEA)`

You can derive specialized, denormalized tables later for analytics.

## Notes

- This initial pipeline captures all events emitted by Unxversal modules (e.g. `futures`, `perpetuals`, `x*`, `staking`, `lending`, `rewards`, `dex`, `options`).
- For stricter filtering by on-chain package ID(s), add a package allowlist check in `handlers/unxv_events_handler.rs` once your packages are published.

