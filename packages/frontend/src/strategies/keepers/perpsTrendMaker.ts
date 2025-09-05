import type { SuiClient } from '@mysten/sui/client';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { PerpetualsClient } from '../../protocols/perpetuals/client';
import { readRiskCaps, clampOrderQtyByCaps } from '../../lib/riskCaps';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';
import { db } from '../../lib/storage';

function ema(arr: number[], n: number): number {
  if (arr.length === 0) return 0;
  const k = 2 / (n + 1);
  let e = arr[0];
  for (let i = 1; i < arr.length; i++) e = arr[i] * k + e * (1 - k);
  return e;
}

export type PerpsTrendConfig = {
  pkg: string;
  marketId: string;
  oracleRegistryId: string;
  aggregatorId: string;
  feeConfigId: string;
  feeVaultId: string;
  stakingPoolId: string;
  deepbookIndexerUrl: string;
  poolIdForMid: string;
  emaFast: number;
  emaSlow: number;
  qty: bigint;
  refreshSecs?: number;
};

export function createPerpsTrendMakerKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: PerpsTrendConfig): Keeper {
  const perp = new PerpetualsClient(cfg.pkg);
  const dbi = buildDeepbookPublicIndexer(cfg.deepbookIndexerUrl);

  async function getRecentPrices(): Promise<number[]> {
    const now = Date.now();
    const trades = await dbi.trades(cfg.poolIdForMid, { start_time: now - 15 * 60_000, end_time: now, limit: 500 });
    return trades.map((t: any) => Number(t.price));
  }

  async function estimateNetPosition(): Promise<number> {
    const t = `${cfg.pkg}::perpetuals::PositionChanged`;
    const rows = await db.events.where('type').equals(t).toArray();
    rows.sort((a, b) => (b.tsMs ?? 0) - (a.tsMs ?? 0));
    let net = 0;
    for (const r of rows.slice(0, 200)) {
      const p = (r.parsedJson as any) || {};
      if (p.who !== sender) continue;
      net = Number(p.new_long || 0) - Number(p.new_short || 0);
      break;
    }
    return net;
  }

  async function step(): Promise<void> {
    const px = await getRecentPrices();
    if (px.length < Math.max(cfg.emaFast, cfg.emaSlow)) return;
    const eFast = ema(px, cfg.emaFast);
    const eSlow = ema(px, cfg.emaSlow);
    const uptrend = eFast > eSlow;
    const net = await estimateNetPosition();

    const caps = await readRiskCaps(client, (import.meta as any).env.VITE_UNXV_PKG, (cfg as any).vaultId || '');
    const adjQty = clampOrderQtyByCaps(cfg.qty, caps);
    if (uptrend && net <= 0) {
      const tx = perp.openLong({ marketId: cfg.marketId, oracleRegistryId: cfg.oracleRegistryId, aggregatorId: cfg.aggregatorId, feeConfigId: cfg.feeConfigId, feeVaultId: cfg.feeVaultId, stakingPoolId: cfg.stakingPoolId, qty: adjQty });
      if (await devInspectOk(client, sender, tx)) await exec(tx);
    } else if (!uptrend && net >= 0) {
      const tx = perp.openShort({ marketId: cfg.marketId, oracleRegistryId: cfg.oracleRegistryId, aggregatorId: cfg.aggregatorId, feeConfigId: cfg.feeConfigId, feeVaultId: cfg.feeVaultId, stakingPoolId: cfg.stakingPoolId, qty: adjQty });
      if (await devInspectOk(client, sender, tx)) await exec(tx);
    }
  }

  return makeLoop(step, Math.max(1000, (cfg.refreshSecs ?? 15) * 1000));
}



