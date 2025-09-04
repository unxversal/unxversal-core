import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { logger } from '../utils/logger.js';
import { deployConfig, type DeployConfig } from './config.js';

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

async function ensureOracleRegistry(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair): Promise<string> {
  if (cfg.oracleRegistryId) return cfg.oracleRegistryId;
  const tx = new Transaction();
  tx.moveCall({ target: `${cfg.pkgId}::oracle::init_registry`, arguments: [tx.object(cfg.adminRegistryId)] });
  const res = await execTx(client, tx, keypair, 'oracle.init_registry');
  const id = extractCreatedId(res, `${cfg.pkgId}::utils::oracle::OracleRegistry`)
    || extractCreatedId(res, `${cfg.pkgId}::oracle::OracleRegistry`)
    || '';
  return id;
}

async function setOracleParams(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair) {
  if (cfg.oracleMaxAgeSec && cfg.oracleRegistryId) {
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkgId}::oracle::set_max_age_registry`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.oracleRegistryId), tx.pure.u64(cfg.oracleMaxAgeSec)] });
    await execTx(client, tx, keypair, 'oracle.set_max_age');
  }
  if (cfg.oracleFeeds && cfg.oracleFeeds.length && cfg.oracleRegistryId) {
    for (const f of cfg.oracleFeeds) {
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.pkgId}::oracle::set_feed`, arguments: [tx.object(cfg.adminRegistryId), tx.object(cfg.oracleRegistryId), tx.pure.string(f.symbol), tx.object(f.aggregatorId)] });
      await execTx(client, tx, keypair, `oracle.set_feed ${f.symbol}`);
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

async function deployOptions(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair) {
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
  }
}

async function deployFutures(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair) {
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
        ],
      });
      const res = await execTx(client, tx, keypair, `futures.init_market ${f.symbol}`);
      const id = extractCreatedId(res, `${cfg.pkgId}::futures::FuturesMarket<`);
      if (id) logger.info(`futures.market created id=${id}`);
    }
  }
}

async function deployGasFutures(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair) {
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
        ],
      });
      const res = await execTx(client, tx, keypair, 'gas_futures.init_market');
      const id = extractCreatedId(res, `${cfg.pkgId}::gas_futures::GasMarket<`);
      if (id) logger.info(`gas_futures.market created id=${id}`);
    }
  }
}

async function deployPerpetuals(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair) {
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
        ],
      });
      const res = await execTx(client, tx, keypair, `perpetuals.init_market ${p.symbol}`);
      const id = extractCreatedId(res, `${cfg.pkgId}::perpetuals::PerpMarket<`);
      if (id) logger.info(`perpetuals.market created id=${id}`);
    }
  }
}

async function deployLending(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair) {
  if (!cfg.lending?.length) return;
  for (const l of cfg.lending) {
    if (!l.poolId) {
      const tx = new Transaction();
      tx.moveCall({
        target: `${cfg.pkgId}::lending::init_pool`,
        typeArguments: [l.asset],
        arguments: [
          tx.object(cfg.adminRegistryId),
          tx.pure.u64(l.baseRateBps),
          tx.pure.u64(l.multiplierBps),
          tx.pure.u64(l.jumpMultiplierBps),
          tx.pure.u64(l.kinkUtilBps),
          tx.pure.u64(l.reserveFactorBps),
          tx.pure.u64(l.collateralFactorBps),
          tx.pure.u64(l.liquidationCollateralBps),
          tx.pure.u64(l.liquidationBonusBps),
        ],
      });
      const res = await execTx(client, tx, keypair, `lending.init_pool ${l.asset}`);
      const id = extractCreatedId(res, `${cfg.pkgId}::lending::LendingPool<`);
      if (id) logger.info(`lending.pool created id=${id}`);
    }
  }
}

async function deployDexPools(client: SuiClient, cfg: DeployConfig, keypair: Ed25519Keypair) {
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
    await execTx(client, tx, keypair, 'dex.create_permissionless_pool');
  }
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
  await deployLending(client, deployConfig, keypair);
  await deployOptions(client, deployConfig, keypair);
  await deployFutures(client, deployConfig, keypair);
  await deployGasFutures(client, deployConfig, keypair);
  await deployPerpetuals(client, deployConfig, keypair);
  await deployDexPools(client, deployConfig, keypair);

  logger.info('Deploy completed');
}

main().catch((e) => {
  logger.error(e instanceof Error ? e.message : String(e));
  process.exit(1);
});
