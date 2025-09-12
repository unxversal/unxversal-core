import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { SuiClient } from '@mysten/sui/client';
import { createSuiClient, defaultRpc } from '../../lib/network';
import { toast } from 'sonner';
import { useSuiClient, useSignAndExecuteTransaction } from '@mysten/dapp-kit';
import { StakingClient } from '../../protocols/staking/client';
import { loadSettings as loadAppSettings } from '../../lib/settings.config';
import { loadSettings, getTokenBySymbol } from '../../lib/settings.config';
import { db } from '../../lib/storage';
import type { StakingComponentProps } from './types';

type PoolTables = {
  activeByWeekTableId: string;
  rewardByWeekTableId: string;
};

type PoolCore = {
  poolId: string;
  currentWeek: number;
  totalActiveStake: bigint;
  stakeVaultBalance: bigint;
  rewardVaultBalance: bigint;
  rewardThisWeek: bigint;
  tables: PoolTables;
};

const WEEK_MS = 7 * 24 * 60 * 60 * 1000;

function asBigInt(x: any): bigint {
  if (typeof x === 'bigint') return x;
  if (typeof x === 'number') return BigInt(Math.floor(x));
  if (typeof x === 'string') return BigInt(x);
  return 0n;
}

async function getObjectContent(client: SuiClient, id: string): Promise<any | null> {
  const res = await client.getObject({ id, options: { showContent: true } });
  const c = (res.data as any)?.content;
  return c && c.dataType === 'moveObject' ? c : null;
}

function getField(obj: any, path: string[]): any {
  return path.reduce((acc, k) => (acc && acc[k] != null ? acc[k] : undefined), obj);
}

async function fetchPoolCore(client: SuiClient, poolId: string): Promise<PoolCore> {
  const content = await getObjectContent(client, poolId);
  if (!content) throw new Error('Pool object not found');
  const fields = content.fields;

  const currentWeek = Number(fields.current_week ?? 0);
  const totalActiveStake = asBigInt(fields.total_active_stake ?? 0);
  const stakeVaultBalance = asBigInt(getField(fields, ['stake_vault', 'fields', 'value']));
  const rewardVaultBalance = asBigInt(getField(fields, ['reward_vault', 'fields', 'value']));

  const activeByWeekTableId = getField(fields, ['active_by_week', 'fields', 'id', 'id']);
  const rewardByWeekTableId = getField(fields, ['reward_by_week', 'fields', 'id', 'id']);

  // reward for current week, if any
  const rewardThisWeek = await fetchTableU64(client, rewardByWeekTableId, currentWeek);

  return {
    poolId,
    currentWeek,
    totalActiveStake,
    stakeVaultBalance,
    rewardVaultBalance,
    rewardThisWeek,
    tables: { activeByWeekTableId, rewardByWeekTableId },
  };
}

async function fetchTableEntries(client: SuiClient, tableId: string, limit = 512): Promise<Map<number, bigint>> {
  const map = new Map<number, bigint>();
  let cursor: string | null = null;
  while (true) {
    const page = await client.getDynamicFields({ parentId: tableId, cursor, limit: 200 });
    for (const e of page.data) {
      const obj = await client.getObject({ id: e.objectId, options: { showContent: true } });
      const c = (obj.data as any)?.content;
      if (!c || c.dataType !== 'moveObject') continue;
      const name = getField(c, ['fields', 'name', 'value']);
      const value = getField(c, ['fields', 'value']);
      const week = Number(name ?? 0);
      const v = typeof value === 'object' && value?.fields?.value != null ? asBigInt(value.fields.value) : asBigInt(value);
      map.set(week, v);
      if (map.size >= limit) break;
    }
    if (!page.hasNextPage || !page.nextCursor || map.size >= limit) break;
    cursor = page.nextCursor;
  }
  return map;
}

async function fetchTableU64(client: SuiClient, tableId: string, key: number): Promise<bigint> {
  try {
    const obj = await client.getDynamicFieldObject({ parentId: tableId, name: { type: 'u64', value: String(key) } });
    const c = (obj.data as any)?.content;
    if (!c || c.dataType !== 'moveObject') return 0n;
    const value = getField(c, ['fields', 'value']);
    return typeof value === 'object' && value?.fields?.value != null ? asBigInt(value.fields.value) : asBigInt(value);
  } catch {
    return 0n;
  }
}

