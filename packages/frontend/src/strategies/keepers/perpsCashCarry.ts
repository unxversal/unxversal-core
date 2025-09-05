import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { PerpetualsClient } from '../../protocols/perpetuals/client';
import { DexClient } from '../../protocols/dex/dex';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';

function u64(n: number | bigint): bigint { return BigInt(Math.max(0, Math.floor(Number(n)))); }

export type PerpsCarryConfig = {
  // Perps
  pkg: string;
  marketId: string;
  oracleRegistryId: string;
  aggregatorId: string;
  feeConfigId: string;
  feeVaultId: string;
  stakingPoolId: string;
  // Spot via DeepBook
  dex: {
    pkg: string;
    poolId: string;
    balanceManagerId: string;
    tradeProofId: string;
    feeConfigId: string;
    feeVaultId: string;
    deepbookIndexerUrl: string;
  };
  // Target notional per action in quote units
  targetNotionalQuote: number;
  // Optional off-chain signal: positive means short perp / long spot
  expectFundingPositive?: () => Promise<boolean | null>;
  refreshSecs?: number;
};

export function createPerpsCashCarryKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: PerpsCarryConfig): Keeper {
  const perp = new PerpetualsClient(cfg.pkg);
  const dex = new DexClient(cfg.dex.pkg);
  const db = buildDeepbookPublicIndexer(cfg.dex.deepbookIndexerUrl);

  async function getMid(): Promise<bigint> {
    const ob = await db.orderbook(cfg.dex.poolId, { level: 1, depth: 1 });
    if (ob.bids?.length && ob.asks?.length) {
      const b = BigInt(ob.bids[0][0]); const a = BigInt(ob.asks[0][0]);
      return (b + a) / 2n;
    }
    return 0n;
  }

  async function step(): Promise<void> {
    // Derive direction
    const sig = cfg.expectFundingPositive ? await cfg.expectFundingPositive() : null;
    if (sig == null) return;
    const mid = await getMid(); if (mid <= 0n) return;
    const baseQty = u64(Math.max(1, Math.floor(cfg.targetNotionalQuote / Number(mid))));

    // perps leg
    const txPerp = sig
      ? perp.openShort({ marketId: cfg.marketId, oracleRegistryId: cfg.oracleRegistryId, aggregatorId: cfg.aggregatorId, feeConfigId: cfg.feeConfigId, feeVaultId: cfg.feeVaultId, stakingPoolId: cfg.stakingPoolId, qty: baseQty })
      : perp.openLong({ marketId: cfg.marketId, oracleRegistryId: cfg.oracleRegistryId, aggregatorId: cfg.aggregatorId, feeConfigId: cfg.feeConfigId, feeVaultId: cfg.feeVaultId, stakingPoolId: cfg.stakingPoolId, qty: baseQty });

    if (await devInspectOk(client, sender, txPerp)) await exec(txPerp);

    // spot leg (market order for immediacy)
    const txSpot = dex.placeMarketOrder({
      poolId: cfg.dex.poolId,
      balanceManagerId: cfg.dex.balanceManagerId,
      tradeProofId: cfg.dex.tradeProofId,
      feeConfigId: cfg.dex.feeConfigId,
      feeVaultId: cfg.dex.feeVaultId,
      clientOrderId: BigInt(Date.now()),
      selfMatchingOption: 0,
      quantity: baseQty,
      isBid: sig, // if funding positive: buy spot (bid), else sell spot
      payWithDeep: false,
    });
    if (await devInspectOk(client, sender, txSpot)) await exec(txSpot);
  }

  return makeLoop(step, Math.max(1000, (cfg.refreshSecs ?? 60) * 1000));
}



