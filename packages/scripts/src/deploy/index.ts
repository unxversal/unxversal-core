import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { logger } from '../utils/logger.js';
import { deployConfig, type DeployConfig } from './config.js';
import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

type DeployedOptions = { marketId: string; base: string; quote: string; series: Array<{ expiryMs: number; strike1e6: number; isCall: boolean; symbol: string }> };
type DeployedFutures = { marketId: string; collat: string; symbol: string; contractSize: number; initialMarginBps: number; maintenanceMarginBps: number; liquidationFeeBps: number; keeperIncentiveBps: number };
type DeployedGasFutures = { marketId: string; collat: string; expiryMs: number; contractSize: number; initialMarginBps: number; maintenanceMarginBps: number; liquidationFeeBps: number; keeperIncentiveBps: number };
type DeployedPerp = { marketId: string; collat: string; symbol: string; contractSize: number; fundingIntervalMs: number; initialMarginBps: number; maintenanceMarginBps: number; liquidationFeeBps: number; keeperIncentiveBps: number };
type DeployedDexPool = { poolId: string; base: string; quote: string; tickSize: number; lotSize: number; minSize: number; registryId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string };

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
  lending: Array<{ marketId: string; collat: string; debt: string; symbol: string }>;
  options: DeployedOptions[];
  futures: DeployedFutures[];
  gasFutures: DeployedGasFutures[];
  perpetuals: DeployedPerp[];
  dexPools: DeployedDexPool[];
  vaults: Array<{ id: string; asset: string }>;
};

function kpFromEnv(): Ed25519Keypair {
  const b64 = process.env.UNXV_ADMIN_SEED_B64 || '';
  if (!b64) throw new Error('UNXV_ADMIN_SEED_B64 is required');
  return Ed25519Keypair.fromSecretKey(Buffer.from(b64, 'base64'));
}

async function execTx(client: SuiClient, tx: Transaction, keypair: Ed25519Keypair, label: string) {
  const res = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx, options: { showEffects: true, showObjectChanges: true } });
  await client.waitForTransaction({ digest: res.digest });
  logger.info(`${label}: ${res.digest}`);
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

async function ensureOracleRegistry(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair): Promise<string> {
  if (cfg.oracleRegistryId) return cfg.oracleRegistryId;
  const tx = new Transaction();
  tx.moveCall({ target: `${cfg.pkgId}::oracle::init_registry`, arguments: [tx.object(cfg.adminRegistryId), tx.object('0x6')] });
  const res = await execTx(client, tx, keypair, 'oracle.init_registry');
  const id = extractCreatedId(res, `${cfg.pkgId}::oracle::OracleRegistry`)
    || extractCreatedId(res, `${cfg.pkgId}::oracle::OracleRegistry`)
    || '';
  return id;
}

async function setOracleParams(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair) {
  if (cfg.oracleMaxAgeSec && cfg.oracleRegistryId) {
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::oracle::set_max_age_registry`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.oracleRegistryId), tx.pure.u64(cfg.oracleMaxAgeSec), tx.object('0x6')] });
    await execTx(client, tx, keypair, 'oracle.set_max_age');
  }
  if (cfg.oracleFeeds && cfg.oracleFeeds.length && cfg.oracleRegistryId) {
    for (const f of cfg.oracleFeeds) {
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.pkgId}::oracle::set_feed_from_bytes`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.oracleRegistryId), tx.pure.string(f.symbol), tx.pure.vector('u8', Array.from(Buffer.from(f.priceId.replace(/^0x/, ''), 'hex'))), tx.object('0x6')] as any });
      await execTx(client, tx, keypair, `oracle.set_feed_from_bytes ${f.symbol}`);
    }
  }
}

