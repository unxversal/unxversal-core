import { logger } from './utils/logger.js';
import { sleep } from './utils/time.js';
import { config } from './config.js';
import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { SuiPythClient, SuiPriceServiceConnection } from '@pythnetwork/pyth-sui-js';
import { fromB64, fromBase64 } from '@mysten/sui/utils';

/**
 * Env/config
 * These should be provided via environment variables or a small config layer.
 */
const NETWORK = config.network;
const ORACLE_REGISTRY_ID = config.oracleRegistryId;
const ADMIN_REGISTRY_ID = config.adminRegistryId;
const PERP_MARKET_IDS = config.perps.markets;
const FUTURES_MARKET_IDS = config.futures.markets;
const GAS_FUTURES_MARKET_IDS = config.gasFutures.markets;
const OPTIONS_MARKET_IDS = config.options.markets;
const OPTIONS_SWEEP_MAX = config.options.sweepMax;
const PYTH_STATE_ID = config.pyth.stateId;
const WORMHOLE_STATE_ID = config.pyth.wormholeStateId;
const CRON_SLEEP_MS = config.cron.sleepMs;
const LENDING_CFG = config.lending;

// Keypair for admin/keeper (prefer mnemonic)
const ADMIN_MNEMONIC = process.env.UNXV_ADMIN_MNEMONIC || process.env.UNXV_ADMIN_SEED_PHRASE || '';
let keypair: Ed25519Keypair;
if (ADMIN_MNEMONIC) {
  keypair = Ed25519Keypair.deriveKeypair(ADMIN_MNEMONIC);
} else {
  const ADMIN_SEED_B64 = process.env.UNXV_ADMIN_SEED_B64 || '';
  keypair = ADMIN_SEED_B64 ? Ed25519Keypair.fromSecretKey(Buffer.from(ADMIN_SEED_B64, 'base64')) : Ed25519Keypair.generate();
}

const client = new SuiClient({ url: getFullnodeUrl(NETWORK) });

// Required globals from config only (env solely for admin key)
const CLOCK_ID = '0x6';
const REWARDS_ID = config.rewardsId;
const GLOBAL_FEE_VAULT_ID = config.feeVaultId;
const FEE_CONFIG_ID = config.feeConfigId;
const STAKING_POOL_ID = config.stakingPoolId;

// Keeper tuning from config.cron
const MAX_LIQUIDATIONS_PER_MARKET = config.cron.liqBatch ?? 5;
const MAX_HEALTH_CHECKS_PER_MARKET = config.cron.healthChecks ?? 200;
const FULL_SWEEP_INTERVAL_MS = config.cron.fullSweepMs ?? (3 * 60 * 1000);

type Address = string;

function nowMs(): number { return Date.now(); }

function ensure(id: string, label: string): string {
  if (!id) throw new Error(`${label} is required in config/env`);
  return id;
}

async function updatePythFeedsOnTx(tx: Transaction, priceIds: string[]): Promise<string[]> {
  if (!priceIds.length) return [];
  const hermesUrl = config.network === 'mainnet' ? 'https://hermes.pyth.network' : 'https://hermes-beta.pyth.network';
  const connection = new SuiPriceServiceConnection(hermesUrl, { priceFeedRequestConfig: { binary: true } });
  const updateData = await connection.getPriceFeedsUpdateData(priceIds);
  const pythClient = new SuiPythClient(client, PYTH_STATE_ID, WORMHOLE_STATE_ID);
  return await pythClient.updatePriceFeeds(tx, updateData, priceIds);
}

/**
 * Keeper: proactively refresh last observed index price for all futures & gas_futures markets.
 * This helps the live price be fresh without requiring a trade.
 */
