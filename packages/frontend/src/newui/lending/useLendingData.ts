import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { SuiClient } from '@mysten/sui/client';
import { createSuiClient, defaultRpc } from '../../lib/network';
import { db } from '../../lib/storage';
import { loadSettings, getTokenBySymbol, getTokenByTypeTag } from '../../lib/settings.config';
import type { LendingMarketSummary } from './types';
import { getLatestPrice } from '../../lib/switchboard';
// (dedup import)

type MoveObject = any;

function getField(obj: any, path: string[]): any {
  return path.reduce((acc, k) => (acc && acc[k] != null ? acc[k] : undefined), obj);
}

async function getObjectContent(client: SuiClient, id: string): Promise<MoveObject | null> {
  const res = await client.getObject({ id, options: { showContent: true } });
  const c = (res.data as any)?.content;
  return c && c.dataType === 'moveObject' ? c : null;
}

function asNum(x: any): number { try { return Number(x ?? 0); } catch { return 0; } }
function asU128(x: any): bigint { try { return BigInt(x ?? 0); } catch { return 0n; } }

function formatSymbolPair(raw: string): string {
  // Already stored as String in Move; trust value
  return raw;
}

export type UseLendingDataResult = {
  markets: LendingMarketSummary[];
  tvlUsd: number;
  activeUsers: number;
  loading: boolean;
  refresh: () => Promise<void>;
};

/**
 * useLendingData: reads created markets from stored MarketInitialized2 events,
 * then fetches each market object for live fields and computes derived metrics.
 * User positions are intentionally omitted here; pass a user-specific hook later.
 */
