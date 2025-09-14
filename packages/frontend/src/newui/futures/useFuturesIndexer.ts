import { useEffect, useRef, useState } from 'react';
import type { SuiClient } from '@mysten/sui/client';
import type { FuturesComponentProps, FuturesSummary, OrderbookSnapshot, TradeFillRow, FuturesPositionRow, UserOrderRow, OrderHistoryRow } from './types';
import { loadSettings } from '../../lib/settings.config';
import { getLatestPrice } from '../../lib/switchboard';

export type UseFuturesIndexerArgs = {
  client: SuiClient;
  selectedSymbol: string; // e.g., "SUI/USDC"
  selectedExpiryMs: number | null;
  address?: string | null; // connected wallet address for user-specific data
  enabled?: boolean;
};

export function useFuturesIndexer({ client, selectedSymbol, selectedExpiryMs, address, enabled = true }: UseFuturesIndexerArgs): {
  props: Partial<FuturesComponentProps> & Pick<FuturesComponentProps,
    'selectedSymbol' | 'allSymbols' | 'onSelectSymbol' |
    'selectedExpiryMs' | 'availableExpiriesMs' | 'onSelectExpiry' |
    'marketId' | 'summary' | 'orderBook' | 'recentTrades' |
    'positions' | 'openOrders' | 'tradeHistory' | 'orderHistory'> & {
      initialMarginBps?: number;
      maintenanceMarginBps?: number;
      maxLeverage?: number;
    };
  loading: boolean;
  error?: string;
} {
  const settings = loadSettings();
  const pkg = settings.contracts.pkgUnxversal;

  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | undefined>();

  // selections
  const allSymbols = settings.markets.watchlist;
  const [availableExpiriesMs, setAvailableExpiriesMs] = useState<number[]>([]);
  const [marketId, setMarketId] = useState<string>('');

  // core data
  const [summary, setSummary] = useState<FuturesSummary>({});
  const [orderBook, setOrderBook] = useState<OrderbookSnapshot>({ bids: [], asks: [] });
  const [recentTrades, setRecentTrades] = useState<TradeFillRow[]>([]);
  const [initialMarginBpsState, setInitialMarginBpsState] = useState<number | undefined>(undefined);
  const [maintenanceMarginBpsState, setMaintenanceMarginBpsState] = useState<number | undefined>(undefined);
  const [maxLeverageState, setMaxLeverageState] = useState<number | undefined>(undefined);

  // user
  const [positions, setPositions] = useState<FuturesPositionRow[]>([]);
  const [openOrders, setOpenOrders] = useState<UserOrderRow[]>([]);
  const [tradeHistory, setTradeHistory] = useState<TradeFillRow[]>([]);
  const [orderHistory, setOrderHistory] = useState<OrderHistoryRow[]>([]);

  const onSelectSymbol = (_sym: string) => {};
  const onSelectExpiry = (_ms: number) => {};

  // Internal state maps
  type MarketMeta = { marketId: string; expiryMs: number | null; contractSize: number };
  const marketsBySymbol = useRef<Map<string, MarketMeta[]>>(new Map());
  type OrderMeta = { orderId: string; isBid: boolean; price1e6: number; remaining: number; expireTs: number; maker: string; marketId: string };
  const ordersByMarket = useRef<Map<string, Map<string, OrderMeta>>>(new Map());
  type UserPos = { marketId: string; symbol: string; contractSize: number; longQty: number; shortQty: number; avgLong1e6: number; avgShort1e6: number; markPrice1e6?: number; collat?: number };
  const positionsByUser = useRef<Map<string, UserPos>>(new Map());
  const lastMarketReadRef = useRef<number>(0);

  function pythSymbolOf(selected: string): string | null {
    const [base] = (selected || '').split('/');
    if (!base) return null;
    const canonBase = base.startsWith('W') && base.length > 1 ? base.slice(1) : base;
    const m: Record<string, string> = {
      'SUI': 'SUI/USD',
      'ETH': 'ETH/USD',
      'BTC': 'BTC/USD',
      'SOL': 'SOL/USD',
    };
    return m[canonBase] || null;
  }

  function asNumVec(field: any): number[] {
    try {
      if (Array.isArray(field)) return field.map((x) => Number(x));
      if (field && Array.isArray(field.value)) return field.value.map((x: any) => Number(x));
      if (field && field.fields && Array.isArray(field.fields.contents)) return field.fields.contents.map((x: any) => Number(x));
      return [];
    } catch { return []; }
  }

  function computeTwap(ts: number[], px1e6: number[], endMs: number, windowMs: number): number | undefined {
    if (ts.length === 0 || px1e6.length === 0) return undefined;
    const n = Math.min(ts.length, px1e6.length);
    const startMs = Math.max(0, endMs - windowMs);
    let sumWeighted = 0, sumDt = 0;
    let prevT = startMs;
    let prevPx = px1e6[0];
    for (let i = 0; i < n; i++) {
      const t = ts[i];
      const p = px1e6[i];
      if (t < startMs) { prevT = t; prevPx = p; continue; }
      const dt = Math.max(0, t - prevT);
      sumWeighted += dt * prevPx;
      sumDt += dt;
      prevT = t; prevPx = p;
    }
    const tailDt = Math.max(0, endMs - prevT);
    sumWeighted += tailDt * prevPx;
    sumDt += tailDt;
    if (sumDt === 0) return (px1e6[n - 1] ?? 0) / 1_000_000;
    return (sumWeighted / sumDt) / 1_000_000;
  }

  useEffect(() => {
    if (!enabled) { setLoading(false); return; }
    let stopped = false;
    marketsBySymbol.current.clear();
    setAvailableExpiriesMs([]);
    setOrderBook({ bids: [], asks: [] });
    setRecentTrades([]);
    setTradeHistory([]);
    setOpenOrders([]);
    setPositions([]);
    setSummary({});
    ordersByMarket.current.clear();
    positionsByUser.current.clear();

    const run = async () => {
      if (!pkg) { setError('Set pkgUnxversal in Settings'); setLoading(false); return; }
      setError(undefined); setLoading(true);

      // Backfill and follow events for futures module to discover markets and builds snapshots.
      const QUERY = { MoveModule: { package: pkg, module: 'futures' } } as const;
      const PAGE_LIMIT = 100;
      const now = Date.now();
      const since = now - 30 * 24 * 3600 * 1000;

      const handleEvent = (ev: any) => {
        const t: string = ev.type;
        const pj: any = ev.parsedJson || {};
        if (t.endsWith('::futures::MarketInitialized')) {
          const sym = String(pj.symbol);
          const expiryMs = Number(pj.expiry_ms ?? 0) || null;
          const contractSize = Number(pj.contract_size ?? 0);
          const mId = String(pj.market_id?.id ?? pj.market_id ?? '');
          if (!mId) return;
          const arr = marketsBySymbol.current.get(sym) || [];
          if (!arr.find((x) => x.marketId === mId)) arr.push({ marketId: mId, expiryMs, contractSize });
          marketsBySymbol.current.set(sym, arr);
          if (sym === selectedSymbol) {
            const exps = Array.from(new Set(arr.map((m) => m.expiryMs || 0))).filter(Boolean).sort((a,b)=>a-b);
            setAvailableExpiriesMs(exps);
            const cur = arr.find((m) => (m.expiryMs || 0) === (selectedExpiryMs || 0)) || arr[0];
            if (cur) setMarketId(cur.marketId);
          }
        }
        else if (t.endsWith('::futures::OrderPlaced')) {
          const mId = String(pj.market_id?.id ?? pj.market_id ?? marketId);
          const orderId = String(pj.order_id);
          const isBid = Boolean(pj.is_bid);
          const price1e6 = Number(pj.price_1e6 ?? pj.price ?? 0);
          const quantity = Number(pj.quantity ?? 0);
          const expireTs = Number(pj.expire_ts ?? 0);
          const maker = String(pj.maker ?? '');
          if (!ordersByMarket.current.has(mId)) ordersByMarket.current.set(mId, new Map());
          ordersByMarket.current.get(mId)!.set(orderId, { orderId, isBid, price1e6, remaining: quantity, expireTs, maker, marketId: mId });
        }
        else if (t.endsWith('::futures::OrderFilled')) {
          const mId = String(pj.market_id?.id ?? pj.market_id ?? marketId);
          const maker = String(pj.maker);
          const taker = String(pj.taker);
          const price_1e6 = Number(pj.price_1e6 ?? pj.price ?? 0);
          const base_qty = Number(pj.base_qty ?? 0);
          const makerOrderId = String(pj.maker_order_id ?? pj.order_id ?? '');
          const ts = Number(pj.timestamp_ms ?? ev.timestampMs ?? Date.now());
          setRecentTrades((prev) => prev.concat({ maker, taker, priceQuote: price_1e6 / 1_000_000, baseQty: base_qty, tsMs: ts }).slice(-200));
          setTradeHistory((prev) => prev.concat({ maker, taker, priceQuote: price_1e6 / 1_000_000, baseQty: base_qty, tsMs: ts }).slice(-1000));
          const omap = ordersByMarket.current.get(mId);
          if (omap && makerOrderId && omap.has(makerOrderId)) {
            const rec = omap.get(makerOrderId)!;
            rec.remaining = Math.max(0, rec.remaining - base_qty);
            omap.set(makerOrderId, rec);
          }
        }
        else if (t.endsWith('::futures::OrderCanceled')) {
          const mId = String(pj.market_id?.id ?? pj.market_id ?? marketId);
          const orderId = String(pj.order_id);
          const omap = ordersByMarket.current.get(mId);
          if (omap) omap.delete(orderId);
          setOrderHistory((prev) => prev.concat({ kind: 'canceled', orderId, marketId: mId, tsMs: Number(ev.timestampMs ?? Date.now()) }));
        }
        else if (t.endsWith('::futures::Liquidated')) {
          // Optional: reflect in user position health
        }
        else if (t.endsWith('::futures::PositionChanged')) {
          const mId = String(pj.market_id?.id ?? pj.market_id ?? marketId);
          const who = String(pj.who ?? '');
          const isLong = Boolean(pj.is_long);
          const execPx1e6 = Number(pj.exec_price_1e6 ?? 0);
          const newLong = Number(pj.new_long ?? 0);
          const newShort = Number(pj.new_short ?? 0);
          // Find symbol/contractSize
          let sym = selectedSymbol; let cs = 1;
          for (const [symKey, arr] of marketsBySymbol.current.entries()) {
            const found = arr.find((m) => m.marketId === mId);
            if (found) { sym = symKey; cs = found.contractSize; break; }
          }
          const key = `${who}:${mId}`;
          const prev = positionsByUser.current.get(key) || { marketId: mId, symbol: sym, contractSize: cs, longQty: 0, shortQty: 0, avgLong1e6: 0, avgShort1e6: 0 };
          // Update avgs depending on direction
          if (isLong) {
            if (newLong > prev.longQty) {
              const add = newLong - prev.longQty;
              prev.avgLong1e6 = prev.longQty === 0 ? execPx1e6 : Math.floor(((prev.avgLong1e6 * prev.longQty) + (execPx1e6 * add)) / (prev.longQty + add));
            } else if (newLong === 0) {
              prev.avgLong1e6 = 0;
            }
          } else {
            if (newShort > prev.shortQty) {
              const add = newShort - prev.shortQty;
              prev.avgShort1e6 = prev.shortQty === 0 ? execPx1e6 : Math.floor(((prev.avgShort1e6 * prev.shortQty) + (execPx1e6 * add)) / (prev.shortQty + add));
            } else if (newShort === 0) {
              prev.avgShort1e6 = 0;
            }
          }
          prev.longQty = newLong; prev.shortQty = newShort; prev.symbol = sym; prev.contractSize = cs;
          positionsByUser.current.set(key, prev);
        }
        else if (t.endsWith('::futures::CollateralDeposited') || t.endsWith('::futures::CollateralWithdrawn')) {
          // Track approximate collateral for health (optional)
          const mId = String(pj.market_id?.id ?? pj.market_id ?? marketId);
          const who = String(pj.who ?? '');
          const amount = Number(pj.amount ?? 0);
          const key = `${who}:${mId}`;
          const prev = positionsByUser.current.get(key);
          if (prev) {
            const sign = t.endsWith('Deposited') ? 1 : -1;
            prev.collat = Math.max(0, (prev.collat ?? 0) + sign * amount);
            positionsByUser.current.set(key, prev);
          }
        }
      };

      const drainWindow = async (startMs: number, endMs: number) => {
        let c: { txDigest: string; eventSeq: string } | null = null;
        while (!stopped) {
          const res = await client.queryEvents({ query: { Any: [QUERY, { TimeRange: { startTime: String(startMs), endTime: String(endMs) } }] }, cursor: c, limit: PAGE_LIMIT, order: 'ascending' });
          const evs = res.data ?? [];
          if (evs.length === 0) break;
          for (const ev of evs) handleEvent(ev);
          if (!res.hasNextPage) break;
          c = res.nextCursor ?? null;
        }
      };

      try {
        const WIN = 7 * 24 * 3600 * 1000;
        for (let s = since; s < now; s += WIN) {
          const e = Math.min(s + WIN, now);
          await drainWindow(s, e);
        }
      } finally { setLoading(false); }

      const follow = async () => {
        let c: { txDigest: string; eventSeq: string } | null = null;
        while (!stopped) {
          try {
            const res = await client.queryEvents({ query: QUERY, cursor: c, limit: PAGE_LIMIT, order: 'ascending' });
            const evs = res.data ?? [];
            if (evs.length > 0) {
              for (const ev of evs) handleEvent(ev);
              c = res.nextCursor ?? { txDigest: evs[evs.length - 1].id.txDigest, eventSeq: String(evs[evs.length - 1].id.eventSeq) };
              continue;
            }
            await new Promise(r => setTimeout(r, 300));
          } catch {
            await new Promise(r => setTimeout(r, 400 + Math.random() * 400));
          }
        }
      };
      void follow();

      // Periodically read selected market object for live fields
      const pollMarketFields = async () => {
        if (!marketId) return;
        try {
          const nowMs = Date.now();
          if (nowMs - lastMarketReadRef.current < 2500) return;
          lastMarketReadRef.current = nowMs;
          const res = await client.getObject({ id: marketId, options: { showContent: true } });
          const content: any = (res.data as any)?.content;
          const f = content?.dataType === 'moveObject' ? content.fields : null;
          if (!f) return;
          const totalLong = Number(f.total_long_qty ?? 0);
          const totalShort = Number(f.total_short_qty ?? 0);
          const lastPx1e6 = Number(f.last_price_1e6 ?? 0);
          const im = Number(f.initial_margin_bps ?? 0);
          const mm = Number(f.maintenance_margin_bps ?? 0);
          // price selection: prefer on-chain last, else last trade
          const lastTrade = recentTrades[recentTrades.length - 1];
          let last = lastPx1e6 ? lastPx1e6 / 1_000_000 : (lastTrade ? lastTrade.priceQuote : undefined);
          if (last == null) {
            const ps = pythSymbolOf(selectedSymbol);
            const pv = ps ? getLatestPrice(ps) : null;
            if (pv != null) last = pv;
          }
          // 24h change and volume from trades window
          const cutoff = nowMs - 24 * 3600 * 1000;
          const trades24 = recentTrades.filter(t => t.tsMs >= cutoff);
          const vol24h = trades24.reduce((acc, t) => acc + (t.priceQuote * t.baseQty), 0);
          const price24 = trades24.length ? trades24[0].priceQuote : (recentTrades[0]?.priceQuote ?? last);
          const change24h = last != null && price24 != null && price24 > 0 ? ((last - price24) / price24) * 100 : undefined;
          // TWAP(5m)
          const tsVec = asNumVec((f.twap_ts_ms ?? f.twap_ts) ?? []);
          const pxVec = asNumVec((f.twap_px_1e6 ?? f.twap_px) ?? []);
          const twap5m = computeTwap(tsVec, pxVec, nowMs, 5 * 60 * 1000);
          setSummary((prev) => ({ ...prev, last, openInterest: totalLong + totalShort, vol24h, change24h, expiryMs: f.series?.fields?.expiry_ms ?? null, twap5m }));
          setInitialMarginBpsState(im || undefined);
          setMaintenanceMarginBpsState(mm || undefined);
          setMaxLeverageState(im > 0 ? (10000 / im) : undefined);
        } catch {}
      };
      const id = setInterval(pollMarketFields, 800);
      // Fire immediately for fast first paint
      void pollMarketFields();
      return () => { clearInterval(id); };
    };

    void run();
    return () => { stopped = true; };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [client, selectedSymbol, selectedExpiryMs, address, pkg, enabled]);

  return {
    props: {
      selectedSymbol,
      allSymbols,
      onSelectSymbol,
      selectedExpiryMs,
      availableExpiriesMs,
      onSelectExpiry,
      marketId,
      summary,
      orderBook,
      recentTrades,
      positions,
      openOrders,
      tradeHistory,
      orderHistory,
      initialMarginBps: initialMarginBpsState,
      maintenanceMarginBps: maintenanceMarginBpsState,
      maxLeverage: maxLeverageState,
    },
    loading,
    error,
  };
}