async function addAdditionalAdmins(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair) {
  if (!cfg.additionalAdmins || cfg.additionalAdmins.length === 0) return;
  for (const addr of cfg.additionalAdmins) {
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::admin::add_admin`, arguments: [tx.object(cfg.adminRegistryId), tx.pure.address(addr)] });
    await execTx(client, tx, keypair, `admin.add_admin ${addr}`);
  }
}

async function updateFeeParams(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair) {
  if (cfg.feeParams) {
    const p = cfg.feeParams;
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
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::fees::set_trade_fees`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.feeConfigId), tx.pure.u64(t.takerBps), tx.pure.u64(t.makerBps)] });
    await execTx(client, tx, keypair, 'fees.set_trade_fees');
  }
  if (cfg.tradeFees?.futures) {
    const t = cfg.tradeFees.futures;
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::fees::set_futures_trade_fees`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.feeConfigId), tx.pure.u64(t.takerBps), tx.pure.u64(t.makerBps)] });
    await execTx(client, tx, keypair, 'fees.set_futures_trade_fees');
  }
  if (cfg.tradeFees?.gasFutures) {
    const t = cfg.tradeFees.gasFutures;
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::fees::set_gasfutures_trade_fees`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.feeConfigId), tx.pure.u64(t.takerBps), tx.pure.u64(t.makerBps)] });
    await execTx(client, tx, keypair, 'fees.set_gasfutures_trade_fees');
  }
  if (cfg.lendingParams) {
    const lp = cfg.lendingParams;
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::fees::set_lending_params`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.feeConfigId), tx.pure.u64(lp.borrowFeeBps), tx.pure.u64(lp.collateralBonusMaxBps)] });
    await execTx(client, tx, keypair, 'fees.set_lending_params');
  }
  if (typeof cfg.poolCreationFeeUnxv === 'number') {
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::fees::set_pool_creation_fee_unxv`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.feeConfigId), tx.pure.u64(cfg.poolCreationFeeUnxv)] });
    await execTx(client, tx, keypair, 'fees.set_pool_creation_fee_unxv');
  }
}

async function applyUsduFaucetSettings(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair) {
  if (!cfg.usdu || !cfg.usduFaucetId) return;
  const { perAddressLimit, paused } = cfg.usdu;
  if (perAddressLimit != null) {
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::usdu::set_per_address_limit`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.usduFaucetId), tx.pure.u64(perAddressLimit), tx.object('0x6')] });
    await execTx(client, tx, keypair, 'usdu.set_per_address_limit');
  }
  if (paused != null) {
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::usdu::set_paused`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.usduFaucetId), tx.pure.bool(paused), tx.object('0x6')] });
    await execTx(client, tx, keypair, 'usdu.set_paused');
  }
}