async function refreshIndexPrices(): Promise<void> {
  // Update futures markets: one tx per market with inline Pyth update
  for (const m of FUTURES_MARKET_IDS) {
    try {
      const priceId = config.futures.priceIdByMarket[m];
      if (!priceId) { continue; }
      const tx = new Transaction();
      const [priceInfoObjectId] = await updatePythFeedsOnTx(tx, [priceId]);
      tx.moveCall({
        target: `${config.pkgId}::futures::update_index_price`,
        arguments: [tx.object(m), tx.object(ORACLE_REGISTRY_ID), tx.object(priceInfoObjectId), tx.object('0x6')],
      });
      const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true } });
      await client.waitForTransaction({ digest: res.digest });
      logger.debug(`futures.update_index_price ok market=${m}`);
    } catch (e) {
      logger.warn(`futures.update_index_price failed market=${m}: ${(e as Error).message}`);
    }
  }
  // Update gas futures (no Pyth dependency)
  for (const m of GAS_FUTURES_MARKET_IDS) {
    try {
      const tx = new Transaction();
      tx.moveCall({
        target: `${config.pkgId}::gas_futures::update_index_price`,
        arguments: [tx.object(m), tx.object('0x6')],
      });
      const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true } });
      await client.waitForTransaction({ digest: res.digest });
      logger.debug(`gas_futures.update_index_price ok market=${m}`);
    } catch (e) {}
  }
}

// ===== Helper: dynamic fields enumeration (addresses from Table<address, T>) =====
async function listDynamicFieldAddresses(parentId: string, limit = 1000): Promise<Address[]> {
  let cursor: string | null = null;
  const out: Address[] = [];
  do {
    const page = await client.getDynamicFields({ parentId, cursor, limit });
    for (const e of page.data) {
      // For Table<address, T>, e.name.value is an address string
      const addr = (e.name as any)?.value as string;
      if (addr) out.push(addr);
    }
    cursor = page.nextCursor;
  } while (cursor);
  return out;
}

// ===== Helper: read table ids from markets =====
async function getAccountsTableIdFromMarket(marketId: string): Promise<string | null> {
  const obj = await client.getObject({ id: marketId, options: { showContent: true } });
  const fields = (obj.data as any)?.content?.fields;
  const tableId = fields?.accounts?.fields?.id?.id as string | undefined;
  return tableId || null;
}

async function getBorrowsTableIdFromLendingMarket(marketId: string): Promise<string | null> {
  const obj = await client.getObject({ id: marketId, options: { showContent: true } });
  const fields = (obj.data as any)?.content?.fields;
  const tableId = fields?.borrows?.fields?.id?.id as string | undefined;
  return tableId || null;
}

// ===== DevInspect helpers to pre-check liquidations =====
async function devInspectFuturesLiquidation(marketId: string, priceId: string, victim: Address): Promise<boolean> {
  try {
    const tx = new Transaction();
    const [priceInfoObjectId] = await updatePythFeedsOnTx(tx, [priceId]);
    // Call with maximal qty to let on-chain compute needed close up to side size
    const maxU64 = BigInt('18446744073709551615');
    tx.moveCall({
      target: `${config.pkgId}::futures::liquidate`,
      arguments: [
        tx.object(marketId),
        tx.pure.address(victim),
        tx.pure.u64(maxU64),
        tx.object(ORACLE_REGISTRY_ID),
        tx.object(priceInfoObjectId),
        tx.object(ensure(GLOBAL_FEE_VAULT_ID, 'GLOBAL_FEE_VAULT_ID')),
        tx.object(ensure(REWARDS_ID, 'REWARDS_ID')),
        tx.object(CLOCK_ID),
      ],
    });
    const res = await client.devInspectTransactionBlock({
      sender: keypair.getPublicKey().toSuiAddress(),
      transactionBlock: tx,
    } as any);
    return (res as any)?.effects?.status?.status === 'success';
  } catch (e) {
    return false;
  }
}

