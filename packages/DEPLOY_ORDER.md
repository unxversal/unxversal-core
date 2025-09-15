# Unxversal Modular Packages: Dependencies and Publish Order

This document captures the dependency graph and the recommended on-chain publish order after modularizing the original `unxversal` package.

## Packages

- unxvcore
  - Modules: `admin`, `unxv`, `usdu`, `oracle`, `fees`, `staking`, `rewards`, `book`, `big_vector`, `utils`
  - External deps: DeepBook, Token, Pyth (git)
- unxvdex
  - Depends on: `unxvcore`, DeepBook, Token
  - Module: `dex`
- unxvfutures
  - Depends on: `unxvcore`, Pyth (git)
  - Module: `futures`
- unxvperps
  - Depends on: `unxvcore`, Pyth (git)
  - Module: `perpetuals`
- unxvgasfutures
  - Depends on: `unxvcore`
  - Module: `gas_futures`
- unxvoptions
  - Depends on: `unxvcore`, Pyth (git)
  - Module: `options`
- unxvlending
  - Depends on: `unxvcore`, Pyth (git)
  - Module: `lending`
- unxvxperps
  - Depends on: `unxvcore`
  - Module: `xperps`

## Publish Order

1. Publish `unxvcore`
   - Initialize shared objects:
     - `admin::init` (claim Publisher, share `AdminRegistry`)
     - `fees::init` (share `FeeConfig` and `FeeVault`)
     - `staking::init` (share `StakingPool`)
     - `usdu::init` (share `Faucet`)
     - `oracle::init_registry` (share `OracleRegistry`)

2. Publish product packages (any subset as needed):
   - `unxvdex`
   - `unxvfutures`
   - `unxvperps`
   - `unxvgasfutures`
   - `unxvoptions`
   - `unxvlending`
   - `unxvxperps`

The product packages reference `unxvcore` by `published-at`. After each publish, record the package id(s) for use in scripts and indexer allowlists.

## Post-Publish Wiring

- Configure fees (trade fees, tiers, lending params, pool creation fee) via `unxvcore::fees::*`.
- Configure oracle feeds via `unxvcore::oracle::*` (Pyth identifiers).
- Create DeepBook pools and register protocol-specific parameters as needed.
- Initialize individual markets (futures, perps, gas_futures, options, lending) using their respective package ids.

## Notes

- Keep `UNXV_PACKAGE_IDS` env (comma-separated) updated with all published package addresses for the indexer.
- Frontend and scripts should be updated to reference modular package ids per product.
