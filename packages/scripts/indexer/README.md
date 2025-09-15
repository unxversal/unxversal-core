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
- Module filter: indexes events from Unxversal modules only (`admin`, `fees`, `oracle`, `staking`, `rewards`, `usdu`, `book`, `big_vector`, `dex`, `futures`, `gas_futures`, `options`, `perpetuals`, `lending`, `xperps`)

All `sui-indexer-alt-framework` `IndexerArgs` and DB pool `DbArgs` flags are also supported via CLI/env.

## Configuration

### Set the Unxversal package addresses (modular)

By default, the handler accepts any package address. For modular deployments, set a comma-separated allowlist in `UNXV_PACKAGE_IDS` with all published package IDs (core and each product package).

Examples:

```bash
# One package id (legacy/monolithic)
export UNXV_PACKAGE_IDS=0xabc123...

# Multiple package ids (comma-separated; modular)
export UNXV_PACKAGE_IDS=0xcore,0xdex,0xffut,0xperp,0xgas,0xopt,0xlend,0xxp

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

- This initial pipeline captures all events emitted by Unxversal modules (e.g. `admin`, `fees`, `oracle`, `staking`, `rewards`, `usdu`, `book`, `big_vector`, `dex`, `futures`, `gas_futures`, `options`, `perpetuals`, `lending`, `xperps`).
- For stricter filtering by on-chain package ID(s), add a package allowlist check in `handlers/unxv_events_handler.rs` once your packages are published.

# How it works

### How package IDs work in the indexer
- Each published Move package has an on-chain package ID (0x… address). With the modular split, you now have several package IDs (core, dex, futures, perps, gasfutures, options, lending, xperps).
- The indexer can optionally restrict to specific package IDs via the UNXV_PACKAGE_IDS environment variable. Set it to a comma-separated, lowercase list of all your published package IDs:
```bash
export UNXV_PACKAGE_IDS=0xcore,0xdex,0xffut,0xperp,0xgas,0xopt,0xlend,0xxp
```
- When set, the indexer only persists events whose event type’s address matches one of the allowlisted package IDs. If unset, it accepts events from any package (still filtered by module names).

### How the indexer works (high-level)
- It uses sui-indexer-alt-framework to stream Sui checkpoints, then:
  - Runs DB migrations, starts metrics, and initializes the pipeline.
  - For each transaction in a checkpoint, it iterates over events.
  - For each event:
    - Reads the event’s type tag to get the module (e.g., futures) and the package address (the package ID that defined the event’s struct).
    - Applies a module allowlist: admin, fees, oracle, staking, rewards, usdu, book, big_vector, dex, futures, gas_futures, options, perpetuals, lending, xperps.
    - Optionally applies the package allowlist from UNXV_PACKAGE_IDS (if set).
    - Writes the event to the unxv_events table: package (string), module (string), event_type (struct name), type_params (JSON), contents_bcs (bytes), digest, sender, checkpoint, checkpoint_timestamp_ms.
- Package ID source per event:
  - The allowlist check uses the event type tag’s address (the defining package of the event struct).
  - For convenience, the row also includes the package extracted from the move call; in typical cases this matches the event’s package (especially for your modules).

### Practical notes
- Always include all modular package IDs in UNXV_PACKAGE_IDS for production, and keep the list updated on upgrades (you can include both old and new IDs during cutover).
- If you want to index everything during development, you can leave UNXV_PACKAGE_IDS unset; the module filter still gates to Unxversal modules.