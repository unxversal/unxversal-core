import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { logger } from '../utils/logger.js';
import { deployConfig, type DeployConfig } from './config.js';
import { writeFile } from 'node:fs/promises';
import { DeepBookClient } from '@mysten/deepbook-v3';
import { MAINNET_DERIVATIVE_TYPE_TAGS, TESTNET_DERIVATIVE_TYPE_TAGS } from './markets.js';
// xperps deployer is defined locally; builders are wired via config
import path from 'node:path';
import { fileURLToPath } from 'node:url';

type DeployedOptions = { marketId: string; base: string; quote: string; series: Array<{ expiryMs: number; strike1e6: number; isCall: boolean; symbol: string }> };
type DeployedFutures = {
  marketId: string;
  collat: string;
  symbol: string;
  expiryMs?: number;
  contractSize: number;
  tickSize?: number;
  lotSize?: number;
  minSize?: number;
  initialMarginBps: number;
  maintenanceMarginBps: number;
  liquidationFeeBps: number;
  keeperIncentiveBps: number;
  accountMaxNotional1e6?: string;
  marketMaxNotional1e6?: string;
  accountShareOfOiBps?: number;
  tierThresholds1e6?: number[];
  tierImBps?: number[];
  closeOnly?: boolean;
  maxDeviationBps?: number;
  pnlFeeShareBps?: number;
  liqTargetBufferBps?: number;
  imbalanceParams?: { surchargeMaxBps: number; thresholdBps: number };
};
type DeployedGasFutures = {
  marketId: string;
  collat: string;
  expiryMs: number;
  contractSize: number;
  tickSize?: number;
  lotSize?: number;
  minSize?: number;
  initialMarginBps: number;
  maintenanceMarginBps: number;
  liquidationFeeBps: number;
  keeperIncentiveBps: number;
  accountMaxNotional1e6?: string;
  marketMaxNotional1e6?: string;
  accountShareOfOiBps?: number;
  tierThresholds1e6?: number[];
  tierImBps?: number[];
  closeOnly?: boolean;
  maxDeviationBps?: number;
  pnlFeeShareBps?: number;
  liqTargetBufferBps?: number;
  imbalanceParams?: { surchargeMaxBps: number; thresholdBps: number };
};
type DeployedPerp = {
  marketId: string;
  collat: string;
  symbol: string;
  contractSize: number;
  fundingIntervalMs: number;
  tickSize?: number;
  lotSize?: number;
  minSize?: number;
  initialMarginBps: number;
  maintenanceMarginBps: number;
  liquidationFeeBps: number;
  keeperIncentiveBps: number;
  accountMaxNotional1e6?: string;
  marketMaxNotional1e6?: string;
  accountShareOfOiBps?: number;
  tierThresholds1e6?: number[];
  tierImBps?: number[];
};
type DeployedDexPool = { poolId: string; base: string; quote: string; tickSize: number; lotSize: number; minSize: number; registryId: string };
type DeployedXPerp = DeployedPerp & { symbol: string };

// Collect every raw response from signAndExecuteTransaction
const txResponses: Array<{ label: string; digest?: string; response: any }> = [];

type DeploymentSummary = {
  network: string;
  timestampMs: number;
  pkgId: string;
  adminRegistryId: string;
  feeConfigId: string;
  feeVaultId: string;
  stakingPoolId: string;
  usduFaucetId?: string;
  oracleRegistryId?: string;
  additionalAdmins?: string[];
  feeParams?: DeployConfig['feeParams'];
  feeTiers?: DeployConfig['feeTiers'];
  lendingParams?: DeployConfig['lendingParams'];
  poolCreationFeeUnxv?: DeployConfig['poolCreationFeeUnxv'];
  tradeFees?: DeployConfig['tradeFees'];
  oracleMaxAgeSec?: number;
  oracleFeeds?: NonNullable<DeployConfig['oracleFeeds']>;
  // Newly observed package ids and object types from created objects during this run
  createdPackageIds: string[];
  createdObjectTypes: string[];
  lending: Array<{
    marketId: string;
    collat: string;
    debt: string;
    symbol: string;
    baseRateBps?: number;
    multiplierBps?: number;
    jumpMultiplierBps?: number;
    kinkUtilBps?: number;
    reserveFactorBps?: number;
    collateralFactorBps?: number;
    liquidationThresholdBps?: number;
    liquidationBonusBps?: number;
  }>;
  options: DeployedOptions[];
  futures: DeployedFutures[];
  gasFutures: DeployedGasFutures[];
  perpetuals: DeployedPerp[];
  dexPools: DeployedDexPool[];
  vaults: Array<{ id: string; asset: string }>;
  xperps: DeployedXPerp[];
};

function kpFromEnv(): Ed25519Keypair {
  const mnemonic = process.env.UNXV_ADMIN_MNEMONIC || process.env.UNXV_ADMIN_SEED_PHRASE || '';
  if (mnemonic) {
    return Ed25519Keypair.deriveKeypair(mnemonic);
  }
  const b64 = process.env.UNXV_ADMIN_SEED_B64 || '';
  if (b64) {
    return Ed25519Keypair.fromSecretKey(Buffer.from(b64, 'base64'));
  }
  throw new Error('Set UNXV_ADMIN_MNEMONIC (preferred) or UNXV_ADMIN_SEED_B64');
}

async function execTx(client: SuiClient, tx: Transaction, keypair: Ed25519Keypair, label: string) {
  logger.debug(`[tx] preparing ${label}`);
  const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true, showObjectChanges: true } });
  await client.waitForTransaction({ digest: res.digest });
  logger.info(`${label}: ${res.digest}`);
  try {
    txResponses.push({ label, digest: res.digest, response: res });
  } catch (_) {
    // best-effort; ignore serialization issues
  }
  return res;
}

function extractCreatedId(res: any, typeContains: string): string | undefined {
  const changes: any[] = res.objectChanges || [];
  for (const oc of changes) {
    if (oc.type === 'created' && typeof oc.objectType === 'string' && oc.objectType.includes(typeContains)) {
      return oc.objectId as string;
    }
  }
  const effectsCreated: any[] = res.effects?.created || [];
  for (const c of effectsCreated) {
    if (c.reference?.objectId) return c.reference.objectId as string;
  }
  return undefined;
}

function resolveTypeTag(tag: string, pkgId: string): string {
  if (!tag) return tag;
  if (tag.startsWith('0x')) return tag;
  if (tag.startsWith('::')) return `${pkgId}${tag}`;
  // Common shorthand
  if (tag === 'SUI') return '0x2::sui::SUI';
  // If module path lacks address, prefix with pkgId
  return `${pkgId}::${tag}`;
}

function accumulateFromRes(res: any, summary: DeploymentSummary) {
  const changes: any[] = res?.objectChanges || [];
  const pkgSet = new Set(summary.createdPackageIds);
  const typeSet = new Set(summary.createdObjectTypes);
  for (const oc of changes) {
    if (oc?.type === 'created' && typeof oc.objectType === 'string') {
      typeSet.add(oc.objectType as string);
      const typeStr: string = oc.objectType as string;
      const pkg = typeStr.split('::')[0];
      if (pkg && pkg.startsWith('0x')) pkgSet.add(pkg);
    }
  }
  summary.createdPackageIds = Array.from(pkgSet);
  summary.createdObjectTypes = Array.from(typeSet);
}

async function ensureOracleRegistry(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair, summary: DeploymentSummary): Promise<string> {
  if (cfg.oracleRegistryId) {
    logger.info(`oracle.init_registry skipped (reusing registry ${cfg.oracleRegistryId})`);
    return cfg.oracleRegistryId;
  }
  logger.info('oracle.init_registry starting');
  const tx = new Transaction();
  tx.moveCall({ target: `${cfg.pkgId}::oracle::init_registry`, arguments: [tx.object(cfg.adminRegistryId), tx.object('0x6')] });
  const res = await execTx(client, tx, keypair, 'oracle.init_registry');
  accumulateFromRes(res, summary);
  const id = extractCreatedId(res, `${cfg.pkgId}::oracle::OracleRegistry`)
    || extractCreatedId(res, `${cfg.pkgId}::oracle::OracleRegistry`)
    || '';
  return id;
}

async function setOracleParams(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair) {
  if (cfg.oracleMaxAgeSec && cfg.oracleRegistryId) {
    logger.info(`oracle.set_max_age -> ${cfg.oracleMaxAgeSec}s on registry ${cfg.oracleRegistryId}`);
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::oracle::set_max_age_registry`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.oracleRegistryId), tx.pure.u64(cfg.oracleMaxAgeSec), tx.object('0x6')] });
    await execTx(client, tx, keypair, 'oracle.set_max_age');
  }
  if (cfg.oracleFeeds && cfg.oracleFeeds.length && cfg.oracleRegistryId) {
    logger.info(`oracle.set_feed_from_bytes for ${cfg.oracleFeeds.length} feeds`);
    for (const f of cfg.oracleFeeds) {
      logger.debug(`  feed ${f.symbol} -> ${f.priceId}`);
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.pkgId}::oracle::set_feed_from_bytes`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.oracleRegistryId), tx.pure.string(f.symbol), tx.pure.vector('u8', Array.from(Buffer.from(f.priceId.replace(/^0x/, ''), 'hex'))), tx.object('0x6')] as any });
      await execTx(client, tx, keypair, `oracle.set_feed_from_bytes ${f.symbol}`);
    }
  }
}