async function devInspectPerpLiquidation(marketId: string, priceId: string, victim: Address): Promise<boolean> {
  try {
    const tx = new Transaction();
    const [priceInfoObjectId] = await updatePythFeedsOnTx(tx, [priceId]);
    const maxU64 = BigInt('18446744073709551615');
    // Note: perps::liquidate signature puts qty last
    tx.moveCall({
      target: `${config.pkgId}::perpetuals::liquidate`,
      arguments: [
        tx.object(marketId),
        tx.pure.address(victim),
        tx.object(ORACLE_REGISTRY_ID),
        tx.object(priceInfoObjectId),
        tx.object(ensure(GLOBAL_FEE_VAULT_ID, 'GLOBAL_FEE_VAULT_ID')),
        tx.object(ensure(REWARDS_ID, 'REWARDS_ID')),
        tx.object(CLOCK_ID),
        tx.pure.u64(maxU64),
      ],
    });
    const res = await client.devInspectTransactionBlock({
      sender: keypair.getPublicKey().toSuiAddress(),
      transactionBlock: tx,
    } as any);
    return (res as any)?.effects?.status?.status === 'success';
  } catch {
    return false;
  }
}

async function devInspectGasFuturesLiquidation(marketId: string, victim: Address): Promise<boolean> {
  try {
    const tx = new Transaction();
    const maxU64 = BigInt('18446744073709551615');
    tx.moveCall({
      target: `${config.pkgId}::gas_futures::liquidate`,
      arguments: [
        tx.object(marketId),
        tx.pure.address(victim),
        tx.pure.u64(maxU64),
        tx.object(ensure(GLOBAL_FEE_VAULT_ID, 'GLOBAL_FEE_VAULT_ID')),
        tx.object(ensure(REWARDS_ID, 'REWARDS_ID')),
        tx.object(CLOCK_ID),
      ],
    });
    const res = await client.devInspectTransactionBlock({
      sender: keypair.getPublicKey().toSuiAddress(),
      transactionBlock: tx,
    } as any);
    return (res as any)?.effects?.status?.status === 'success';
  } catch {
    return false;
  }
}

async function devInspectLendingIsUnhealthy(marketId: string, symbolPriceId: string, who: Address, typeArgs: { collat: string; debt: string }): Promise<boolean> {
  try {
    const tx = new Transaction();
    const [priceInfoObjectId] = await updatePythFeedsOnTx(tx, [symbolPriceId]);
    tx.moveCall({
      target: `${config.pkgId}::lending::is_healthy_market`,
      typeArguments: [typeArgs.collat, typeArgs.debt],
      arguments: [
        tx.object(marketId),
        tx.pure.address(who),
        tx.object(ORACLE_REGISTRY_ID),
        tx.object(priceInfoObjectId),
        tx.object(CLOCK_ID),
      ],
    });
    const res = await client.devInspectTransactionBlock({ sender: keypair.getPublicKey().toSuiAddress(), transactionBlock: tx } as any);
    // devInspect returns return values in results; last return is a bool
    const r = (res as any)?.results?.[0]?.returnValues?.[0]?.[0];
    // r is base64-encoded bcs bool; decode and interpret (0x00 false, 0x01 true)
    if (!r) return false;
    const bytes: Uint8Array = fromBase64(r);
    const healthy = bytes.length > 0 && bytes[0] === 1;
    return !healthy;
  } catch {
    return false;
  }
}

// ===== Liquidation executors =====
async function liquidateFuturesMarket(marketId: string, priceId: string, victims: Address[]): Promise<void> {
  if (!victims.length) return;
  const tx = new Transaction();
  const [priceInfoObjectId] = await updatePythFeedsOnTx(tx, [priceId]);
  const maxU64 = BigInt('18446744073709551615');
  // Batch a few victims per tx
  for (const v of victims.slice(0, MAX_LIQUIDATIONS_PER_MARKET)) {
    tx.moveCall({
      target: `${config.pkgId}::futures::liquidate`,
      arguments: [
        tx.object(marketId),
        tx.pure.address(v),
        tx.pure.u64(maxU64),
        tx.object(ORACLE_REGISTRY_ID),
        tx.object(priceInfoObjectId),
        tx.object(ensure(GLOBAL_FEE_VAULT_ID, 'GLOBAL_FEE_VAULT_ID')),
        tx.object(ensure(REWARDS_ID, 'REWARDS_ID')),
        tx.object(CLOCK_ID),
      ],
    });
  }
  const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true } });
  await client.waitForTransaction({ digest: res.digest });
  logger.info(`futures.liquidate ok market=${marketId} victims=${Math.min(victims.length, MAX_LIQUIDATIONS_PER_MARKET)}`);
}