async function deployOptions(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair, summary: DeploymentSummary) {
  if (!cfg.options?.length) return;
  for (const m of cfg.options) {
    let marketId = m.marketId;
    if (!marketId) {
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.pkgId}::options::init_market`, arguments: [tx.object(cfg.adminRegistryId)] });
      const res = await execTx(client, tx, keypair, 'options.init_market');
      marketId = extractCreatedId(res, `${cfg.pkgId}::options::OptionsMarket<`) || marketId;
      if (marketId) logger.info(`options.market created id=${marketId}`);
    }
    if (m.series?.length && marketId) {
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
          ],
        });
        await execTx(client, tx, keypair, `options.create_series ${s.symbol}`);
      }
    }
    if (marketId) {
      summary.options.push({ marketId, base: m.base, quote: m.quote, series: m.series || [] });
    }
  }
}

async function deployFutures(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair, summary: DeploymentSummary) {
  if (!cfg.futures?.length) return;
  for (const f of cfg.futures) {
    if (!f.marketId) {
      const tx = new Transaction();
      tx.moveCall({
        target: `${cfg.pkgId}::futures::init_market`,
        typeArguments: [f.collat],
        arguments: [
          tx.object(cfg.adminRegistryId),
          tx.pure.u64(0),
          tx.pure.string(f.symbol),
          tx.pure.u64(f.contractSize),
          tx.pure.u64(f.initialMarginBps),
          tx.pure.u64(f.maintenanceMarginBps),
          tx.pure.u64(f.liquidationFeeBps),
          tx.pure.u64((f as any).keeperIncentiveBps ?? 0),
        ],
      });
      const res = await execTx(client, tx, keypair, `futures.init_market ${f.symbol}`);
      const id = extractCreatedId(res, `${cfg.pkgId}::futures::FuturesMarket<`);
      if (id) logger.info(`futures.market created id=${id}`);
      if (id) summary.futures.push({ marketId: id, collat: f.collat, symbol: f.symbol, contractSize: f.contractSize, initialMarginBps: f.initialMarginBps, maintenanceMarginBps: f.maintenanceMarginBps, liquidationFeeBps: f.liquidationFeeBps, keeperIncentiveBps: (f as any).keeperIncentiveBps ?? 0 });
    } else {
      summary.futures.push({ marketId: f.marketId, collat: f.collat, symbol: f.symbol, contractSize: f.contractSize, initialMarginBps: f.initialMarginBps, maintenanceMarginBps: f.maintenanceMarginBps, liquidationFeeBps: f.liquidationFeeBps, keeperIncentiveBps: (f as any).keeperIncentiveBps ?? 0 });
      if (typeof (f as any).keeperIncentiveBps === 'number' && f.marketId) {
        const tx = new Transaction();
        tx.moveCall({ target: `${cfg.pkgId}::futures::set_keeper_incentive_bps`, typeArguments: [f.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(f.marketId), tx.pure.u64((f as any).keeperIncentiveBps)] });
        await execTx(client, tx, keypair, `futures.set_keeper_incentive_bps ${f.symbol}`);
      }

      // Apply new risk controls
      if (f.marketId) {
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
  for (const g of cfg.gasFutures) {
    if (!g.marketId) {
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
        ],
      });
      const res = await execTx(client, tx, keypair, 'gas_futures.init_market');
      const id = extractCreatedId(res, `${cfg.pkgId}::gas_futures::GasMarket<`);
      if (id) logger.info(`gas_futures.market created id=${id}`);
      if (id) summary.gasFutures.push({ marketId: id, collat: g.collat, expiryMs: g.expiryMs, contractSize: g.contractSize, initialMarginBps: g.initialMarginBps, maintenanceMarginBps: g.maintenanceMarginBps, liquidationFeeBps: g.liquidationFeeBps, keeperIncentiveBps: (g as any).keeperIncentiveBps ?? 0 });
    } else {
      summary.gasFutures.push({ marketId: g.marketId, collat: g.collat, expiryMs: g.expiryMs, contractSize: g.contractSize, initialMarginBps: g.initialMarginBps, maintenanceMarginBps: g.maintenanceMarginBps, liquidationFeeBps: g.liquidationFeeBps, keeperIncentiveBps: (g as any).keeperIncentiveBps ?? 0 });
      if (typeof (g as any).keeperIncentiveBps === 'number' && g.marketId) {
        const tx = new Transaction();
        tx.moveCall({ target: `${cfg.pkgId}::gas_futures::set_keeper_incentive_bps`, typeArguments: [g.collat], arguments: [tx.object(cfg.adminRegistryId), tx.object(g.marketId), tx.pure.u64((g as any).keeperIncentiveBps)] });
        await execTx(client, tx, keypair, 'gas_futures.set_keeper_incentive_bps');
      }

      // Apply new gas futures risk controls
      if (g.marketId) {
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
  for (const p of cfg.perpetuals) {
    if (!p.marketId) {
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
        ],
      });
      const res = await execTx(client, tx, keypair, `perpetuals.init_market ${p.symbol}`);
      const id = extractCreatedId(res, `${cfg.pkgId}::perpetuals::PerpMarket<`);
      if (id) logger.info(`perpetuals.market created id=${id}`);
      if (id) summary.perpetuals.push({ marketId: id, collat: p.collat, symbol: p.symbol, contractSize: p.contractSize, fundingIntervalMs: p.fundingIntervalMs, initialMarginBps: p.initialMarginBps, maintenanceMarginBps: p.maintenanceMarginBps, liquidationFeeBps: p.liquidationFeeBps, keeperIncentiveBps: (p as any).keeperIncentiveBps ?? 0 });
    } else {
      summary.perpetuals.push({ marketId: p.marketId, collat: p.collat, symbol: p.symbol, contractSize: p.contractSize, fundingIntervalMs: p.fundingIntervalMs, initialMarginBps: p.initialMarginBps, maintenanceMarginBps: p.maintenanceMarginBps, liquidationFeeBps: p.liquidationFeeBps, keeperIncentiveBps: (p as any).keeperIncentiveBps ?? 0 });
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

async function deployLending(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair, summary: DeploymentSummary) {
  if (!cfg.lendingMarkets?.length) return;
  for (const m of cfg.lendingMarkets) {
    if (!m.marketId) {
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
      const id = extractCreatedId(res, `${cfg.pkgId}::lending::LendingMarket<`);
      if (id) {
        logger.info(`lending.market created id=${id}`);
        summary.lending.push({ marketId: id, collat: m.collat, debt: m.debt, symbol: m.symbol });
      }
    }
  }
}

async function deployDexPools(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair, summary: DeploymentSummary) {
  if (!cfg.dexPools?.length) return;
  for (const d of cfg.dexPools) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.pkgId}::dex::create_permissionless_pool`,
      typeArguments: [d.base, d.quote],
      arguments: [
        tx.object(d.registryId),
        tx.object(d.feeConfigId),
        tx.object(d.feeVaultId),
        tx.object(d.unxvFeeCoinId),
        tx.pure.u64(d.tickSize),
        tx.pure.u64(d.lotSize),
        tx.pure.u64(d.minSize),
        tx.object(d.stakingPoolId),
        tx.object('0x6'),
      ],
    });
    const res = await execTx(client, tx, keypair, 'dex.create_permissionless_pool');
    const poolId = extractCreatedId(res, 'deepbook::pool::Pool<') || '';
    if (poolId) {
      summary.dexPools.push({ poolId, base: d.base, quote: d.quote, tickSize: d.tickSize, lotSize: d.lotSize, minSize: d.minSize, registryId: d.registryId, feeConfigId: d.feeConfigId, feeVaultId: d.feeVaultId, stakingPoolId: d.stakingPoolId });
    }
  }
}