async function addAdditionalAdmins(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair) {
  if (!cfg.additionalAdmins || cfg.additionalAdmins.length === 0) return;
  logger.info(`admin.add_admin for ${cfg.additionalAdmins.length} addresses`);
  for (const addr of cfg.additionalAdmins) {
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::admin::add_admin`, arguments: [tx.object(cfg.adminRegistryId), tx.pure.address(addr)] });
    await execTx(client, tx, keypair, `admin.add_admin ${addr}`);
  }
}

async function updateFeeParams(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair) {
  if (cfg.feeParams) {
    const p = cfg.feeParams;
    logger.info('fees.set_params');
    logger.debug(JSON.stringify(p));
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.pkgId}::fees::set_params`,
      arguments: [
        tx.object(cfg.adminRegistryId),
        tx.object(cfg.feeConfigId),
        tx.pure.u64(p.dexFeeBps),
        tx.pure.u64(p.unxvDiscountBps),
        tx.pure.bool(p.preferDeepBackend),
        tx.pure.u64(p.stakersShareBps),
        tx.pure.u64(p.treasuryShareBps),
        tx.pure.u64(p.burnShareBps),
        tx.pure.address(p.treasury),
        tx.object('0x6'),
      ],
    });
    await execTx(client, tx, keypair, 'fees.set_params');
  }
  if (cfg.feeTiers) {
    const t = cfg.feeTiers;
    logger.info('fees.set_staking_tiers');
    logger.debug(JSON.stringify(t));
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.pkgId}::fees::set_staking_tiers`,
      arguments: [
        tx.object(cfg.adminRegistryId),
        tx.object(cfg.feeConfigId),
        tx.pure.u64(t.t1), tx.pure.u64(t.b1),
        tx.pure.u64(t.t2), tx.pure.u64(t.b2),
        tx.pure.u64(t.t3), tx.pure.u64(t.b3),
        tx.pure.u64(t.t4), tx.pure.u64(t.b4),
        tx.pure.u64(t.t5), tx.pure.u64(t.b5),
        tx.pure.u64(t.t6), tx.pure.u64(t.b6),
      ],
    });
    await execTx(client, tx, keypair, 'fees.set_staking_tiers');
  }
  if (cfg.tradeFees?.dex) {
    const t = cfg.tradeFees.dex;
    logger.info('fees.set_trade_fees (DEX)');
    logger.debug(JSON.stringify(t));
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::fees::set_trade_fees`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.feeConfigId), tx.pure.u64(t.takerBps), tx.pure.u64(t.makerBps)] });
    await execTx(client, tx, keypair, 'fees.set_trade_fees');
  }
  if (cfg.tradeFees?.futures) {
    const t = cfg.tradeFees.futures;
    logger.info('fees.set_futures_trade_fees');
    logger.debug(JSON.stringify(t));
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::fees::set_futures_trade_fees`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.feeConfigId), tx.pure.u64(t.takerBps), tx.pure.u64(t.makerBps)] });
    await execTx(client, tx, keypair, 'fees.set_futures_trade_fees');
  }
  if (cfg.tradeFees?.gasFutures) {
    const t = cfg.tradeFees.gasFutures;
    logger.info('fees.set_gasfutures_trade_fees');
    logger.debug(JSON.stringify(t));
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::fees::set_gasfutures_trade_fees`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.feeConfigId), tx.pure.u64(t.takerBps), tx.pure.u64(t.makerBps)] });
    await execTx(client, tx, keypair, 'fees.set_gasfutures_trade_fees');
  }
  if (cfg.lendingParams) {
    const lp = cfg.lendingParams;
    logger.info('fees.set_lending_params');
    logger.debug(JSON.stringify(lp));
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::fees::set_lending_params`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.feeConfigId), tx.pure.u64(lp.borrowFeeBps), tx.pure.u64(lp.collateralBonusMaxBps)] });
    await execTx(client, tx, keypair, 'fees.set_lending_params');
  }
  if (typeof cfg.poolCreationFeeUnxv === 'number') {
    logger.info(`fees.set_pool_creation_fee_unxv -> ${cfg.poolCreationFeeUnxv}`);
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::fees::set_pool_creation_fee_unxv`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.feeConfigId), tx.pure.u64(cfg.poolCreationFeeUnxv)] });
    await execTx(client, tx, keypair, 'fees.set_pool_creation_fee_unxv');
  }
}

async function applyUsduFaucetSettings(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair) {
  if (!cfg.usdu || !cfg.usduFaucetId) return;
  const { perAddressLimit, paused } = cfg.usdu;
  if (perAddressLimit != null) {
    logger.info(`usdu.set_per_address_limit -> ${perAddressLimit}`);
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::usdu::set_per_address_limit`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.usduFaucetId), tx.pure.u64(perAddressLimit), tx.object('0x6')] });
    await execTx(client, tx, keypair, 'usdu.set_per_address_limit');
  }
  if (paused != null) {
    logger.info(`usdu.set_paused -> ${paused}`);
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::usdu::set_paused`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.usduFaucetId), tx.pure.bool(paused), tx.object('0x6')] });
    await execTx(client, tx, keypair, 'usdu.set_paused');
  }
}