async function liquidatePerpMarket(marketId: string, priceId: string, victims: Address[]): Promise<void> {
  if (!victims.length) return;
  const tx = new Transaction();
  const [priceInfoObjectId] = await updatePythFeedsOnTx(tx, [priceId]);
  const maxU64 = BigInt('18446744073709551615');
  for (const v of victims.slice(0, MAX_LIQUIDATIONS_PER_MARKET)) {
    tx.moveCall({
      target: `${config.pkgId}::perpetuals::liquidate`,
      arguments: [
        tx.object(marketId),
        tx.pure.address(v),
        tx.object(ORACLE_REGISTRY_ID),
        tx.object(priceInfoObjectId),
        tx.object(ensure(GLOBAL_FEE_VAULT_ID, 'GLOBAL_FEE_VAULT_ID')),
        tx.object(ensure(REWARDS_ID, 'REWARDS_ID')),
        tx.object(CLOCK_ID),
        tx.pure.u64(maxU64),
      ],
    });
  }
  const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true } });
  await client.waitForTransaction({ digest: res.digest });
  logger.info(`perpetuals.liquidate ok market=${marketId} victims=${Math.min(victims.length, MAX_LIQUIDATIONS_PER_MARKET)}`);
}

async function liquidateGasFuturesMarket(marketId: string, victims: Address[]): Promise<void> {
  if (!victims.length) return;
  const tx = new Transaction();
  const maxU64 = BigInt('18446744073709551615');
  for (const v of victims.slice(0, MAX_LIQUIDATIONS_PER_MARKET)) {
    tx.moveCall({
      target: `${config.pkgId}::gas_futures::liquidate`,
      arguments: [
        tx.object(marketId),
        tx.pure.address(v),
        tx.pure.u64(maxU64),
        tx.object(ensure(GLOBAL_FEE_VAULT_ID, 'GLOBAL_FEE_VAULT_ID')),
        tx.object(ensure(REWARDS_ID, 'REWARDS_ID')),
        tx.object(CLOCK_ID),
      ],
    });
  }
  const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true } });
  await client.waitForTransaction({ digest: res.digest });
  logger.info(`gas_futures.liquidate ok market=${marketId} victims=${Math.min(victims.length, MAX_LIQUIDATIONS_PER_MARKET)}`);
}