export function useLendingData(address?: string | null) {
  const settings = loadSettings();
  const pkg = settings.contracts.pkgUnxversal;
  const [client] = useState<SuiClient>(() => createSuiClient(defaultRpc(settings.network)));
  const [markets, setMarkets] = useState<LendingMarketSummary[]>([]);
  const [tvlUsd, setTvlUsd] = useState(0);
  const [activeUsers, setActiveUsers] = useState(0);
  const [loading, setLoading] = useState(false);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const listMarketIds = useCallback(async (): Promise<Array<{ id: string; symbol: string }>> => {
    // scan events table for MarketInitialized2
    const typeName = `${pkg}::lending::MarketInitialized2`;
    const rows = await db.events.where('type').equals(typeName).toArray();
    const seen = new Map<string, { id: string; symbol: string }>();
    for (const r of rows) {
      const pj: any = r.parsedJson;
      const marketId = pj?.market_id?.id ?? pj?.market_id ?? null;
      const symbol = pj?.symbol ?? '';
      if (!marketId || !symbol) continue;
      seen.set(marketId, { id: marketId, symbol: formatSymbolPair(symbol) });
    }
    return Array.from(seen.values());
  }, [pkg]);

  async function getDynamicFieldObjectOrNull(client: SuiClient, parentId: string, name: any): Promise<any | null> {
    try {
      const obj = await client.getDynamicFieldObject({ parentId, name });
      const c = (obj.data as any)?.content;
      return c && c.dataType === 'moveObject' ? c : null;
    } catch {
      return null;
    }
  }

  async function readAddressU128(client: SuiClient, tableId: string, who: string): Promise<bigint> {
    const c = await getDynamicFieldObjectOrNull(client, tableId, { type: 'address', value: who });
    if (!c) return 0n;
    const v = c.fields?.value;
    if (typeof v === 'object' && v?.fields?.value != null) return BigInt(v.fields.value);
    try { return BigInt(v ?? 0); } catch { return 0n; }
  }

  async function readAddressU64(client: SuiClient, tableId: string, who: string): Promise<number> {
    const c = await getDynamicFieldObjectOrNull(client, tableId, { type: 'address', value: who });
    if (!c) return 0;
    const v = c.fields?.value;
    if (typeof v === 'object' && v?.fields?.value != null) return Number(v.fields.value);
    try { return Number(v ?? 0); } catch { return 0; }
  }

  async function readBorrowPosition(client: SuiClient, tableId: string, who: string): Promise<{ principal: bigint; snap: bigint } | null> {
    const c = await getDynamicFieldObjectOrNull(client, tableId, { type: 'address', value: who });
    if (!c) return null;
    const vf = c.fields?.value?.fields ?? {};
    try { return { principal: BigInt(vf.principal ?? 0), snap: BigInt(vf.interest_index_snap ?? 0) }; } catch { return null; }
  }

  const readMarket = useCallback(async (marketId: string, symbolPair: string): Promise<LendingMarketSummary | null> => {
    const content = await getObjectContent(client, marketId);
    if (!content) return null;
    const f = content.fields;

    // live balances
    const debtLiquidity = asNum(getField(f, ['debt_liquidity', 'fields', 'value']));
    const totalSupplyShares = asU128(f.total_supply_shares ?? 0n);
    const borrowIndex = asU128(f.borrow_index ?? 0n);
    const totalBorrowsPrincipal = asU128(f.total_borrows_principal ?? 0n);
    const lastAccruedMs = asNum(f.last_accrued_ms ?? 0);
    const irm = f.irm ?? { base_rate_bps: 0, multiplier_bps: 0, jump_multiplier_bps: 0, kink_util_bps: 1 };
    const params = {
      reserveFactorBps: asNum(f.reserve_factor_bps ?? 0),
      collateralFactorBps: asNum(f.collateral_factor_bps ?? 0),
      liquidationThresholdBps: asNum(f.liquidation_threshold_bps ?? 0),
      liquidationBonusBps: asNum(f.liquidation_bonus_bps ?? 0),
      flashFeeBps: asNum(f.flash_fee_bps ?? 0),
    };

    // derive util and rates
    const totalBorrow = Number(totalBorrowsPrincipal);
    const liquidity = debtLiquidity;
    const totalSupply = liquidity + totalBorrow;
    const utilBps = totalSupply > 0 ? Math.floor((totalBorrow * 10000) / totalSupply) : 0;
    const kink = Math.max(1, asNum(irm.kink_util_bps ?? 1));
    const base = asNum(irm.base_rate_bps ?? 0);
    const mult = asNum(irm.multiplier_bps ?? 0);
    const jump = asNum(irm.jump_multiplier_bps ?? 0);
    const denom = 10000;
    const borrowAprBps = utilBps <= kink
      ? base + Math.floor((mult * utilBps) / kink)
      : base + mult + Math.floor(jump * ((utilBps - kink) / Math.max(1, denom - kink)));
    const supplyAprBps = Math.floor(borrowAprBps * (utilBps / denom) * (1 - (params.reserveFactorBps / denom)));

    // parse symbol pair and token metas from settings
    const [collatSym, debtSym] = (symbolPair || '').split('/');
    const collatTk = getTokenBySymbol(collatSym) || getTokenByTypeTag(collatSym);
    const debtTk = getTokenBySymbol(debtSym) || getTokenByTypeTag(debtSym);

    const collateral = {
      symbol: collatSym ?? 'COL',
      name: collatTk?.name ?? collatSym ?? 'COL',
      decimals: collatTk?.decimals ?? 9,
      typeTag: collatTk?.typeTag ?? collatSym ?? '',
      iconUrl: collatTk?.iconUrl,
    };
    const debt = {
      symbol: debtSym ?? 'DEBT',
      name: debtTk?.name ?? debtSym ?? 'DEBT',
      decimals: debtTk?.decimals ?? 6,
      typeTag: debtTk?.typeTag ?? debtSym ?? '',
      iconUrl: debtTk?.iconUrl,
    };

    // Optional price for collateral in USD (UI may show max LTV value hints)
    const [baseSym] = (symbolPair || '').split('/');

    // User-specific fields (optional)
    let userSuppliedDebt: number | undefined = undefined;
    let userBorrowedDebt: number | undefined = undefined;
    let userCollateral: number | undefined = undefined;
    let userHealthFactor: number | undefined = undefined;

    if (address) {
      const supplierTableId = getField(f, ['supplier_shares', 'fields', 'id', 'id']);
      const collateralTableId = getField(f, ['collateral_of', 'fields', 'id', 'id']);
      const borrowsTableId = getField(f, ['borrows', 'fields', 'id', 'id']);
      if (supplierTableId) {
        const shares = await readAddressU128(client, supplierTableId, address);
        if (shares > 0n && totalSupplyShares > 0n) {
          const liqBI = BigInt(liquidity);
          const value = (liqBI * shares) / totalSupplyShares; // debt units
          userSuppliedDebt = Number(value > BigInt(Number.MAX_SAFE_INTEGER) ? BigInt(Number.MAX_SAFE_INTEGER) : value);
        } else {
          userSuppliedDebt = 0;
        }
      }
      if (collateralTableId) {
        const coll = await readAddressU64(client, collateralTableId, address);
        userCollateral = coll;
      }
      if (borrowsTableId) {
        const pos = await readBorrowPosition(client, borrowsTableId, address);
        if (pos && pos.principal > 0n) {
          // approximate current index with linear accrual since lastAccruedMs
          const YEAR_MS = 365 * 24 * 60 * 60 * 1000;
          const dt = Math.max(0, Date.now() - lastAccruedMs);
          const deltaIndex = BigInt(Math.floor((borrowAprBps * dt) / YEAR_MS)) * (10n ** 18n) / 10000n; // scaled to WAD
          const curIndex = borrowIndex + deltaIndex;
          const owed = (pos.principal * curIndex) / (10n ** 18n);
          userBorrowedDebt = Number(owed > BigInt(Number.MAX_SAFE_INTEGER) ? BigInt(Number.MAX_SAFE_INTEGER) : owed);
        } else {
          userBorrowedDebt = 0;
        }
      }
      // Health factor if price is available and borrowed > 0
      const priceUsd = getLatestPrice(`${baseSym}/USD`) ?? null;
      if (priceUsd != null && (userBorrowedDebt ?? 0) > 0) {
        const dColl = collateral.decimals;
        const dDebt = debt.decimals;
        const lt = Math.floor(params.liquidationThresholdBps / 100) / 100; // percent -> fraction
        const collUsd = (userCollateral ?? 0) / Math.pow(10, dColl) * priceUsd;
        const debtUnits = (userBorrowedDebt ?? 0) / Math.pow(10, dDebt);
        const maxDebtUsd = collUsd * lt;
        userHealthFactor = debtUnits > 0 ? Math.max(0.01, maxDebtUsd / debtUnits) : undefined;
      }
    }

    const out: LendingMarketSummary = {
      id: marketId,
      symbolPair,
      collateral,
      debt,
      supplyApy: Number((supplyAprBps / 100).toFixed(2)),
      borrowApy: Number((borrowAprBps / 100).toFixed(2)),
      totalSupplyDebt: totalSupply,
      totalBorrowDebt: totalBorrow,
      utilizationRate: Number((utilBps / 100).toFixed(1)),
      totalLiquidityDebt: liquidity,
      maxLtv: Math.floor(params.collateralFactorBps / 100),
      liquidationThreshold: Math.floor(params.liquidationThresholdBps / 100),
      reserveFactor: Math.floor(params.reserveFactorBps / 100),
      userSuppliedDebt,
      userBorrowedDebt,
      userCollateral,
      userHealthFactor,
    };
    return out;
  }, [client]);

  const refresh = useCallback(async () => {
    if (!pkg) return;
    setLoading(true);
    try {
      const ids = await listMarketIds();
      const rows: LendingMarketSummary[] = [];
      for (const m of ids) {
        const row = await readMarket(m.id, m.symbol);
        if (row) rows.push(row);
      }
      setMarkets(rows);
      // Aggregate TVL from debt totals (USDC-denominated markets)
      const tvl = rows.reduce((acc, r) => acc + (r.totalSupplyDebt || 0), 0);
      setTvlUsd(tvl);
      // Approximate active users using unique addresses in recent events
      const types = [
        `${pkg}::lending::DebtSupplied`,
        `${pkg}::lending::DebtWithdrawn`,
        `${pkg}::lending::CollateralDeposited2`,
        `${pkg}::lending::DebtBorrowed`,
        `${pkg}::lending::DebtRepaid`,
      ];
      const rowsEv = await db.events.where('type').anyOf(types).toArray();
      const uniq = new Set<string>();
      for (const r of rowsEv) {
        const pj: any = r.parsedJson;
        const who = pj?.who || pj?.borrower || null;
        if (typeof who === 'string') uniq.add(who.toLowerCase());
      }
      setActiveUsers(uniq.size);
    } finally {
      setLoading(false);
    }
  }, [pkg, listMarketIds, readMarket]);

  useEffect(() => {
    void refresh();
    if (timerRef.current) clearInterval(timerRef.current);
    // Poll markets moderately (5s)
    timerRef.current = setInterval(() => void refresh(), 5000);
    return () => { if (timerRef.current) clearInterval(timerRef.current); };
  }, [refresh]);

  return useMemo<UseLendingDataResult>(() => ({ markets, tvlUsd, activeUsers, loading, refresh }), [markets, tvlUsd, activeUsers, loading, refresh]);
}