async function deployOptions(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair, summary: DeploymentSummary) {
  if (!cfg.options?.length) return;
  logger.info(`Deploying Options: ${cfg.options.length} market(s)`);
  for (const m of cfg.options) {
    let marketId = m.marketId;
    if (!marketId) {
      logger.debug(`options.init_market (base=${m.base}, quote=${m.quote})`);
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.pkgId}::options::init_market`, arguments: [tx.object(cfg.adminRegistryId)] });
      const res = await execTx(client, tx, keypair, 'options.init_market');
      accumulateFromRes(res, summary);
      marketId = extractCreatedId(res, `${cfg.pkgId}::options::OptionsMarket<`) || marketId;
      if (marketId) logger.info(`options.market created id=${marketId}`);
    }
    if (m.series?.length && marketId) {
      const symbol = m.series[0]?.symbol ?? '';
      logger.info(`Creating ${m.series.length} option series for market ${marketId} (${symbol})`);
      for (const s of m.series) {
        const tx = new Transaction();
        tx.moveCall({
          target: `${cfg.pkgId}::options::create_option_series`,
          typeArguments: [m.base, m.quote],
          arguments: [
            tx.object(cfg.adminRegistryId),
            tx.object(marketId),
            tx.pure.u64(s.expiryMs),
            tx.pure.u64(s.strike1e6),
            tx.pure.bool(s.isCall),
            tx.pure.string(s.symbol),
            tx.pure.u64(m.tickSize),
            tx.pure.u64(m.lotSize),
            tx.pure.u64(m.minSize),
            tx.pure.bool((s as any).cashSettled ?? false),
            tx.pure.u64((s as any).cap1e6 ?? 0),
          ],
        });
        const res = await execTx(client, tx, keypair, `options.create_series ${s.symbol}`);
        accumulateFromRes(res, summary);
      }
    }
    if (marketId) {
      summary.options.push({ marketId, base: m.base, quote: m.quote, series: m.series || [] });
    }
  }
}

async function deployFutures(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair, summary: DeploymentSummary) {
  if (!cfg.futures?.length) return;
  logger.info(`Deploying Futures: ${cfg.futures.length} market spec(s)`);
  for (const f of cfg.futures) {
    if (!f.marketId) {
      logger.debug(`futures.init_market symbol=${f.symbol} expiryMs=${(f as any).expiryMs ?? 0}`);
      const tx = new Transaction();
      tx.moveCall({
        target: `${cfg.pkgId}::futures::init_market`,
        typeArguments: [f.collat],
        arguments: [
          tx.object(cfg.adminRegistryId),
          tx.pure.u64((f as any).expiryMs ?? 0),
          tx.pure.string(f.symbol),
          tx.pure.u64(f.contractSize),
          tx.pure.u64(f.initialMarginBps),
          tx.pure.u64(f.maintenanceMarginBps),
          tx.pure.u64(f.liquidationFeeBps),
          tx.pure.u64((f as any).keeperIncentiveBps ?? 0),
          tx.pure.u64((f as any).tickSize ?? 0),
          tx.pure.u64((f as any).lotSize ?? 0),
          tx.pure.u64((f as any).minSize ?? 0),
        ],
      });
      const res = await execTx(client, tx, keypair, `futures.init_market ${f.symbol}`);
      accumulateFromRes(res, summary);
      const id = extractCreatedId(res, `${cfg.pkgId}::futures::FuturesMarket<`);
      if (id) logger.info(`futures.market created id=${id}`);
      if (id) summary.futures.push({
        marketId: id,
        collat: f.collat,
        symbol: f.symbol,
        expiryMs: (f as any).expiryMs,
        contractSize: f.contractSize,
        tickSize: (f as any).tickSize,
        lotSize: (f as any).lotSize,
        minSize: (f as any).minSize,
        initialMarginBps: f.initialMarginBps,
        maintenanceMarginBps: f.maintenanceMarginBps,
        liquidationFeeBps: f.liquidationFeeBps,
        keeperIncentiveBps: (f as any).keeperIncentiveBps ?? 0,
        accountMaxNotional1e6: (f as any).accountMaxNotional1e6,
        marketMaxNotional1e6: (f as any).marketMaxNotional1e6,
        accountShareOfOiBps: (f as any).accountShareOfOiBps,
        tierThresholds1e6: (f as any).tierThresholds1e6,
        tierImBps: (f as any).tierImBps,
        closeOnly: (f as any).closeOnly,
        maxDeviationBps: (f as any).maxDeviationBps,
        pnlFeeShareBps: (f as any).pnlFeeShareBps,
        liqTargetBufferBps: (f as any).liqTargetBufferBps,
        imbalanceParams: (f as any).imbalanceParams,
      });
      // Apply post-init admin knobs and risk controls for newly created market
      if (id) {
        const fc = f as any;
        if (typeof fc.closeOnly === 'boolean') {
          const t1 = new Transaction();
          t1.moveCall({ target: `${cfg.pkgId}::futures::set_close_only`, typeArguments: [f.collat], arguments: [t1.object(cfg.adminRegistryId), t1.object(id), t1.pure.bool(fc.closeOnly)] });
          await execTx(client, t1, keypair, `futures.set_close_only ${f.symbol}`);
        }
        if (typeof fc.maxDeviationBps === 'number') {
          const t2 = new Transaction();
          t2.moveCall({ target: `${cfg.pkgId}::futures::set_price_deviation_bps`, typeArguments: [f.collat], arguments: [t2.object(cfg.adminRegistryId), t2.object(id), t2.pure.u64(fc.maxDeviationBps)] });
          await execTx(client, t2, keypair, `futures.set_price_deviation_bps ${f.symbol}`);
        }
        if (typeof fc.pnlFeeShareBps === 'number') {
          const t3 = new Transaction();
          t3.moveCall({ target: `${cfg.pkgId}::futures::set_pnl_fee_share_bps`, typeArguments: [f.collat], arguments: [t3.object(cfg.adminRegistryId), t3.object(id), t3.pure.u64(fc.pnlFeeShareBps)] });
          await execTx(client, t3, keypair, `futures.set_pnl_fee_share_bps ${f.symbol}`);
        }
        if (typeof fc.liqTargetBufferBps === 'number') {
          const t4 = new Transaction();
          t4.moveCall({ target: `${cfg.pkgId}::futures::set_liq_target_buffer_bps`, typeArguments: [f.collat], arguments: [t4.object(cfg.adminRegistryId), t4.object(id), t4.pure.u64(fc.liqTargetBufferBps)] });
          await execTx(client, t4, keypair, `futures.set_liq_target_buffer_bps ${f.symbol}`);
        }
        if (fc.imbalanceParams) {
          const p = fc.imbalanceParams as { surchargeMaxBps: number; thresholdBps: number };
          const t5 = new Transaction();
          t5.moveCall({ target: `${cfg.pkgId}::futures::set_imbalance_params`, typeArguments: [f.collat], arguments: [t5.object(cfg.adminRegistryId), t5.object(id), t5.pure.u64(p.surchargeMaxBps), t5.pure.u64(p.thresholdBps)] });
          await execTx(client, t5, keypair, `futures.set_imbalance_params ${f.symbol}`);
        }
        if (fc.accountMaxNotional1e6 || fc.marketMaxNotional1e6) {
          const t6 = new Transaction();
          t6.moveCall({ target: `${cfg.pkgId}::futures::set_notional_caps`, typeArguments: [f.collat], arguments: [t6.object(cfg.adminRegistryId), t6.object(id), t6.pure.u128(BigInt(fc.accountMaxNotional1e6 || '0')), t6.pure.u128(BigInt(fc.marketMaxNotional1e6 || '0'))] as any });
          await execTx(client, t6, keypair, `futures.set_notional_caps ${f.symbol}`);
        }
        if (typeof fc.accountShareOfOiBps === 'number') {
          const t7 = new Transaction();
          t7.moveCall({ target: `${cfg.pkgId}::futures::set_share_of_oi_bps`, typeArguments: [f.collat], arguments: [t7.object(cfg.adminRegistryId), t7.object(id), t7.pure.u64(fc.accountShareOfOiBps)] });
          await execTx(client, t7, keypair, `futures.set_share_of_oi_bps ${f.symbol}`);
        }
        if (fc.tierThresholds1e6 && fc.tierImBps) {
          const thresholds = fc.tierThresholds1e6 as number[];
          const imbps = fc.tierImBps as number[];
          const t8 = new Transaction();
          t8.moveCall({ target: `${cfg.pkgId}::futures::set_risk_tiers`, typeArguments: [f.collat], arguments: [t8.object(cfg.adminRegistryId), t8.object(id), t8.pure.vector('u64', thresholds), t8.pure.vector('u64', imbps)] as any });
          await execTx(client, t8, keypair, `futures.set_risk_tiers ${f.symbol}`);
        }
      }
    } else {
      summary.futures.push({
        marketId: f.marketId,
        collat: f.collat,
        symbol: f.symbol,
        expiryMs: (f as any).expiryMs,
        contractSize: f.contractSize,
        tickSize: (f as any).tickSize,
        lotSize: (f as any).lotSize,
        minSize: (f as any).minSize,
        initialMarginBps: f.initialMarginBps,
        maintenanceMarginBps: f.maintenanceMarginBps,
        liquidationFeeBps: f.liquidationFeeBps,
        keeperIncentiveBps: (f as any).keeperIncentiveBps ?? 0,
        accountMaxNotional1e6: (f as any).accountMaxNotional1e6,
        marketMaxNotional1e6: (f as any).marketMaxNotional1e6,
        accountShareOfOiBps: (f as any).accountShareOfOiBps,
        tierThresholds1e6: (f as any).tierThresholds1e6,
        tierImBps: (f as any).tierImBps,
        closeOnly: (f as any).closeOnly,
        maxDeviationBps: (f as any).maxDeviationBps,
        pnlFeeShareBps: (f as any).pnlFeeShareBps,
        liqTargetBufferBps: (f as any).liqTargetBufferBps,
        imbalanceParams: (f as any).imbalanceParams,
      });
      if (typeof (f as any).keeperIncentiveBps === 'number' && f.marketId) {
        const tx = new Transaction();
        tx.moveCall({ target: `${cfg.pkgId}::futures::set_keeper_incentive_bps`, typeArguments: [f.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(f.marketId), tx.pure.u64((f as any).keeperIncentiveBps)] });
        await execTx(client, tx, keypair, `futures.set_keeper_incentive_bps ${f.symbol}`);
      }

      // Apply new risk controls
      if (f.marketId) {
        // Optional admin knobs post-init
        if (typeof (f as any).closeOnly === 'boolean') {
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::futures::set_close_only`, typeArguments: [f.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(f.marketId), tx.pure.bool((f as any).closeOnly)] });
          await execTx(client, tx, keypair, `futures.set_close_only ${f.symbol}`);
        }
        if (typeof (f as any).maxDeviationBps === 'number') {
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::futures::set_price_deviation_bps`, typeArguments: [f.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(f.marketId), tx.pure.u64((f as any).maxDeviationBps)] });
          await execTx(client, tx, keypair, `futures.set_price_deviation_bps ${f.symbol}`);
        }
        if (typeof (f as any).pnlFeeShareBps === 'number') {
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::futures::set_pnl_fee_share_bps`, typeArguments: [f.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(f.marketId), tx.pure.u64((f as any).pnlFeeShareBps)] });
          await execTx(client, tx, keypair, `futures.set_pnl_fee_share_bps ${f.symbol}`);
        }
        if (typeof (f as any).liqTargetBufferBps === 'number') {
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::futures::set_liq_target_buffer_bps`, typeArguments: [f.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(f.marketId), tx.pure.u64((f as any).liqTargetBufferBps)] });
          await execTx(client, tx, keypair, `futures.set_liq_target_buffer_bps ${f.symbol}`);
        }
        if ((f as any).imbalanceParams) {
          const p = (f as any).imbalanceParams as { surchargeMaxBps: number; thresholdBps: number };
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::futures::set_imbalance_params`, typeArguments: [f.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(f.marketId), tx.pure.u64(p.surchargeMaxBps), tx.pure.u64(p.thresholdBps)] });
          await execTx(client, tx, keypair, `futures.set_imbalance_params ${f.symbol}`);
        }
        if ((f as any).accountMaxNotional1e6 || (f as any).marketMaxNotional1e6) {
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::futures::set_notional_caps`, typeArguments: [f.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(f.marketId), tx.pure.u128(BigInt((f as any).accountMaxNotional1e6 || '0')), tx.pure.u128(BigInt((f as any).marketMaxNotional1e6 || '0'))] as any });
          await execTx(client, tx, keypair, `futures.set_notional_caps ${f.symbol}`);
        }
        if (typeof (f as any).accountShareOfOiBps === 'number') {
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::futures::set_share_of_oi_bps`, typeArguments: [f.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(f.marketId), tx.pure.u64((f as any).accountShareOfOiBps)] });
          await execTx(client, tx, keypair, `futures.set_share_of_oi_bps ${f.symbol}`);
        }
        if ((f as any).tierThresholds1e6 && (f as any).tierImBps) {
          const thresholds = (f as any).tierThresholds1e6 as number[];
          const imbps = (f as any).tierImBps as number[];
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::futures::set_risk_tiers`, typeArguments: [f.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(f.marketId), tx.pure.vector('u64', thresholds), tx.pure.vector('u64', imbps)] as any });
          await execTx(client, tx, keypair, `futures.set_risk_tiers ${f.symbol}`);
        }
      }
    }
  }
}

async function deployGasFutures(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair, summary: DeploymentSummary) {
  if (!cfg.gasFutures?.length) return;
  logger.info(`Deploying Gas Futures: ${cfg.gasFutures.length} market spec(s)`);
  for (const g of cfg.gasFutures) {
    if (!g.marketId) {
      logger.debug(`gas_futures.init_market expiryMs=${g.expiryMs}`);
      const tx = new Transaction();
      tx.moveCall({
        target: `${cfg.pkgId}::gas_futures::init_market`,
        typeArguments: [g.collat],
        arguments: [
          tx.object(cfg.adminRegistryId),
          tx.pure.u64(g.expiryMs),
          tx.pure.u64(g.contractSize),
          tx.pure.u64(g.initialMarginBps),
          tx.pure.u64(g.maintenanceMarginBps),
          tx.pure.u64(g.liquidationFeeBps),
          tx.pure.u64((g as any).keeperIncentiveBps ?? 0),
          tx.pure.u64((g as any).tickSize ?? 0),
          tx.pure.u64((g as any).lotSize ?? 0),
          tx.pure.u64((g as any).minSize ?? 0),
        ],
      });
      const res = await execTx(client, tx, keypair, 'gas_futures.init_market');
      accumulateFromRes(res, summary);
      const id = extractCreatedId(res, `${cfg.pkgId}::gas_futures::GasMarket<`);
      if (id) logger.info(`gas_futures.market created id=${id}`);
      if (id) summary.gasFutures.push({
        marketId: id,
        collat: g.collat,
        expiryMs: g.expiryMs,
        contractSize: g.contractSize,
        tickSize: (g as any).tickSize,
        lotSize: (g as any).lotSize,
        minSize: (g as any).minSize,
        initialMarginBps: g.initialMarginBps,
        maintenanceMarginBps: g.maintenanceMarginBps,
        liquidationFeeBps: g.liquidationFeeBps,
        keeperIncentiveBps: (g as any).keeperIncentiveBps ?? 0,
        accountMaxNotional1e6: (g as any).accountMaxNotional1e6,
        marketMaxNotional1e6: (g as any).marketMaxNotional1e6,
        accountShareOfOiBps: (g as any).accountShareOfOiBps,
        tierThresholds1e6: (g as any).tierThresholds1e6,
        tierImBps: (g as any).tierImBps,
        closeOnly: (g as any).closeOnly,
        maxDeviationBps: (g as any).maxDeviationBps,
        pnlFeeShareBps: (g as any).pnlFeeShareBps,
        liqTargetBufferBps: (g as any).liqTargetBufferBps,
        imbalanceParams: (g as any).imbalanceParams,
      });
      // Apply post-init admin knobs and risk controls for newly created gas futures market
      if (id) {
        const gc = g as any;
        if (typeof gc.closeOnly === 'boolean') {
          const t1 = new Transaction();
          t1.moveCall({ target: `${cfg.pkgId}::gas_futures::set_close_only`, typeArguments: [g.collat], arguments: [t1.object(cfg.adminRegistryId), t1.object(id), t1.pure.bool(gc.closeOnly)] });
          await execTx(client, t1, keypair, `gas_futures.set_close_only`);
        }
        if (typeof gc.maxDeviationBps === 'number') {
          const t2 = new Transaction();
          t2.moveCall({ target: `${cfg.pkgId}::gas_futures::set_price_deviation_bps`, typeArguments: [g.collat], arguments: [t2.object(cfg.adminRegistryId), t2.object(id), t2.pure.u64(gc.maxDeviationBps)] });
          await execTx(client, t2, keypair, `gas_futures.set_price_deviation_bps`);
        }
        if (typeof gc.pnlFeeShareBps === 'number') {
          const t3 = new Transaction();
          t3.moveCall({ target: `${cfg.pkgId}::gas_futures::set_pnl_fee_share_bps`, typeArguments: [g.collat], arguments: [t3.object(cfg.adminRegistryId), t3.object(id), t3.pure.u64(gc.pnlFeeShareBps)] });
          await execTx(client, t3, keypair, `gas_futures.set_pnl_fee_share_bps`);
        }
        if (typeof gc.liqTargetBufferBps === 'number') {
          const t4 = new Transaction();
          t4.moveCall({ target: `${cfg.pkgId}::gas_futures::set_liq_target_buffer_bps`, typeArguments: [g.collat], arguments: [t4.object(cfg.adminRegistryId), t4.object(id), t4.pure.u64(gc.liqTargetBufferBps)] });
          await execTx(client, t4, keypair, `gas_futures.set_liq_target_buffer_bps`);
        }
        if (gc.imbalanceParams) {
          const p = gc.imbalanceParams as { surchargeMaxBps: number; thresholdBps: number };
          const t5 = new Transaction();
          t5.moveCall({ target: `${cfg.pkgId}::gas_futures::set_imbalance_params`, typeArguments: [g.collat], arguments: [t5.object(cfg.adminRegistryId), t5.object(id), t5.pure.u64(p.surchargeMaxBps), t5.pure.u64(p.thresholdBps)] });
          await execTx(client, t5, keypair, `gas_futures.set_imbalance_params`);
        }
        if (gc.accountMaxNotional1e6 || gc.marketMaxNotional1e6) {
          const t6 = new Transaction();
          t6.moveCall({ target: `${cfg.pkgId}::gas_futures::set_notional_caps`, typeArguments: [g.collat], arguments: [t6.object(cfg.adminRegistryId), t6.object(id), t6.pure.u128(BigInt(gc.accountMaxNotional1e6 || '0')), t6.pure.u128(BigInt(gc.marketMaxNotional1e6 || '0'))] as any });
          await execTx(client, t6, keypair, 'gas_futures.set_notional_caps');
        }
        if (typeof gc.accountShareOfOiBps === 'number') {
          const t7 = new Transaction();
          t7.moveCall({ target: `${cfg.pkgId}::gas_futures::set_share_of_oi_bps`, typeArguments: [g.collat], arguments: [t7.object(cfg.adminRegistryId), t7.object(id), t7.pure.u64(gc.accountShareOfOiBps)] });
          await execTx(client, t7, keypair, 'gas_futures.set_share_of_oi_bps');
        }
        if (gc.tierThresholds1e6 && gc.tierImBps) {
          const thresholds = gc.tierThresholds1e6 as number[];
          const imbps = gc.tierImBps as number[];
          const t8 = new Transaction();
          t8.moveCall({ target: `${cfg.pkgId}::gas_futures::set_risk_tiers`, typeArguments: [g.collat], arguments: [t8.object(cfg.adminRegistryId), t8.object(id), t8.pure.vector('u64', thresholds), t8.pure.vector('u64', imbps)] as any });
          await execTx(client, t8, keypair, 'gas_futures.set_risk_tiers');
        }
      }
    } else {
      summary.gasFutures.push({
        marketId: g.marketId,
        collat: g.collat,
        expiryMs: g.expiryMs,
        contractSize: g.contractSize,
        tickSize: (g as any).tickSize,
        lotSize: (g as any).lotSize,
        minSize: (g as any).minSize,
        initialMarginBps: g.initialMarginBps,
        maintenanceMarginBps: g.maintenanceMarginBps,
        liquidationFeeBps: g.liquidationFeeBps,
        keeperIncentiveBps: (g as any).keeperIncentiveBps ?? 0,
        accountMaxNotional1e6: (g as any).accountMaxNotional1e6,
        marketMaxNotional1e6: (g as any).marketMaxNotional1e6,
        accountShareOfOiBps: (g as any).accountShareOfOiBps,
        tierThresholds1e6: (g as any).tierThresholds1e6,
        tierImBps: (g as any).tierImBps,
        closeOnly: (g as any).closeOnly,
        maxDeviationBps: (g as any).maxDeviationBps,
        pnlFeeShareBps: (g as any).pnlFeeShareBps,
        liqTargetBufferBps: (g as any).liqTargetBufferBps,
        imbalanceParams: (g as any).imbalanceParams,
      });
      if (typeof (g as any).keeperIncentiveBps === 'number' && g.marketId) {
        const tx = new Transaction();
        tx.moveCall({ target: `${cfg.pkgId}::gas_futures::set_keeper_incentive_bps`, typeArguments: [g.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(g.marketId), tx.pure.u64((g as any).keeperIncentiveBps)] });
        await execTx(client, tx, keypair, 'gas_futures.set_keeper_incentive_bps');
      }

      // Apply new gas futures risk controls
      if (g.marketId) {
        if (typeof (g as any).closeOnly === 'boolean') {
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::gas_futures::set_close_only`, typeArguments: [g.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(g.marketId), tx.pure.bool((g as any).closeOnly)] });
          await execTx(client, tx, keypair, `gas_futures.set_close_only`);
        }
        if (typeof (g as any).maxDeviationBps === 'number') {
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::gas_futures::set_price_deviation_bps`, typeArguments: [g.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(g.marketId), tx.pure.u64((g as any).maxDeviationBps)] });
          await execTx(client, tx, keypair, `gas_futures.set_price_deviation_bps`);
        }
        if (typeof (g as any).pnlFeeShareBps === 'number') {
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::gas_futures::set_pnl_fee_share_bps`, typeArguments: [g.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(g.marketId), tx.pure.u64((g as any).pnlFeeShareBps)] });
          await execTx(client, tx, keypair, `gas_futures.set_pnl_fee_share_bps`);
        }
        if (typeof (g as any).liqTargetBufferBps === 'number') {
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::gas_futures::set_liq_target_buffer_bps`, typeArguments: [g.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(g.marketId), tx.pure.u64((g as any).liqTargetBufferBps)] });
          await execTx(client, tx, keypair, `gas_futures.set_liq_target_buffer_bps`);
        }
        if ((g as any).imbalanceParams) {
          const p = (g as any).imbalanceParams as { surchargeMaxBps: number; thresholdBps: number };
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::gas_futures::set_imbalance_params`, typeArguments: [g.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(g.marketId), tx.pure.u64(p.surchargeMaxBps), tx.pure.u64(p.thresholdBps)] });
          await execTx(client, tx, keypair, `gas_futures.set_imbalance_params`);
        }
        if ((g as any).accountMaxNotional1e6 || (g as any).marketMaxNotional1e6) {
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::gas_futures::set_notional_caps`, typeArguments: [g.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(g.marketId), tx.pure.u128(BigInt((g as any).accountMaxNotional1e6 || '0')), tx.pure.u128(BigInt((g as any).marketMaxNotional1e6 || '0'))] as any });
          await execTx(client, tx, keypair, 'gas_futures.set_notional_caps');
        }
        if (typeof (g as any).accountShareOfOiBps === 'number') {
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::gas_futures::set_share_of_oi_bps`, typeArguments: [g.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(g.marketId), tx.pure.u64((g as any).accountShareOfOiBps)] });
          await execTx(client, tx, keypair, 'gas_futures.set_share_of_oi_bps');
        }
        if ((g as any).tierThresholds1e6 && (g as any).tierImBps) {
          const thresholds = (g as any).tierThresholds1e6 as number[];
          const imbps = (g as any).tierImBps as number[];
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::gas_futures::set_risk_tiers`, typeArguments: [g.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(g.marketId), tx.pure.vector('u64', thresholds), tx.pure.vector('u64', imbps)] as any });
          await execTx(client, tx, keypair, 'gas_futures.set_risk_tiers');
        }
      }
    }
  }
}

async function deployPerpetuals(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair, summary: DeploymentSummary) {
  if (!cfg.perpetuals?.length) return;
  logger.info(`Deploying Perpetuals: ${cfg.perpetuals.length} market spec(s)`);
  for (const p of cfg.perpetuals) {
    if (!p.marketId) {
      logger.debug(`perpetuals.init_market symbol=${p.symbol}`);
      const tx = new Transaction();
      tx.moveCall({
        target: `${cfg.pkgId}::perpetuals::init_market`,
        typeArguments: [p.collat],
        arguments: [
          tx.object(cfg.adminRegistryId),
          tx.pure.string(p.symbol),
          tx.pure.u64(p.contractSize),
          tx.pure.u64(p.fundingIntervalMs),
          tx.pure.u64(p.initialMarginBps),
          tx.pure.u64(p.maintenanceMarginBps),
          tx.pure.u64(p.liquidationFeeBps),
          tx.pure.u64((p as any).keeperIncentiveBps ?? 0),
          tx.pure.u64((p as any).tickSize ?? 0),
          tx.pure.u64((p as any).lotSize ?? 0),
          tx.pure.u64((p as any).minSize ?? 0),
        ],
      });
      const res = await execTx(client, tx, keypair, `perpetuals.init_market ${p.symbol}`);
      accumulateFromRes(res, summary);
      const id = extractCreatedId(res, `${cfg.pkgId}::perpetuals::PerpMarket<`);
      if (id) logger.info(`perpetuals.market created id=${id}`);
      if (id) summary.perpetuals.push({
        marketId: id,
        collat: p.collat,
        symbol: p.symbol,
        contractSize: p.contractSize,
        fundingIntervalMs: p.fundingIntervalMs,
        tickSize: (p as any).tickSize,
        lotSize: (p as any).lotSize,
        minSize: (p as any).minSize,
        initialMarginBps: p.initialMarginBps,
        maintenanceMarginBps: p.maintenanceMarginBps,
        liquidationFeeBps: p.liquidationFeeBps,
        keeperIncentiveBps: (p as any).keeperIncentiveBps ?? 0,
        accountMaxNotional1e6: (p as any).accountMaxNotional1e6,
        marketMaxNotional1e6: (p as any).marketMaxNotional1e6,
        accountShareOfOiBps: (p as any).accountShareOfOiBps,
        tierThresholds1e6: (p as any).tierThresholds1e6,
        tierImBps: (p as any).tierImBps,
      });
      // Apply post-init risk controls for newly created perps market
      if (id) {
        const pc = p as any;
        if (pc.accountMaxNotional1e6 || pc.marketMaxNotional1e6) {
          const t1 = new Transaction();
          t1.moveCall({ target: `${cfg.pkgId}::perpetuals::set_notional_caps`, typeArguments: [p.collat], arguments: [t1.object(cfg.adminRegistryId), t1.object(id), t1.pure.u128(BigInt(pc.accountMaxNotional1e6 || '0')), t1.pure.u128(BigInt(pc.marketMaxNotional1e6 || '0'))] as any });
          await execTx(client, t1, keypair, `perpetuals.set_notional_caps ${p.symbol}`);
        }
        if (typeof pc.accountShareOfOiBps === 'number') {
          const t2 = new Transaction();
          t2.moveCall({ target: `${cfg.pkgId}::perpetuals::set_share_of_oi_bps`, typeArguments: [p.collat], arguments: [t2.object(cfg.adminRegistryId), t2.object(id), t2.pure.u64(pc.accountShareOfOiBps)] });
          await execTx(client, t2, keypair, `perpetuals.set_share_of_oi_bps ${p.symbol}`);
        }
        if (pc.tierThresholds1e6 && pc.tierImBps) {
          const thresholds = pc.tierThresholds1e6 as number[];
          const imbps = pc.tierImBps as number[];
          const t3 = new Transaction();
          t3.moveCall({ target: `${cfg.pkgId}::perpetuals::set_risk_tiers`, typeArguments: [p.collat], arguments: [t3.object(cfg.adminRegistryId), t3.object(id), t3.pure.vector('u64', thresholds), t3.pure.vector('u64', imbps)] as any });
          await execTx(client, t3, keypair, `perpetuals.set_risk_tiers ${p.symbol}`);
        }
      }
    } else {
      summary.perpetuals.push({
        marketId: p.marketId,
        collat: p.collat,
        symbol: p.symbol,
        contractSize: p.contractSize,
        fundingIntervalMs: p.fundingIntervalMs,
        tickSize: (p as any).tickSize,
        lotSize: (p as any).lotSize,
        minSize: (p as any).minSize,
        initialMarginBps: p.initialMarginBps,
        maintenanceMarginBps: p.maintenanceMarginBps,
        liquidationFeeBps: p.liquidationFeeBps,
        keeperIncentiveBps: (p as any).keeperIncentiveBps ?? 0,
        accountMaxNotional1e6: (p as any).accountMaxNotional1e6,
        marketMaxNotional1e6: (p as any).marketMaxNotional1e6,
        accountShareOfOiBps: (p as any).accountShareOfOiBps,
        tierThresholds1e6: (p as any).tierThresholds1e6,
        tierImBps: (p as any).tierImBps,
      });
      if (typeof (p as any).keeperIncentiveBps === 'number' && p.marketId) {
        const tx = new Transaction();
        tx.moveCall({ target: `${cfg.pkgId}::perpetuals::set_keeper_incentive_bps`, typeArguments: [p.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(p.marketId), tx.pure.u64((p as any).keeperIncentiveBps)] });
        await execTx(client, tx, keypair, `perpetuals.set_keeper_incentive_bps ${p.symbol}`);
      }
      // Apply new perps risk controls
      if (p.marketId) {
        if ((p as any).accountMaxNotional1e6 || (p as any).marketMaxNotional1e6) {
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::perpetuals::set_notional_caps`, typeArguments: [p.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(p.marketId), tx.pure.u128(BigInt((p as any).accountMaxNotional1e6 || '0')), tx.pure.u128(BigInt((p as any).marketMaxNotional1e6 || '0'))] as any });
          await execTx(client, tx, keypair, `perpetuals.set_notional_caps ${p.symbol}`);
        }
        if (typeof (p as any).accountShareOfOiBps === 'number') {
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::perpetuals::set_share_of_oi_bps`, typeArguments: [p.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(p.marketId), tx.pure.u64((p as any).accountShareOfOiBps)] });
          await execTx(client, tx, keypair, `perpetuals.set_share_of_oi_bps ${p.symbol}`);
        }
        if ((p as any).tierThresholds1e6 && (p as any).tierImBps) {
          const thresholds = (p as any).tierThresholds1e6 as number[];
          const imbps = (p as any).tierImBps as number[];
          const tx = new Transaction();
          tx.moveCall({ target: `${cfg.pkgId}::perpetuals::set_risk_tiers`, typeArguments: [p.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(p.marketId), tx.pure.vector('u64', thresholds), tx.pure.vector('u64', imbps)] as any });
          await execTx(client, tx, keypair, `perpetuals.set_risk_tiers ${p.symbol}`);
        }
      }
    }
  }
}

// === X- synthetic deployers ===
async function deployXPerps(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair, summary: DeploymentSummary) {
  if (!cfg.xperps?.length) return;
  logger.info(`Deploying XPerps: ${cfg.xperps.length} market spec(s)`);
  for (const p of cfg.xperps) {
    if (!p.marketId) {
      const tx = new Transaction();
      tx.moveCall({
        target: `${cfg.pkgId}::xperps::init_market`,
        typeArguments: [p.collat],
        arguments: [
          tx.object(cfg.adminRegistryId),
          tx.pure.u64(p.contractSize),
          tx.pure.u64(p.fundingIntervalMs),
          tx.pure.u64((p as any).initialMark1e6 ?? 1_000_000),
          tx.pure.u64(p.tickSize),
          tx.pure.u64(p.lotSize),
          tx.pure.u64(p.minSize),
          tx.pure.u64(p.initialMarginBps),
          tx.pure.u64(p.maintenanceMarginBps),
          tx.pure.u64(p.liquidationFeeBps),
          tx.pure.u64((p as any).keeperIncentiveBps ?? 0),
        ],
      });
      const res = await execTx(client, tx, keypair, `xperps.init_market ${p.symbol}`);
      accumulateFromRes(res, summary);
      const id = extractCreatedId(res, `${cfg.pkgId}::xperps::XPerpMarket<`);
      if (id) {
        logger.info(`xperps.market created id=${id}`);
        summary.xperps.push({
          marketId: id,
          collat: p.collat,
          symbol: p.symbol,
          contractSize: p.contractSize,
          fundingIntervalMs: p.fundingIntervalMs,
          tickSize: p.tickSize,
          lotSize: p.lotSize,
          minSize: p.minSize,
          initialMarginBps: p.initialMarginBps,
          maintenanceMarginBps: p.maintenanceMarginBps,
          liquidationFeeBps: p.liquidationFeeBps,
          keeperIncentiveBps: (p as any).keeperIncentiveBps ?? 0,
        } as any);
        // Optional EMA params and caps
        const hasEma = (p as any).alphaNum != null || (p as any).capMultipleBps != null || (p as any).markGateBps != null;
        if (hasEma) {
          const t = new Transaction();
          t.moveCall({ target: `${cfg.pkgId}::xperps::set_ema_params`, typeArguments: [p.collat], arguments: [
            t.object(cfg.adminRegistryId), t.object(id),
            t.pure.u64((p as any).alphaNum ?? 1), t.pure.u64((p as any).alphaDen ?? 480),
            t.pure.u64((p as any).alphaLongNum ?? 1), t.pure.u64((p as any).alphaLongDen ?? 43200),
            t.pure.u64((p as any).capMultipleBps ?? 40000), t.pure.u64((p as any).markGateBps ?? 0),
          ] });
          await execTx(client, t, keypair, `xperps.set_ema_params ${p.symbol}`);
        }
        // Optional caps and tiers
        if ((p as any).accountMaxNotional1e6 || (p as any).marketMaxNotional1e6) {
          const t = new Transaction();
          t.moveCall({ target: `${cfg.pkgId}::xperps::set_notional_caps`, typeArguments: [p.collat], arguments: [
            t.object(cfg.adminRegistryId), t.object(id),
            t.pure.u128(BigInt((p as any).accountMaxNotional1e6 || '0')),
            t.pure.u128(BigInt((p as any).marketMaxNotional1e6 || '0')),
          ] as any });
          await execTx(client, t, keypair, `xperps.set_notional_caps ${p.symbol}`);
        }
        if (typeof (p as any).accountShareOfOiBps === 'number') {
          const t = new Transaction();
          t.moveCall({ target: `${cfg.pkgId}::xperps::set_share_of_oi_bps`, typeArguments: [p.collat], arguments: [
            t.object(cfg.adminRegistryId), t.object(id), t.pure.u64((p as any).accountShareOfOiBps),
          ] });
          await execTx(client, t, keypair, `xperps.set_share_of_oi_bps ${p.symbol}`);
        }
        if ((p as any).tierThresholds1e6 && (p as any).tierImBps) {
          const thresholds = (p as any).tierThresholds1e6 as number[];
          const imbps = (p as any).tierImBps as number[];
          const t = new Transaction();
          t.moveCall({ target: `${cfg.pkgId}::xperps::set_risk_tiers`, typeArguments: [p.collat], arguments: [
            t.object(cfg.adminRegistryId), t.object(id), t.pure.vector('u64', thresholds), t.pure.vector('u64', imbps),
          ] as any });
          await execTx(client, t, keypair, `xperps.set_risk_tiers ${p.symbol}`);
        }
      }
    }
  }
}


async function deployLending(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair, summary: DeploymentSummary) {
  if (!cfg.lendingMarkets?.length) return;
  logger.info(`Deploying Lending: ${cfg.lendingMarkets.length} market spec(s)`);
  for (const m of cfg.lendingMarkets) {
    if (!m.marketId) {
      logger.debug(`lending.init_market symbol=${m.symbol}`);
      const tx = new Transaction();
      tx.moveCall({
        target: `${cfg.pkgId}::lending::init_market`,
        typeArguments: [resolveTypeTag(m.collat, cfg.pkgId), resolveTypeTag(m.debt, cfg.pkgId)],
        arguments: [
          tx.object(cfg.adminRegistryId),
          tx.pure.string(m.symbol),
          tx.pure.u64(m.baseRateBps),
          tx.pure.u64(m.multiplierBps),
          tx.pure.u64(m.jumpMultiplierBps),
          tx.pure.u64(m.kinkUtilBps),
          tx.pure.u64(m.reserveFactorBps),
          tx.pure.u64(m.collateralFactorBps),
          tx.pure.u64(m.liquidationThresholdBps),
          tx.pure.u64(m.liquidationBonusBps),
        ],
      });
      const res = await execTx(client, tx, keypair, `lending.init_market ${m.collat}`);
      accumulateFromRes(res, summary);
      const id = extractCreatedId(res, `${cfg.pkgId}::lending::LendingMarket<`);
      if (id) {
        logger.info(`lending.market created id=${id}`);
        summary.lending.push({
          marketId: id,
          collat: m.collat,
          debt: m.debt,
          symbol: m.symbol,
          baseRateBps: m.baseRateBps,
          multiplierBps: m.multiplierBps,
          jumpMultiplierBps: m.jumpMultiplierBps,
          kinkUtilBps: m.kinkUtilBps,
          reserveFactorBps: m.reserveFactorBps,
          collateralFactorBps: m.collateralFactorBps,
          liquidationThresholdBps: m.liquidationThresholdBps,
          liquidationBonusBps: m.liquidationBonusBps,
        });
      }
    }
  }
}

function deriveCoinKeys(
  baseType: string,
  quoteType: string,
  network: string,
): { baseKey: string; quoteKey: string; symbol?: string; baseDecimals?: number; quoteDecimals?: number } {
  const mapping = network === 'mainnet' ? MAINNET_DERIVATIVE_TYPE_TAGS : TESTNET_DERIVATIVE_TYPE_TAGS;
  for (const [symbol, v] of Object.entries(mapping)) {
    if (v.base === baseType && v.quote === quoteType) {
      const [baseKey, quoteKey] = symbol.split('/');
      return { baseKey, quoteKey, symbol, baseDecimals: v.baseDecimals, quoteDecimals: v.quoteDecimals };
    }
  }
  // Fallback: last segment of type tag
  const baseKey = (baseType.split('::')[2] || 'BASE').toUpperCase();
  const quoteKey = (quoteType.split('::')[2] || 'QUOTE').toUpperCase();
  // Heuristic decimals
  const baseName = baseKey;
  const quoteName = quoteKey;
  const baseDecimals = baseName === 'SUI' ? 9 : 6;
  const quoteDecimals = quoteName === 'SUI' ? 9 : 6;
  return { baseKey, quoteKey, baseDecimals, quoteDecimals };
}

function buildCustomCoinMap(cfg: DeployConfig): Record<string, { address: string; type: string; scalar: number }> {
  const coins: Record<string, { address: string; type: string; scalar: number }> = {};
  for (const d of (cfg.dexPools || [])) {
    const info = deriveCoinKeys(d.base, d.quote, cfg.network);
    const entries: Array<{ key: string; type: string; decimals?: number }> = [
      { key: info.baseKey, type: d.base, decimals: info.baseDecimals },
      { key: info.quoteKey, type: d.quote, decimals: info.quoteDecimals },
    ];
    for (const e of entries) {
      if (!coins[e.key]) {
        const addr = e.type.split('::')[0];
        const decimals = typeof e.decimals === 'number' ? e.decimals : (e.key === 'SUI' ? 9 : 6);
        const scalar = Math.pow(10, decimals);
        coins[e.key] = { address: addr, type: e.type, scalar };
      }
    }
  }
  return coins;
}

async function deployDexPools(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair, summary: DeploymentSummary) {
  if (!cfg.dexPools?.length) return;
  const env = cfg.network === 'mainnet' ? 'mainnet' as const : 'testnet' as const;
  const address = keypair.toSuiAddress();
  const customCoins = buildCustomCoinMap(cfg);
  const db = new DeepBookClient({ client: client as any, address, env, coins: customCoins });
  logger.info(`Creating ${cfg.dexPools.length} DeepBook pool(s) via SDK`);
  for (const d of cfg.dexPools) {
    const { baseKey, quoteKey, symbol } = deriveCoinKeys(d.base, d.quote, cfg.network);
    const deepFeeAmount = (d as any).deepCreationFeeAmount ?? 600;
    const deepFeeCoinId = (d as any).deepCreationFeeCoinId as string | undefined;
    if (!deepFeeCoinId) {
      throw new Error(`Missing deepCreationFeeCoinId for ${symbol ?? `${baseKey}/${quoteKey}`}. Provide a DEEP coin id via dexPools[*].deepCreationFeeCoinId.`);
    }
    const tx = new Transaction();
    const [deepFeeCoin] = tx.splitCoins(tx.object(deepFeeCoinId), [tx.pure.u64(deepFeeAmount)]);
    // Add SDK call (bridge generates PTB thunk)
    tx.add((ttx: any) => (db.deepBook.createPermissionlessPool({
      baseCoinKey: baseKey,
      quoteCoinKey: quoteKey,
      tickSize: d.tickSize,
      lotSize: d.lotSize,
      minSize: d.minSize,
      deepCoin: deepFeeCoin,
    }) as any)(ttx));

    const res = await execTx(client, tx, keypair, `deepbook.create_permissionless_pool ${symbol ?? `${baseKey}/${quoteKey}`}`);
    accumulateFromRes(res, summary);
    // Resolve pool id after finality
    try {
      const poolId = await db.getPoolIdByAssets(d.base, d.quote);
      if (poolId) {
        summary.dexPools.push({ poolId, base: d.base, quote: d.quote, tickSize: d.tickSize, lotSize: d.lotSize, minSize: d.minSize, registryId: d.registryId });
        logger.info(`  Pool created: ${symbol ?? `${baseKey}/${quoteKey}`} -> ${poolId}`);
      }
    } catch {}
  }
}

async function createVault<T extends string>(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair, assetType: string, summary: DeploymentSummary): Promise<string> {
  const tx = new Transaction();
  // NOTE: Replace generic with actual type param via typeArguments if your Move function is generic
  tx.moveCall({ target: `${cfg.pkgId}::vaults::create_vault`, typeArguments: [assetType], arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.feeConfigId), tx.object(cfg.feeVaultId), tx.pure.bool(false), tx.object('0x6'), tx.object('0x6')] });
  const res = await execTx(client, tx, keypair, 'vaults.create_vault');
  accumulateFromRes(res, summary);
  const id = extractCreatedId(res, `${cfg.pkgId}::vaults::Vault<`) || '';
  return id;
}

async function setVaultCaps(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair, vaultId: string, caps: { maxOrderSizeBase?: number; maxInventoryTiltBps?: number; minDistanceBps?: number; paused?: boolean }) {
  const tx = new Transaction();
  // Build RiskCaps struct args inline
  tx.moveCall({ target: `${cfg.pkgId}::vaults::set_risk_caps`, arguments: [tx.object(cfg.adminRegistryId), tx.object(vaultId), tx.pure.u64(caps.maxOrderSizeBase ?? 0), tx.pure.u64(caps.maxInventoryTiltBps ?? 7000), tx.pure.u64(caps.minDistanceBps ?? 5), tx.pure.bool(caps.paused ?? false), tx.object('0x6')] as any });
  await execTx(client, tx, keypair, `vaults.set_risk_caps ${vaultId}`);
}

function getOutputPath(): string {
  const __filename = fileURLToPath(import.meta.url);
  const __dirname = path.dirname(__filename);
  return path.resolve(__dirname, '..', '..', 'deploy-output.md');
}

function getTxResponsesPath(): string {
  const __filename = fileURLToPath(import.meta.url);
  const __dirname = path.dirname(__filename);
  return path.resolve(__dirname, '..', '..', 'deploy-tx-responses.json');
}

function getSummaryJsonPath(): string {
  const __filename = fileURLToPath(import.meta.url);
  const __dirname = path.dirname(__filename);
  return path.resolve(__dirname, '..', '..', 'deploy-summary.json');
}

async function writeDeploymentMarkdown(summary: DeploymentSummary) {
  const lines: string[] = [];
  lines.push(`# Unxversal Deploy Summary`);
  lines.push('');
  lines.push(`- **Network**: ${summary.network}`);
  lines.push(`- **Timestamp**: ${new Date(summary.timestampMs).toISOString()}`);
  lines.push('');
  lines.push('## Core objects');
  lines.push(`- **Package**: \`${summary.pkgId}\``);
  lines.push(`- **AdminRegistry**: \`${summary.adminRegistryId}\``);
  lines.push(`- **FeeConfig**: \`${summary.feeConfigId}\``);
  lines.push(`- **FeeVault**: \`${summary.feeVaultId}\``);
  lines.push(`- **StakingPool**: \`${summary.stakingPoolId}\``);
  if (summary.usduFaucetId) lines.push(`- **USDU Faucet**: \`${summary.usduFaucetId}\``);
  if (summary.oracleRegistryId) lines.push(`- **OracleRegistry**: \`${summary.oracleRegistryId}\``);
  if (summary.additionalAdmins?.length) lines.push(`- **Additional Admins**: ${summary.additionalAdmins.map((a) => `\`${a}\``).join(', ')}`);
  lines.push('');
  lines.push('## Configuration & Fees');
  if (summary.feeParams) lines.push('### Fee Params\n```json\n' + JSON.stringify(summary.feeParams, null, 2) + '\n```');
  if (summary.feeTiers) lines.push('### Staking Tiers\n```json\n' + JSON.stringify(summary.feeTiers, null, 2) + '\n```');
  if (summary.lendingParams) lines.push('### Lending Params\n```json\n' + JSON.stringify(summary.lendingParams, null, 2) + '\n```');
  if (typeof summary.poolCreationFeeUnxv === 'number') lines.push(`- **Pool Creation Fee (UNXV)**: ${summary.poolCreationFeeUnxv}`);
  if (summary.tradeFees) lines.push('### Trade Fees\n```json\n' + JSON.stringify(summary.tradeFees, null, 2) + '\n```');
  lines.push('');
  lines.push('## Oracle');
  if (typeof summary.oracleMaxAgeSec === 'number') lines.push(`- **Max Age (sec)**: ${summary.oracleMaxAgeSec}`);
  if (summary.oracleFeeds?.length) {
    lines.push(`- **Feeds (${summary.oracleFeeds.length})**:`);
    for (const f of summary.oracleFeeds) lines.push(`  - **${f.symbol}**: \`${f.priceId}\``);
  }
  lines.push('');
  // Counts overview
  lines.push('## Objects Created (Counts)');
  lines.push(`- **Lending**: ${summary.lending.length}`);
  lines.push(`- **Options markets**: ${summary.options.length}`);
  const optionSeriesCount = summary.options.reduce((n, m) => n + (m.series?.length || 0), 0);
  lines.push(`  - Series total: ${optionSeriesCount}`);
  lines.push(`- **Futures**: ${summary.futures.length}`);
  lines.push(`- **Gas Futures**: ${summary.gasFutures.length}`);
  lines.push(`- **Perpetuals**: ${summary.perpetuals.length}`);
  lines.push(`- **XPerps**: ${summary.xperps.length}`);
  // Removed synthetic modules xfutures/xoptions
  lines.push(`- **DEX Pools**: ${summary.dexPools.length}`);
  lines.push(`- **Vaults**: ${summary.vaults.length}`);
  lines.push('');
  if (summary.lending.length) {
    lines.push('## Lending Markets');
    for (const m of summary.lending) {
      lines.push(`- **${m.symbol}** market=\`${m.marketId}\` (<${m.collat}> → <${m.debt}>)`);
      lines.push(`  - Rates: base=${m.baseRateBps} | mul=${m.multiplierBps} | jump=${m.jumpMultiplierBps} | kink=${m.kinkUtilBps}`);
      lines.push(`  - Risk: reserve=${m.reserveFactorBps} | collat=${m.collateralFactorBps} | liqTh=${m.liquidationThresholdBps} | liqBonus=${m.liquidationBonusBps}`);
    }
    lines.push('');
  }
  if (summary.options.length) {
    lines.push('## Options Markets');
    for (const m of summary.options) {
      const total = m.series?.length || 0;
      const expiries = (m.series || []).map((s) => s.expiryMs).sort((a, b) => a - b);
      const first = expiries[0];
      const last = expiries[expiries.length - 1];
      lines.push(`- **Market** \`${m.marketId}\` (<${m.base}>, <${m.quote}>) — series=${total}${first ? `, first=${new Date(first).toISOString()}` : ''}${last ? `, last=${new Date(last).toISOString()}` : ''}`);
      if (m.series?.length) {
        for (const s of m.series) lines.push(`  - ${s.symbol} | expiry=${new Date(s.expiryMs).toISOString()} | strike1e6=${s.strike1e6} | isCall=${s.isCall}`);
      }
    }
    lines.push('');
  }
  if (summary.futures.length) {
    lines.push('## Futures Markets');
    const bySym = new Map<string, DeployedFutures[]>();
    for (const f of summary.futures) {
      const arr = bySym.get(f.symbol) || [];
      arr.push(f); bySym.set(f.symbol, arr);
    }
    for (const [sym, arr] of bySym.entries()) {
      lines.push(`### ${sym} (${arr.length})`);
      for (const m of arr.sort((a, b) => (a.expiryMs || 0) - (b.expiryMs || 0))) {
        lines.push(`- market=\`${m.marketId}\` expiry=${m.expiryMs ?? 0} (${m.expiryMs ? new Date(m.expiryMs).toISOString() : 'perp'})`);
        lines.push(`  - collat=<${m.collat}> cs=${m.contractSize} tick=${m.tickSize} lot=${m.lotSize} min=${m.minSize}`);
        lines.push(`  - IM=${m.initialMarginBps} MM=${m.maintenanceMarginBps} LiqFee=${m.liquidationFeeBps} KeeperBps=${m.keeperIncentiveBps}`);
        if (m.accountMaxNotional1e6 || m.marketMaxNotional1e6) lines.push(`  - Caps: acct=${m.accountMaxNotional1e6} market=${m.marketMaxNotional1e6}`);
        if (m.accountShareOfOiBps != null) lines.push(`  - ShareOfOI=${m.accountShareOfOiBps}`);
        if (m.tierThresholds1e6 && m.tierImBps) lines.push(`  - Tiers: thresholds=${JSON.stringify(m.tierThresholds1e6)} imbps=${JSON.stringify(m.tierImBps)}`);
        if (m.closeOnly != null) lines.push(`  - closeOnly=${m.closeOnly}`);
        if (m.maxDeviationBps != null) lines.push(`  - maxDeviationBps=${m.maxDeviationBps}`);
        if (m.pnlFeeShareBps != null) lines.push(`  - pnlFeeShareBps=${m.pnlFeeShareBps}`);
        if (m.liqTargetBufferBps != null) lines.push(`  - liqTargetBufferBps=${m.liqTargetBufferBps}`);
        if (m.imbalanceParams) lines.push(`  - imbalance: surchargeMax=${m.imbalanceParams.surchargeMaxBps} threshold=${m.imbalanceParams.thresholdBps}`);
      }
    }
    lines.push('');
  }
  if (summary.gasFutures.length) {
    lines.push('## Gas Futures Markets');
    for (const m of summary.gasFutures.sort((a, b) => a.expiryMs - b.expiryMs)) {
      lines.push(`- market=\`${m.marketId}\` expiry=${m.expiryMs} (${new Date(m.expiryMs).toISOString()})`);
      lines.push(`  - collat=<${m.collat}> cs=${m.contractSize} tick=${m.tickSize} lot=${m.lotSize} min=${m.minSize}`);
      lines.push(`  - IM=${m.initialMarginBps} MM=${m.maintenanceMarginBps} LiqFee=${m.liquidationFeeBps} KeeperBps=${m.keeperIncentiveBps}`);
      if (m.accountMaxNotional1e6 || m.marketMaxNotional1e6) lines.push(`  - Caps: acct=${m.accountMaxNotional1e6} market=${m.marketMaxNotional1e6}`);
      if (m.accountShareOfOiBps != null) lines.push(`  - ShareOfOI=${m.accountShareOfOiBps}`);
      if (m.tierThresholds1e6 && m.tierImBps) lines.push(`  - Tiers: thresholds=${JSON.stringify(m.tierThresholds1e6)} imbps=${JSON.stringify(m.tierImBps)}`);
      if (m.closeOnly != null) lines.push(`  - closeOnly=${m.closeOnly}`);
      if (m.maxDeviationBps != null) lines.push(`  - maxDeviationBps=${m.maxDeviationBps}`);
      if (m.pnlFeeShareBps != null) lines.push(`  - pnlFeeShareBps=${m.pnlFeeShareBps}`);
      if (m.liqTargetBufferBps != null) lines.push(`  - liqTargetBufferBps=${m.liqTargetBufferBps}`);
      if (m.imbalanceParams) lines.push(`  - imbalance: surchargeMax=${m.imbalanceParams.surchargeMaxBps} threshold=${m.imbalanceParams.thresholdBps}`);
    }
    lines.push('');
  }
  if (summary.perpetuals.length) {
    lines.push('## Perpetuals Markets');
    const bySym = new Map<string, DeployedPerp[]>();
    for (const p of summary.perpetuals) {
      const arr = bySym.get(p.symbol) || [];
      arr.push(p); bySym.set(p.symbol, arr);
    }
    for (const [sym, arr] of bySym.entries()) {
      lines.push(`### ${sym} (${arr.length})`);
      for (const m of arr) {
        lines.push(`- market=\`${m.marketId}\``);
        lines.push(`  - collat=<${m.collat}> cs=${m.contractSize} fundIntMs=${m.fundingIntervalMs} tick=${m.tickSize} lot=${m.lotSize} min=${m.minSize}`);
        lines.push(`  - IM=${m.initialMarginBps} MM=${m.maintenanceMarginBps} LiqFee=${m.liquidationFeeBps} KeeperBps=${m.keeperIncentiveBps}`);
        if (m.accountMaxNotional1e6 || m.marketMaxNotional1e6) lines.push(`  - Caps: acct=${m.accountMaxNotional1e6} market=${m.marketMaxNotional1e6}`);
        if (m.accountShareOfOiBps != null) lines.push(`  - ShareOfOI=${m.accountShareOfOiBps}`);
        if (m.tierThresholds1e6 && m.tierImBps) lines.push(`  - Tiers: thresholds=${JSON.stringify(m.tierThresholds1e6)} imbps=${JSON.stringify(m.tierImBps)}`);
      }
    }
    lines.push('');
  }
  if (summary.dexPools.length) {
    lines.push('## DEX Pools (DeepBook)');
    for (const p of summary.dexPools) lines.push(`- pool=\`${p.poolId}\`, <${p.base}>/<${p.quote}>, tick=${p.tickSize}, lot=${p.lotSize}, min=${p.minSize}, registry=\`${p.registryId}\``);
    lines.push('');
  }
  if (summary.vaults.length) {
    lines.push('## Vaults');
    for (const v of summary.vaults) lines.push(`- vault=<${v.id}> asset=<${v.asset}>`);
    lines.push('');
  }
  if (summary.createdPackageIds.length) {
    lines.push('## Packages observed during deployment');
    const uniquePkgs = Array.from(new Set(summary.createdPackageIds));
    for (const p of uniquePkgs) lines.push(`- packageId: \`${p}\``);
    lines.push('');
  }
  lines.push('## Raw summary');
  lines.push('```json');
  lines.push(JSON.stringify(summary, null, 2));
  lines.push('```');
  const outPath = getOutputPath();
  await writeFile(outPath, lines.join('\n'));
  logger.info(`Wrote deploy summary to ${outPath}`);
}

