# Unxversal Deployment Guide

This document explains how the deployment system is structured and how to run and customize deployments for Unxversal. It covers the modular config, per‑protocol builders, the deploy runner, outputs, and required environment/inputs.

## Overview

- Source: `packages/scripts/src/deploy`
- Entrypoint: `src/deploy/index.ts`
- Config aggregation: `src/deploy/config.ts` (re-exports from `config.modular.ts`)
- Shared types: `src/deploy/types.ts`
- Builders:
  - Markets & constants: `src/deploy/markets.ts`
  - Options: `src/deploy/options.ts`
  - Futures: `src/deploy/futures.ts`
  - Gas Futures: `src/deploy/gas_futures.ts`
  - Perpetuals: `src/deploy/perpetuals.ts`
  - Lending: `src/deploy/lending.ts`
  - Oracle: `src/deploy/oracle.ts`
  - DEX Pools (DeepBook): `src/deploy/dex.ts`
  - Vaults: `src/deploy/vaults.ts`

The deploy script initializes or updates on‑chain components (lending, options, futures, gas futures, perps, DEX pools, vaults) and writes human‑ and machine‑readable artifacts.

## Running a Deploy

- Env vars (admin key):
  - `UNXV_ADMIN_MNEMONIC` or `UNXV_ADMIN_SEED_PHRASE` (preferred)
  - Or `UNXV_ADMIN_SEED_B64` (base64 private key)
- Optional env vars (admins):
  - `UNXV_TWO`, `UNXV_THREE` → appended to additional admins list

Build and run:

```bash
# from repo root
npm -w packages/scripts run build
node packages/scripts/dist/deploy/index.js
```

The script selects the RPC based on `deployConfig.network` (`mainnet` or `testnet`).

## Outputs

- Markdown summary: `packages/scripts/deploy-output.md`
- Raw tx responses: `packages/scripts/deploy-tx-responses.json`
- JSON summary: `packages/scripts/deploy-summary.json`

These are written at the end of the run for auditability and tooling.

## Configuration Model

The deployment is driven by `DeployConfig` (see `src/deploy/types.ts`). Two concrete configs are exported:

- `deployConfig`: mainnet flavor
- `testnetDeployConfig`: testnet flavor

`config.modular.ts` composes these from the builder modules. Each module is responsible for producing a list of spec objects for a protocol.

### Key fields

- Core ids: `pkgId`, `adminRegistryId`, `feeConfigId`, `feeVaultId`, `stakingPoolId`, `usduFaucetId?`, `oracleRegistryId?`
- Admins and fee params: `additionalAdmins`, `feeParams`, `feeTiers`, `tradeFees`, `lendingParams`, `poolCreationFeeUnxv?`
- Oracle: `oracleMaxAgeSec`, `oracleFeeds[]`
- Protocol specs:
  - `lendingMarkets[]`
  - `options[]` (with generated `series[]`)
  - `futures[]`
  - `gasFutures[]`
  - `perpetuals[]`
  - `dexPools[]`
  - `vaults[]`

### Mainnet vs Testnet type‑tags

- `markets.ts` declares `MAINNET_DERIVATIVE_TYPE_TAGS` and `TESTNET_DERIVATIVE_TYPE_TAGS`.
- Builders (e.g., `options.ts`, `perpetuals.ts`, `dex.ts`) pick the correct mapping for the network.

## Per‑Protocol Builders

- Options (`options.ts`): builds series from symbols/policies using `buildAllOptionSeriesForFeeds`. Requires type‑tags and decimal/tick/lot configs from `markets.ts`.
- Futures (`futures.ts`): generates dated futures using interval schedulers and tiered risk caps from `markets.ts`.
- Gas Futures (`gas_futures.ts`): weekly expiries with MIST‑scaled tick; similar to futures but simplified.
- Perpetuals (`perpetuals.ts`): builds linear perps using tier schedules and funding intervals per tier.
- Lending (`lending.ts`): defines two flavors (mainnet/testnet) of dual‑asset markets.
- Oracle (`oracle.ts`): feed lists and `ORACLE_MAX_AGE_SEC`.
- DEX Pools (`dex.ts`): builds DeepBook pool creation specs (base/quote/tick/lot/min) from type‑tags by network.
- Vaults (`vaults.ts`): optional creation and post‑init caps.

## Deploy Runner (index.ts)

- Loads admin keypair from env; connects to RPC via `getFullnodeUrl(network)`.
- Ensures `oracleRegistry` exists (creates if absent), sets `oracleMaxAgeSec`, and registers feeds.
- Applies `feeParams`, `feeTiers`, `tradeFees`, `lendingParams`, and `poolCreationFeeUnxv` if present.
- Deploys, in order: Lending → Options → Futures → Gas Futures → Perps → DEX Pools → Vaults.
- Verbose logging: every step/tx is logged, including params for transparency.
- Artifacts: collects created package/object types; generates comprehensive markdown; writes raw tx responses and JSON summary.

### DEX Pool Creation & DEEP Fee

DeepBook requires a DEEP creation fee (currently 600). The on‑chain `unxversal::dex` functions now accept a `Coin<DEEP>` and forward it to DeepBook:

- `create_pool_admin<Base, Quote>(..., creation_fee_deep: Coin<DEEP>, ...)` (admin‑gated)
- `create_permissionless_pool<Base, Quote>(..., creation_fee_deep: Coin<DEEP>, ...)` (charges UNXV fee and pays DEEP to DeepBook)

In the deploy runner, each `dexPools[]` entry can include:

- `deepCreationFeeCoinId`: object id of a DEEP coin you hold
- `deepCreationFeeAmount`: optional (defaults to 600)

The script splits exactly `deepCreationFeeAmount` from that coin in‑tx and passes it to `unxversal::dex::create_pool_admin`.

## Customizing the Config

- Change symbols/policies and type‑tags in `markets.ts`.
- Tune risk tiers and caps in `markets.ts` / builder defaults.
- Set fees/discounts via `feeParams`/`feeTiers`/`tradeFees`.
- Adjust options strike bands in `POLICIES` (`markets.ts`) and spot lookups in `utils/series.ts` if needed.

## Troubleshooting

- Missing ids: Ensure `pkgId`, `adminRegistryId`, `feeConfigId`, `feeVaultId`, `stakingPoolId` are populated.
- Oracle feed bytes: `oracle.set_feed_from_bytes` expects a 32‑byte price id (0x‑hex string).
- DEEP pool creation fee: set `deepCreationFeeCoinId` per pool, or wire a global helper to inject it.
- Permissions: admin‑gated functions require the caller (your keypair) to be in `AdminRegistry`.

## Programmatic Artifacts

- `deploy-tx-responses.json`: array of `{ label, digest, response }` for all transactions.
- `deploy-summary.json`: the full in‑memory summary used to generate markdown.
- `deploy-output.md`: human readable report with counts and per‑market details.

## Safety

- The runner logs every call and waits for finality per tx.
- Risk caps and fees are explicit in the config; review before running mainnet.
- Consider running a dry run against testnet with the testnet config first.