// Lending liquidation (non-flash): uses keeper's Debt coin balance to repay and seize Collat
// Requires config.lending.markets[*].keeperDebtCoinId (object id of a Coin<Debt> owned by the keeper wallet)
async function liquidateLendingMarketOnce(args: { marketId: string; collat: string; debt: string; symbolPriceId: string; keeperDebtCoinId?: string }): Promise<void> {
  const { marketId, collat, debt, symbolPriceId, keeperDebtCoinId } = args;
  const borrowsId = await getBorrowsTableIdFromLendingMarket(marketId);
  if (!borrowsId) return;
  const borrowers = await listDynamicFieldAddresses(borrowsId);
  if (!borrowers.length) return;

  // Pre-filter unhealthy via devInspect
  const unhealthy: Address[] = [];
  for (const who of borrowers.slice(0, MAX_HEALTH_CHECKS_PER_MARKET)) {
    const bad = await devInspectLendingIsUnhealthy(marketId, symbolPriceId, who, { collat, debt });
    if (bad) unhealthy.push(who);
  }
  if (!unhealthy.length) return;

  if (!keeperDebtCoinId) {
    logger.warn(`Lending liquidation skipped for market=${marketId}: keeperDebtCoinId missing`);
    return;
  }

  const tx = new Transaction();
  const [priceInfoObjectId] = await updatePythFeedsOnTx(tx, [symbolPriceId]);
  let processed = 0;
  for (const who of unhealthy) {
    if (processed >= MAX_LIQUIDATIONS_PER_MARKET) break;
    // Use a conservative repay chunk; on-chain will cap by owed
    const repayAmt = BigInt(1_000_000);
    const [repayCoin] = tx.splitCoins(tx.object(keeperDebtCoinId), [tx.pure.u64(repayAmt)]);
    const leftoverDebt = tx.moveCall({
      target: `${config.pkgId}::lending::liquidate2`,
      typeArguments: [collat, debt],
      arguments: [tx.object(marketId), tx.pure.address(who), repayCoin, tx.object(ORACLE_REGISTRY_ID), tx.object(priceInfoObjectId), tx.object(CLOCK_ID)],
    });
    // Merge any leftover debt back into keeper's coin
    tx.mergeCoins(tx.object(keeperDebtCoinId), [leftoverDebt]);
    processed++;
  }
  if (processed > 0) {
    const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true } });
    await client.waitForTransaction({ digest: res.digest });
    logger.info(`lending.liquidate2 ok market=${marketId} victims=${processed}`);
  }
}

/**
 * Keeper: snap settlement prices for any markets past expiry. We attempt all; settled ones will revert gracefully.
 */
async function snapSettlements(): Promise<void> {
  // Futures snap
  for (const m of FUTURES_MARKET_IDS) {
    try {
      const priceId = config.futures.priceIdByMarket[m];
      const expiryMs = config.futures.expiryMsByMarket?.[m] ?? 0;
      if (!priceId) { continue; }
      if (!expiryMs || expiryMs <= 0) { continue; }
      const tx = new Transaction();
      const [priceInfoObjectId] = await updatePythFeedsOnTx(tx, [priceId]);
      tx.moveCall({
        target: `${config.pkgId}::futures::snap_settlement_price`,
        arguments: [tx.object(m), tx.object(ORACLE_REGISTRY_ID), tx.object(priceInfoObjectId), tx.object('0x6')],
      });
      const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true } });
      await client.waitForTransaction({ digest: res.digest });
      logger.info(`futures.snap_settlement_price ok market=${m}`);
    } catch (e) {
      // Ignore if not yet expired or already settled
    }
  }
  // Gas futures snap
  for (const m of GAS_FUTURES_MARKET_IDS) {
    try {
      const expiryMs = config.gasFutures.expiryMsByMarket?.[m] ?? 0;
      if (!expiryMs || expiryMs <= 0) { continue; }
      const tx = new Transaction();
      tx.moveCall({
        target: `${config.pkgId}::gas_futures::snap_settlement_price`,
        arguments: [tx.object(m), tx.object('0x6')],
      });
      const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true } });
      await client.waitForTransaction({ digest: res.digest });
      logger.info(`gas_futures.snap_settlement_price ok market=${m}`);
    } catch (e) {}
  }
}

/**
 * Options: sweep expired orders for each market/series key.
 * This requires you to provide the list of series keys per market; for simplicity
 * we accept a comma-separated list in env per market: UNXV_OPTIONS_SERIES_<index>
 */