export async function main(): Promise<void> {
  const keypair = kpFromEnv();
  const client = new SuiClient({ url: getFullnodeUrl(deployConfig.network) });

  logger.info(`Starting Unxversal deploy -> network=${deployConfig.network}`);
  logger.info(`Config counts: options=${deployConfig.options?.length || 0}, futures=${deployConfig.futures?.length || 0}, gasFutures=${deployConfig.gasFutures?.length || 0}, perps=${deployConfig.perpetuals?.length || 0}, lending=${deployConfig.lendingMarkets?.length || 0}, dexPools=${deployConfig.dexPools?.length || 0}, vaults=${deployConfig.vaults?.length || 0}`);

  const summary: DeploymentSummary = {
    network: deployConfig.network,
    timestampMs: Date.now(),
    pkgId: deployConfig.pkgId,
    adminRegistryId: deployConfig.adminRegistryId,
    feeConfigId: deployConfig.feeConfigId,
    feeVaultId: deployConfig.feeVaultId,
    stakingPoolId: deployConfig.stakingPoolId,
    usduFaucetId: deployConfig.usduFaucetId,
    oracleRegistryId: deployConfig.oracleRegistryId,
    additionalAdmins: deployConfig.additionalAdmins,
    feeParams: deployConfig.feeParams,
    feeTiers: deployConfig.feeTiers,
    lendingParams: deployConfig.lendingParams,
    poolCreationFeeUnxv: deployConfig.poolCreationFeeUnxv,
    tradeFees: deployConfig.tradeFees,
    oracleMaxAgeSec: deployConfig.oracleMaxAgeSec,
    oracleFeeds: deployConfig.oracleFeeds || [],
    createdPackageIds: [],
    createdObjectTypes: [],
    lending: [],
    options: [],
    futures: [],
    gasFutures: [],
    perpetuals: [],
    dexPools: [],
    vaults: [],
    xperps: [],
  };

  const ensuredOracleId = await ensureOracleRegistry(client, deployConfig, keypair, summary);
  if (ensuredOracleId && !deployConfig.oracleRegistryId) {
    deployConfig.oracleRegistryId = ensuredOracleId;
  }
  await addAdditionalAdmins(client, deployConfig, keypair);
  await setOracleParams(client, deployConfig, keypair);
  await updateFeeParams(client, deployConfig, keypair);
  await applyUsduFaucetSettings(client, deployConfig, keypair);

  await deployLending(client, deployConfig, keypair, summary);
  await deployOptions(client, deployConfig, keypair, summary);
  await deployFutures(client, deployConfig, keypair, summary);
  await deployGasFutures(client, deployConfig, keypair, summary);
  await deployPerpetuals(client, deployConfig, keypair, summary);
  // x- synthetic protocols
  await deployXPerps(client, deployConfig, keypair, summary);
  await deployDexPools(client, deployConfig, keypair, summary);

  // Create vaults (optional)
  if (deployConfig.vaults?.length) {
    for (const v of deployConfig.vaults) {
      const id = await createVault(client, deployConfig, keypair, v.asset, summary);
      if (id) {
        summary.vaults.push({ id, asset: v.asset });
        if (v.caps) await setVaultCaps(client, deployConfig, keypair, id, v.caps);
      }
    }
  }

  logger.info('Generating comprehensive deployment markdown');
  await writeDeploymentMarkdown(summary);

  // Also write machine-readable artifacts
  const respPath = getTxResponsesPath();
  await writeFile(respPath, JSON.stringify({
    network: deployConfig.network,
    pkgId: deployConfig.pkgId,
    timestampMs: summary.timestampMs,
    count: txResponses.length,
    responses: txResponses,
  }, null, 2));
  logger.info(`Wrote raw tx responses to ${respPath}`);

  const summaryJsonPath = getSummaryJsonPath();
  await writeFile(summaryJsonPath, JSON.stringify(summary, null, 2));
  logger.info(`Wrote deployment summary JSON to ${summaryJsonPath}`);

  logger.info('Deploy completed');
}

main().catch((e) => {
  logger.error(e instanceof Error ? e.message : String(e));
  process.exit(1);
});