type StakerOnChain = {
  active_stake: bigint;
  pending_stake: bigint;
  activate_week: number;
  pending_unstake: bigint;
  deactivate_week: number;
  last_claimed_week: number;
};

async function fetchStaker(client: SuiClient, poolId: string, address: string): Promise<StakerOnChain | null> {
  try {
    const obj = await client.getDynamicFieldObject({ parentId: poolId, name: { type: 'address', value: address } });
    const c = (obj.data as any)?.content;
    if (!c || c.dataType !== 'moveObject') return null;
    const value = getField(c, ['fields', 'value', 'fields']);
    if (!value) return null;
    return {
      active_stake: asBigInt(value.active_stake ?? 0),
      pending_stake: asBigInt(value.pending_stake ?? 0),
      activate_week: Number(value.activate_week ?? 0),
      pending_unstake: asBigInt(value.pending_unstake ?? 0),
      deactivate_week: Number(value.deactivate_week ?? 0),
      last_claimed_week: Number(value.last_claimed_week ?? 0),
    };
  } catch {
    return null;
  }
}

function u128MulDiv(a: bigint, b: bigint, denom: bigint): bigint {
  if (denom === 0n) return 0n;
  return (a * b) / denom;
}

function computeClaimable(
  pool: PoolCore,
  st: StakerOnChain,
  activeByWeek: Map<number, bigint>,
  rewardByWeek: Map<number, bigint>,
): { claimable: bigint; toWeek: number } {
  const start = BigInt(st.last_claimed_week + 1);
  const end = pool.currentWeek > 0 ? BigInt(pool.currentWeek - 1) : 0n;
  if (end < start) return { claimable: 0n, toWeek: st.last_claimed_week };

  let acc = 0n;
  let active = st.active_stake;

  for (let w = start; w <= end; w++) {
    const wi = Number(w);
    if (st.activate_week !== 0 && wi === st.activate_week && st.pending_stake > 0n) {
      active = active + st.pending_stake;
    }
    if (st.deactivate_week !== 0 && wi === st.deactivate_week && st.pending_unstake > 0n) {
      active = active >= st.pending_unstake ? active - st.pending_unstake : 0n;
    }
    const poolActive = activeByWeek.get(wi) ?? pool.totalActiveStake;
    const weekReward = rewardByWeek.get(wi) ?? 0n;
    if (poolActive > 0n && active > 0n && weekReward > 0n) {
      const share = u128MulDiv(weekReward, active, poolActive);
      acc += share;
    }
  }
  return { claimable: acc, toWeek: Number(end) };
}

async function sumClaimedRewards(pkg: string, who: string): Promise<bigint> {
  const typeName = `${pkg}::staking::RewardsClaimed`;
  const rows = await db.events.where('type').equals(typeName).toArray();
  let acc = 0n;
  for (const r of rows) {
    const pj: any = r.parsedJson;
    if (pj && (pj.who?.toLowerCase?.() === who.toLowerCase())) {
      acc += asBigInt(pj.amount ?? 0);
    }
  }
  return acc;
}