async function sweepExpiredOptions(): Promise<void> {
  const clockId = '0x6';
  for (let i = 0; i < OPTIONS_MARKET_IDS.length; i++) {
    const marketId = OPTIONS_MARKET_IDS[i];
    const seriesList = config.options.seriesByMarket[marketId] || [];
    for (const key of seriesList) {
      try {
        const tx = new Transaction();
        tx.moveCall({
          target: `${config.pkgId}::options::sweep_expired_orders`,
          arguments: [tx.object(marketId), tx.pure.u128(BigInt(key)), tx.pure.u64(OPTIONS_SWEEP_MAX), tx.object(clockId)],
        });
        const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true } });
        await client.waitForTransaction({ digest: res.digest });
        logger.info(`options.sweep_expired_orders ok market=${marketId} series=${key}`);
      } catch (e) {
        logger.warn(`options.sweep_expired_orders failed market=${marketId} series=${key}: ${(e as Error).message}`);
      }
    }
  }
}

/**
 * Perpetuals: apply funding index update periodically (admin), using a provided delta.
 * You must compute the delta off-chain (e.g., mid-price premium/discount vs. index) and pass via env.
 */
async function applyPerpFunding(): Promise<void> {
  const delta1e6 = config.perps.fundingDelta1e6 || 0;
  const longsPay = config.perps.longsPay ?? true;
  if (!delta1e6 || !PERP_MARKET_IDS.length) return;
  for (const m of PERP_MARKET_IDS) {
    try {
      const tx = new Transaction();
      tx.moveCall({
        target: `${config.pkgId}::perpetuals::apply_funding_update`,
        arguments: [tx.object(ADMIN_REGISTRY_ID), tx.object(m), tx.pure.bool(longsPay), tx.pure.u64(delta1e6), tx.object('0x6')],
      });
      const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true } });
      await client.waitForTransaction({ digest: res.digest });
      logger.info(`perpetuals.apply_funding_update ok market=${m} delta=${delta1e6} longsPay=${longsPay}`);
    } catch (e) {
      logger.warn(`perpetuals.apply_funding_update failed market=${m}: ${(e as Error).message}`);
    }
  }
}

/**
 * Lending: sweep reserves from pools into the FeeVault per config.
 */
async function sweepLendingReserves(): Promise<void> {
  if (!LENDING_CFG || !LENDING_CFG.markets?.length) return;
  const feeVaultId = LENDING_CFG.feeVaultId;
  if (!feeVaultId) return;
  for (const m of LENDING_CFG.markets) {
    const amount = (m.sweepAmount ?? LENDING_CFG.defaultSweepAmount ?? 0);
    if (!amount || amount <= 0) continue;
    try {
      const tx = new Transaction();
      tx.moveCall({
        target: `${config.pkgId}::lending::sweep_debt_reserves_to_fee_vault`,
        typeArguments: [m.collat.startsWith('0x') || m.collat.startsWith('::') ? (m.collat.startsWith('::') ? `${config.pkgId}${m.collat}` : m.collat) : `${config.pkgId}::${m.collat}`,
                       m.debt.startsWith('0x') || m.debt.startsWith('::') ? (m.debt.startsWith('::') ? `${config.pkgId}${m.debt}` : m.debt) : `${config.pkgId}::${m.debt}`],
        arguments: [tx.object(ADMIN_REGISTRY_ID), tx.object(m.marketId), tx.object(feeVaultId), tx.pure.u64(amount), tx.object('0x6')],
      } as any);
      const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true } });
      await client.waitForTransaction({ digest: res.digest });
      logger.info(`lending.sweep_debt_reserves_to_fee_vault ok market=${m.marketId} amount=${amount}`);
    } catch (e) {
      logger.warn(`lending.sweep_debt_reserves_to_fee_vault failed market=${m.marketId}: ${(e as Error).message}`);
    }
  }
}

/**
 * Lending: accrue interest (soft) via a zero-op that calls accrue internally.
 * We can trigger a 0-amount deposit to force accrue path without changing state; alternatively, add explicit keeper entry if needed.
 * Here we call set_params with current values to emit an Accrued event is not ideal; better pattern is a dedicated entry accrue.
 * Since module exposes public accrue<T>(pool,&Clock), we can include it in a moveCall only if exposed as entry. If not, we can piggyback on a read path that calls accrue—omitted.
 * For now, we skip automatic lend-accrual cron (not an entry function) and rely on user-tx paths.
 */

