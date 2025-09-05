import { logger } from './utils/logger.js';
import { sleep } from './utils/time.js';
import { config } from './config.js';
import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Aggregator, SwitchboardClient } from '@switchboard-xyz/sui-sdk';

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
const SWITCHBOARD_AGGREGATOR_IDS = config.switchboard.aggregatorIds;
const CRON_SLEEP_MS = config.cron.sleepMs;

// Keypair for admin/keeper
const ADMIN_SEED_B64 = process.env.UNXV_ADMIN_SEED_B64 || '';
const keypair = ADMIN_SEED_B64 ? Ed25519Keypair.fromSecretKey(Buffer.from(ADMIN_SEED_B64, 'base64')) : Ed25519Keypair.generate();

const client = new SuiClient({ url: getFullnodeUrl(NETWORK) });

/**
 * Switchboard: update all configured aggregators.
 * Per docs: aggregator.fetchUpdateTx(tx) should be first in the PTB.
 */
async function updateSwitchboardFeeds(): Promise<void> {
  if (!SWITCHBOARD_AGGREGATOR_IDS.length) return;
  const sb = new SwitchboardClient(client);
  for (const aggId of SWITCHBOARD_AGGREGATOR_IDS) {
    try {
      const aggregator = new Aggregator(sb, aggId);
      const tx = new Transaction();
      await aggregator.fetchUpdateTx(tx);
      const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true } });
      await client.waitForTransaction({ digest: res.digest });
      logger.info(`Switchboard updated: ${aggId}`);
    } catch (e) {
      logger.error(`Switchboard update failed for ${aggId}: ${(e as Error).message}`);
    }
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
        logger.info(`Options sweep ok market=${marketId} series=${key}`);
      } catch (e) {
        logger.error(`Options sweep failed market=${marketId} series=${key}: ${(e as Error).message}`);
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
      logger.info(`Perp funding applied market=${m} delta=${delta1e6} longsPay=${longsPay}`);
    } catch (e) {
      logger.error(`Perp funding failed market=${m}: ${(e as Error).message}`);
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
    arguments: [tx.object(ADMIN_REGISTRY_ID), tx.object(ORACLE_REGISTRY_ID), tx.pure.string(symbol), tx.object(aggregatorId)],
  });
  const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true } });
  await client.waitForTransaction({ digest: res.digest });
  logger.info(`Oracle set_feed symbol=${symbol} agg=${aggregatorId}`);
}

async function oracleSetMaxAge(seconds: number): Promise<void> {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.pkgId}::oracle::set_max_age_registry`,
    arguments: [tx.object(ADMIN_REGISTRY_ID), tx.object(ORACLE_REGISTRY_ID), tx.pure.u64(seconds)],
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
      (async () => { await updateSwitchboardFeeds(); })(),
      (async () => { await sweepExpiredOptions(); })(),
      (async () => { await applyPerpFunding(); })(),
    ]);
    await sleep(CRON_SLEEP_MS);
  }
}

runCron().catch((err) => {
  console.error(err);
  process.exit(1);
});