async function createVault<T extends string>(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair, assetType: string): Promise<string> {
  const tx = new Transaction();
  // NOTE: Replace generic with actual type param via typeArguments if your Move function is generic
  tx.moveCall({ target: `${cfg.pkgId}::vaults::create_vault`, typeArguments: [assetType], arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.feeConfigId), tx.object(cfg.feeVaultId), tx.pure.bool(false), tx.object('0x6'), tx.object('0x6')] });
  const res = await execTx(client, tx, keypair, 'vaults.create_vault');
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
  lines.push('## Fee settings');
  if (summary.feeParams) lines.push('```json\n' + JSON.stringify(summary.feeParams, null, 2) + '\n```');
  if (summary.feeTiers) lines.push('```json\n' + JSON.stringify(summary.feeTiers, null, 2) + '\n```');
  if (summary.lendingParams) lines.push('```json\n' + JSON.stringify(summary.lendingParams, null, 2) + '\n```');
  if (typeof summary.poolCreationFeeUnxv === 'number') lines.push(`- **Pool Creation Fee (UNXV)**: ${summary.poolCreationFeeUnxv}`);
  if (summary.tradeFees) lines.push('```json\n' + JSON.stringify(summary.tradeFees, null, 2) + '\n```');
  lines.push('');
  lines.push('## Oracle');
  if (typeof summary.oracleMaxAgeSec === 'number') lines.push(`- **Max Age (sec)**: ${summary.oracleMaxAgeSec}`);
  if (summary.oracleFeeds?.length) {
    lines.push('- **Feeds**:');
    for (const f of summary.oracleFeeds) lines.push(`  - **${f.symbol}**: \`${f.aggregatorId}\``);
  }
  lines.push('');
  if (summary.options.length) {
    lines.push('## Options Markets');
    for (const m of summary.options) {
      lines.push(`- **Market** \`${m.marketId}\` (<${m.base}>, <${m.quote}>)`);
      if (m.series?.length) {
        for (const s of m.series) lines.push(`  - ${s.symbol} | expiry=${s.expiryMs} | strike1e6=${s.strike1e6} | isCall=${s.isCall}`);
      }
    }
    lines.push('');
  }
  if (summary.futures.length) {
    lines.push('## Futures Markets');
    for (const m of summary.futures) lines.push(`- **${m.symbol}**: market=\`${m.marketId}\`, collat=<${m.collat}>, cs=${m.contractSize}, IM=${m.initialMarginBps}, MM=${m.maintenanceMarginBps}, LiqFee=${m.liquidationFeeBps}, KeeperBps=${m.keeperIncentiveBps}`);
    lines.push('');
  }
  if (summary.gasFutures.length) {
    lines.push('## Gas Futures Markets');
    for (const m of summary.gasFutures) lines.push(`- market=\`${m.marketId}\`, collat=<${m.collat}>, expiry=${m.expiryMs}, cs=${m.contractSize}, IM=${m.initialMarginBps}, MM=${m.maintenanceMarginBps}, LiqFee=${m.liquidationFeeBps}, KeeperBps=${m.keeperIncentiveBps}`);
    lines.push('');
  }
  if (summary.perpetuals.length) {
    lines.push('## Perpetuals Markets');
    for (const m of summary.perpetuals) lines.push(`- **${m.symbol}**: market=\`${m.marketId}\`, collat=<${m.collat}>, cs=${m.contractSize}, fundInt=${m.fundingIntervalMs}, IM=${m.initialMarginBps}, MM=${m.maintenanceMarginBps}, LiqFee=${m.liquidationFeeBps}, KeeperBps=${m.keeperIncentiveBps}`);
    lines.push('');
  }
  if (summary.dexPools.length) {
    lines.push('## DEX Pools (DeepBook)');
    for (const p of summary.dexPools) lines.push(`- pool=\`${p.poolId}\`, <${p.base}>/<${p.quote}>, tick=${p.tickSize}, lot=${p.lotSize}, min=${p.minSize}`);
    lines.push('');
  }
  if (summary.vaults.length) {
    lines.push('## Vaults');
    for (const v of summary.vaults) lines.push(`- vault=<${v.id}> asset=<${v.asset}>`);
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

  const ensuredOracleId = await ensureOracleRegistry(client, deployConfig, keypair);
  if (ensuredOracleId && !deployConfig.oracleRegistryId) {
    deployConfig.oracleRegistryId = ensuredOracleId;
  }
  await addAdditionalAdmins(client, deployConfig, keypair);
  await setOracleParams(client, deployConfig, keypair);
  await updateFeeParams(client, deployConfig, keypair);
  await applyUsduFaucetSettings(client, deployConfig, keypair);

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
    lending: [],
    options: [],
    futures: [],
    gasFutures: [],
    perpetuals: [],
    dexPools: [],
    vaults: [],
  };

  await deployLending(client, deployConfig, keypair, summary);
  await deployOptions(client, deployConfig, keypair, summary);
  await deployFutures(client, deployConfig, keypair, summary);
  await deployGasFutures(client, deployConfig, keypair, summary);
  await deployPerpetuals(client, deployConfig, keypair, summary);
  await deployDexPools(client, deployConfig, keypair, summary);

  // Create vaults (optional)
  if (deployConfig.vaults?.length) {
    for (const v of deployConfig.vaults) {
      const id = await createVault(client, deployConfig, keypair, v.asset);
      if (id) {
        summary.vaults.push({ id, asset: v.asset });
        if (v.caps) await setVaultCaps(client, deployConfig, keypair, id, v.caps);
      }
    }
  }

  await writeDeploymentMarkdown(summary);

  logger.info('Deploy completed');
}

main().catch((e) => {
  logger.error(e instanceof Error ? e.message : String(e));
  process.exit(1);
});