/**
 * Oracle registry maintenance: set feeds for symbols or adjust staleness.
 */
async function oracleSetFeed(symbol: string, aggregatorId: string): Promise<void> {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.pkgId}::oracle::set_feed`,
    arguments: [tx.object(ADMIN_REGISTRY_ID), tx.object(ORACLE_REGISTRY_ID), tx.pure.string(symbol), tx.object(aggregatorId), tx.object('0x6')],
  });
  const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true } });
  await client.waitForTransaction({ digest: res.digest });
  logger.info(`Oracle set_feed symbol=${symbol} agg=${aggregatorId}`);
}

async function oracleSetMaxAge(seconds: number): Promise<void> {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.pkgId}::oracle::set_max_age_registry`,
    arguments: [tx.object(ADMIN_REGISTRY_ID), tx.object(ORACLE_REGISTRY_ID), tx.pure.u64(seconds), tx.object('0x6')],
  });
  const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true } });
  await client.waitForTransaction({ digest: res.digest });
  logger.info(`Oracle max_age set to ${seconds}s`);
}

/**
 * Gas futures/futures: no explicit cron required beyond oracle updates; trading/liquidation are user/keeper driven.
 * Treasury/fees: optional convert-to-quote cron could be added using fees::admin_convert_fee_balance_via_pool.
 */