export function useStakingData(address?: string | null) {
  const settings = loadSettings();
  const pkg = settings.contracts.pkgUnxversal;
  const poolId = settings.staking?.poolId || '';
  const tokenInfo = getTokenBySymbol('UNXV', settings);
  const symbol = tokenInfo?.symbol || 'UNXV';
  const decimals = tokenInfo?.decimals ?? 9;
  const [client] = useState<SuiClient>(() => createSuiClient(defaultRpc(settings.network)));
  const suiClient = useSuiClient();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();

  const [data, setData] = useState<Pick<StakingComponentProps,
    'poolId' | 'symbol' | 'decimals' | 'currentWeek' | 'totalActiveStake' | 'stakeVaultBalance' | 'rewardVaultBalance' | 'rewardThisWeek' | 'weeklySnapshots' | 'apyEstimate' | 'nextWeekStartMs' | 'address' | 'walletUnxvBalance' | 'staker' | 'claimableRewards' | 'claimedToWeek' | 'claimedRewardsTotal' | 'tier'
  > | null>(null);
  const [loading, setLoading] = useState(false);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const refresh = useCallback(async () => {
    if (!pkg || !poolId) return;
    setLoading(true);
    try {
      const pool = await fetchPoolCore(client, poolId);
      const [activeByWeek, rewardByWeek] = await Promise.all([
        fetchTableEntries(client, pool.tables.activeByWeekTableId, 1024),
        fetchTableEntries(client, pool.tables.rewardByWeekTableId, 1024),
      ]);

      // build snapshots sorted by week asc, last 8-12 for UI
      const weeks = Array.from(new Set([...activeByWeek.keys(), ...rewardByWeek.keys()])).sort((a, b) => a - b);
      const snapshots = weeks.slice(Math.max(0, weeks.length - 12)).map((w) => ({ week: w, active: activeByWeek.get(w) ?? pool.totalActiveStake, reward: rewardByWeek.get(w) ?? 0n }));

      const st = address ? await fetchStaker(client, poolId, address) : null;
      const staker = st ?? { active_stake: 0n, pending_stake: 0n, activate_week: 0, pending_unstake: 0n, deactivate_week: 0, last_claimed_week: 0 };

      const { claimable, toWeek } = computeClaimable(pool, staker, activeByWeek, rewardByWeek);
      const nextWeekStartMs = (pool.currentWeek + 1) * WEEK_MS;

      // Wallet UNXV balance via getCoins typeTag
      let walletUnxvBalance = 0n;
      try {
        if (address && tokenInfo?.packageId && tokenInfo.moduleName && tokenInfo.structName) {
          const typeTag = `${tokenInfo.packageId}::${tokenInfo.moduleName}::${tokenInfo.structName}`;
          const coins = await client.getCoins({ owner: address, coinType: typeTag });
          for (const c of coins.data) walletUnxvBalance += asBigInt(c.balance);
        }
      } catch {}

      // Tier computation based on activeStake mirroring old UI (values only shown)
      const activeStake = staker.active_stake;
      const activeInUnits = Number(activeStake) / (10 ** decimals);
      const tier = (() => {
        if (activeInUnits >= 500000) return { tier: 6, name: 'Midnight Ocean', discountPct: 40 };
        if (activeInUnits >= 100000) return { tier: 5, name: 'Cobalt Trench', discountPct: 30 };
        if (activeInUnits >= 10000) return { tier: 4, name: 'Indigo Waves', discountPct: 20 };
        if (activeInUnits >= 1000) return { tier: 3, name: 'Teal Harbor', discountPct: 15 };
        if (activeInUnits >= 100) return { tier: 2, name: 'Silver Stream', discountPct: 10 };
        if (activeInUnits >= 10) return { tier: 1, name: 'Crystal Pool', discountPct: 5 };
        return { tier: 0, name: 'Frost Shore', discountPct: 0 };
      })();

      const claimedRewardsTotal = address ? await sumClaimedRewards(pkg, address) : 0n;

      setData({
        poolId,
        symbol,
        decimals,
        currentWeek: pool.currentWeek,
        totalActiveStake: pool.totalActiveStake,
        stakeVaultBalance: pool.stakeVaultBalance,
        rewardVaultBalance: pool.rewardVaultBalance,
        rewardThisWeek: pool.rewardThisWeek,
        weeklySnapshots: snapshots,
        apyEstimate: undefined,
        nextWeekStartMs,
        address: address ?? undefined,
        walletUnxvBalance,
        staker: {
          activeStake: staker.active_stake,
          pendingStake: staker.pending_stake,
          activateWeek: staker.activate_week,
          pendingUnstake: staker.pending_unstake,
          deactivateWeek: staker.deactivate_week,
          lastClaimedWeek: staker.last_claimed_week,
        },
        claimableRewards: claimable,
        claimedToWeek: toWeek,
        claimedRewardsTotal,
        tier,
      });
    } finally {
      setLoading(false);
    }
  }, [client, pkg, poolId, address, decimals, symbol]);

  useEffect(() => {
    void refresh();
    if (timerRef.current) clearInterval(timerRef.current);
    // staking is low frequency → 15s default
    timerRef.current = setInterval(() => void refresh(), 15000);
    return () => { if (timerRef.current) clearInterval(timerRef.current); };
  }, [refresh]);

  // APY estimate from last N weeks
  const apyFromSnapshots = useMemo(() => {
    if (!data?.weeklySnapshots || data.weeklySnapshots.length === 0) return undefined;
    const weeks = data.weeklySnapshots.slice(-8);
    const totalRewards = weeks.reduce((acc, w) => acc + (w.reward ?? 0n), 0n);
    const avgActive = weeks.reduce((acc, w) => acc + (w.active ?? 0n), 0n) / BigInt(weeks.length || 1);
    if (avgActive === 0n) return undefined;
    const weeklyYield = Number(totalRewards) / Number(avgActive) / (weeks.length || 1);
    return Math.max(0, weeklyYield * 52 * 100);
  }, [data?.weeklySnapshots]);

  // Actions: stake, unstake, claim
  const submitStake = useCallback(async (amountBaseUnits: bigint) => {
    if (!address) { toast.error('Connect wallet'); return; }
    if (!pkg || !poolId) { toast.error('Missing staking settings'); return; }
    try {
      toast.loading('Preparing stake…', { id: 'stake' , position: 'top-center'});
      const sc = new StakingClient(pkg);
      // Build tx that merges coins and splits to exact amount
      const typeTag = tokenInfo?.packageId && tokenInfo.moduleName && tokenInfo.structName ? `${tokenInfo.packageId}::${tokenInfo.moduleName}::${tokenInfo.structName}` : '';
      if (!typeTag) throw new Error('UNXV type missing');
      const coins = await suiClient.getCoins({ owner: address, coinType: typeTag });
      if (!coins.data.length) throw new Error('No UNXV coins');
      const tx = sc.stake({ poolId, unxvCoinId: coins.data[0].coinObjectId });
      // Merge rest into first and then split to desired amount
      for (let i = 1; i < coins.data.length; i++) tx.mergeCoins(tx.object(coins.data[0].coinObjectId), [tx.object(coins.data[i].coinObjectId)]);
      const coin = tx.splitCoins(tx.object(coins.data[0].coinObjectId), [tx.pure.u64(amountBaseUnits)]);
      // Replace call arg with split coin
      (tx as any).blockData?.transactions?.forEach?.((t: any) => {
        if (t.kind === 'MoveCall' && t.target.endsWith('staking::stake_unx')) {
          t.arguments[1] = coin;
        }
      });
      await signAndExecute({ transaction: tx, chain: loadAppSettings().network === 'mainnet' ? 'sui:mainnet' : 'sui:testnet' });
      toast.success('Staked', { id: 'stake', position: 'top-center' });
      await refresh();
    } catch (e: any) {
      toast.error(e?.message ?? 'Stake failed', { id: 'stake', position: 'top-center' });
    }
  }, [address, pkg, poolId, tokenInfo?.packageId, tokenInfo?.moduleName, tokenInfo?.structName, signAndExecute, suiClient, refresh]);

  const submitUnstake = useCallback(async (amountBaseUnits: bigint) => {
    if (!address) { toast.error('Connect wallet'); return; }
    if (!pkg || !poolId) { toast.error('Missing staking settings'); return; }
    try {
      toast.loading('Submitting unstake…', { id: 'unstake', position: 'top-center' });
      const sc = new StakingClient(pkg);
      const tx = sc.unstake({ poolId, amount: amountBaseUnits });
      await signAndExecute({ transaction: tx, chain: loadAppSettings().network === 'mainnet' ? 'sui:mainnet' : 'sui:testnet' });
      toast.success('Unstake scheduled', { id: 'unstake', position: 'top-center' });
      await refresh();
    } catch (e: any) {
      toast.error(e?.message ?? 'Unstake failed', { id: 'unstake', position: 'top-center' });
    }
  }, [address, pkg, poolId, signAndExecute, refresh]);

  const submitClaim = useCallback(async () => {
    if (!address) { toast.error('Connect wallet'); return; }
    if (!pkg || !poolId) { toast.error('Missing staking settings'); return; }
    try {
      toast.loading('Claiming rewards…', { id: 'claim', position: 'top-center' });
      const sc = new StakingClient(pkg);
      const tx = sc.claimRewards({ poolId });
      await signAndExecute({ transaction: tx, chain: loadAppSettings().network === 'mainnet' ? 'sui:mainnet' : 'sui:testnet' });
      toast.success('Rewards claimed', { id: 'claim', position: 'top-center' });
      await refresh();
    } catch (e: any) {
      toast.error(e?.message ?? 'Claim failed', { id: 'claim', position: 'top-center' });
    }
  }, [address, pkg, poolId, signAndExecute, refresh]);

  const next = useMemo(() => ({ data: data ? { ...data, apyEstimate: apyFromSnapshots } : null, loading, refresh, submitStake, submitUnstake, submitClaim }), [data, loading, refresh, submitStake, submitUnstake, submitClaim, apyFromSnapshots]);
  return next;
}