async function runCron(): Promise<void> {
  logger.info(`Cron started on ${NETWORK}`);
  for (;;) {
    await Promise.allSettled([
      (async () => { /* pyth updates done inline per-market */ })(),
      (async () => { await sweepExpiredOptions(); })(),
      (async () => { await applyPerpFunding(); })(),
      (async () => { await refreshIndexPrices(); })(),
      (async () => { await snapSettlements(); })(),
      (async () => { await sweepLendingReserves(); })(),
      // Futures liquidations (price-driven; we use devInspect precheck to avoid reverts)
      (async () => {
        try {
          const victimsByMarket: Record<string, Address[]> = {};
          const now = nowMs();
          for (const m of FUTURES_MARKET_IDS) {
            // Only sweep periodically to avoid heavy scans; hot-set subscription can be added separately
            const lastKey = `fut:${m}`;
            (globalThis as any)._unxv_lastSweep = (globalThis as any)._unxv_lastSweep || new Map<string, number>();
            const last = (globalThis as any)._unxv_lastSweep.get(lastKey) || 0;
            if (now - last < FULL_SWEEP_INTERVAL_MS) continue;
            (globalThis as any)._unxv_lastSweep.set(lastKey, now);
            const tableId = await getAccountsTableIdFromMarket(m);
            if (!tableId) continue;
            const addrs = await listDynamicFieldAddresses(tableId);
            const priceId = config.futures.priceIdByMarket[m];
            if (!priceId || !addrs.length) continue;
            const candidates: Address[] = [];
            for (const a of addrs.slice(0, MAX_HEALTH_CHECKS_PER_MARKET)) {
              const ok = await devInspectFuturesLiquidation(m, priceId, a);
              if (ok) candidates.push(a);
            }
            if (candidates.length) victimsByMarket[m] = candidates;
            logger.debug(`futures scan market=${m} scanned=${addrs.length} candidates=${candidates.length}`);
          }
          for (const m of Object.keys(victimsByMarket)) {
            await liquidateFuturesMarket(m, config.futures.priceIdByMarket[m], victimsByMarket[m]);
          }
        } catch (e) {}
      })(),
      // Perps liquidations
      (async () => {
        try {
          const victimsByMarket: Record<string, Address[]> = {};
          const now = nowMs();
          for (const m of PERP_MARKET_IDS) {
            const lastKey = `perp:${m}`;
            (globalThis as any)._unxv_lastSweep = (globalThis as any)._unxv_lastSweep || new Map<string, number>();
            const last = (globalThis as any)._unxv_lastSweep.get(lastKey) || 0;
            if (now - last < FULL_SWEEP_INTERVAL_MS) continue;
            (globalThis as any)._unxv_lastSweep.set(lastKey, now);
            const tableId = await getAccountsTableIdFromMarket(m);
            if (!tableId) continue;
            const addrs = await listDynamicFieldAddresses(tableId);
            const priceId = config.perps.priceIdByMarket[m];
            if (!priceId || !addrs.length) continue;
            const candidates: Address[] = [];
            for (const a of addrs.slice(0, MAX_HEALTH_CHECKS_PER_MARKET)) {
              const ok = await devInspectPerpLiquidation(m, priceId, a);
              if (ok) candidates.push(a);
            }
            if (candidates.length) victimsByMarket[m] = candidates;
            logger.debug(`perps scan market=${m} scanned=${addrs.length} candidates=${candidates.length}`);
          }
          for (const m of Object.keys(victimsByMarket)) {
            await liquidatePerpMarket(m, config.perps.priceIdByMarket[m], victimsByMarket[m]);
          }
        } catch (e) {}
      })(),
      // Gas futures liquidations
      (async () => {
        try {
          const victimsByMarket: Record<string, Address[]> = {};
          const now = nowMs();
          for (const m of GAS_FUTURES_MARKET_IDS) {
            const lastKey = `gas:${m}`;
            (globalThis as any)._unxv_lastSweep = (globalThis as any)._unxv_lastSweep || new Map<string, number>();
            const last = (globalThis as any)._unxv_lastSweep.get(lastKey) || 0;
            if (now - last < FULL_SWEEP_INTERVAL_MS) continue;
            (globalThis as any)._unxv_lastSweep.set(lastKey, now);
            const tableId = await getAccountsTableIdFromMarket(m);
            if (!tableId) continue;
            const addrs = await listDynamicFieldAddresses(tableId);
            if (!addrs.length) continue;
            const candidates: Address[] = [];
            for (const a of addrs.slice(0, MAX_HEALTH_CHECKS_PER_MARKET)) {
              const ok = await devInspectGasFuturesLiquidation(m, a);
              if (ok) candidates.push(a);
            }
            if (candidates.length) victimsByMarket[m] = candidates;
            logger.debug(`gas_futures scan market=${m} scanned=${addrs.length} candidates=${candidates.length}`);
          }
          for (const m of Object.keys(victimsByMarket)) {
            await liquidateGasFuturesMarket(m, victimsByMarket[m]);
          }
        } catch (e) {}
      })(),
      // Lending liquidations (requires dexPoolId per market to swap seized collateral to Debt)
      (async () => {
        try {
          if (!LENDING_CFG || !LENDING_CFG.markets?.length) return;
          const now = nowMs();
          for (const m of LENDING_CFG.markets) {
            const lastKey = `lend:${m.marketId}`;
            (globalThis as any)._unxv_lastSweep = (globalThis as any)._unxv_lastSweep || new Map<string, number>();
            const last = (globalThis as any)._unxv_lastSweep.get(lastKey) || 0;
            if (now - last < FULL_SWEEP_INTERVAL_MS) continue;
            (globalThis as any)._unxv_lastSweep.set(lastKey, now);
            const symbolPriceId = (config as any).lending?.priceIdByMarket?.[m.marketId] || (config.futures.priceIdByMarket as any)[m.marketId] || '';
            if (!symbolPriceId) continue;
            const keeperDebtCoinId = (m as any).keeperDebtCoinId as string | undefined;
            await liquidateLendingMarketOnce({ marketId: m.marketId, collat: (m as any).collat, debt: (m as any).debt, symbolPriceId, keeperDebtCoinId });
            logger.debug(`lending scan market=${m.marketId} done`);
          }
        } catch (e) {}
      })(),
    ]);
    await sleep(CRON_SLEEP_MS);
  }
}

runCron().catch((err) => {
  console.error(err);
  process.exit(1);
});
