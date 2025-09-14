import { useEffect, useMemo, useRef, useState } from 'react';
import type { SuiClient } from '@mysten/sui/client';
import type { FuturesComponentProps, FuturesSummary, OrderbookSnapshot, TradeFillRow, FuturesPositionRow, UserOrderRow, OrderHistoryRow } from './types';
import { loadSettings } from '../../lib/settings.config';

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
    'positions' | 'openOrders' | 'tradeHistory' | 'orderHistory'>;
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
          const im = Number(f.initial_margin_bps ?? 0);
          const mm = Number(f.maintenance_margin_bps ?? 0);
          const totalLong = Number(f.total_long_qty ?? 0);
          const totalShort = Number(f.total_short_qty ?? 0);
          const lastPx1e6 = Number(f.last_price_1e6 ?? 0);
          // price selection: prefer on-chain last, else last trade
          const lastTrade = recentTrades[recentTrades.length - 1];
          const last = lastPx1e6 ? lastPx1e6 / 1_000_000 : (lastTrade ? lastTrade.priceQuote : undefined);
          // 24h change and volume from trades window
          const cutoff = nowMs - 24 * 3600 * 1000;
          const trades24 = recentTrades.filter(t => t.tsMs >= cutoff);
          const vol24h = trades24.reduce((acc, t) => acc + (t.priceQuote * t.baseQty), 0);
          const price24 = trades24.length ? trades24[0].priceQuote : (recentTrades[0]?.priceQuote ?? last);
          const change24h = last != null && price24 != null && price24 > 0 ? ((last - price24) / price24) * 100 : undefined;
          setSummary((prev) => ({ ...prev, last, openInterest: totalLong + totalShort, vol24h, change24h, expiryMs: f.series?.fields?.expiry_ms ?? null }));

          // Build orderbook snapshot for selected market (aggregate by price)
          const omap = ordersByMarket.current.get(marketId) || new Map();
          const now = Date.now();
          const bids: Record<number, number> = {};
          const asks: Record<number, number> = {};
          for (const o of omap.values()) {
            if (o.expireTs && o.expireTs <= now) continue;
            if (o.remaining <= 0) continue;
            const px = o.price1e6 / 1_000_000;
            if (o.isBid) bids[px] = (bids[px] ?? 0) + o.remaining;
            else asks[px] = (asks[px] ?? 0) + o.remaining;
          }
          const bidLvls = Object.entries(bids).map(([p,q]) => ({ price: Number(p), qty: q as number })).sort((a,b)=> b.price - a.price).slice(0, 24);
          const askLvls = Object.entries(asks).map(([p,q]) => ({ price: Number(p), qty: q as number })).sort((a,b)=> a.price - b.price).slice(0, 24);
          setOrderBook({ bids: bidLvls, asks: askLvls });

          // Recompute user positions list (all markets) if address provided
          if (address) {
            const list: FuturesPositionRow[] = [];
            for (const pos of positionsByUser.current.values()) {
              if (!pos) continue;
              const markPx1e6 = lastPx1e6 || (last ? Math.floor(last * 1_000_000) : 0);
              const pnlLong = pos.longQty > 0 && pos.avgLong1e6 > 0 ? Math.floor(((markPx1e6 - pos.avgLong1e6) * pos.longQty * pos.contractSize) / 1_000_000) : 0;
              const pnlShort = pos.shortQty > 0 && pos.avgShort1e6 > 0 ? Math.floor(((pos.avgShort1e6 - markPx1e6) * pos.shortQty * pos.contractSize) / 1_000_000) : 0;
              const pnlQuote = (pnlLong + pnlShort) / 1;
              list.push({ marketId: pos.marketId, symbol: pos.symbol, expiryMs: null, contractSize: pos.contractSize, longQty: pos.longQty, shortQty: pos.shortQty, avgLong1e6: pos.avgLong1e6, avgShort1e6: pos.avgShort1e6, markPrice1e6: markPx1e6, pnlQuote });
            }
            setPositions(list);
            // Open orders scoped to user
            const myOrders: UserOrderRow[] = [];
            for (const [mId, om] of ordersByMarket.current.entries()) {
              for (const o of om.values()) {
                if (address && o.maker.toLowerCase() !== address.toLowerCase()) continue;
                myOrders.push({ orderId: o.orderId, marketId: mId, isBid: o.isBid, priceQuote: o.price1e6 / 1_000_000, qtyRemaining: o.remaining, expireTs: o.expireTs });
              }
            }
            setOpenOrders(myOrders);
          }
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
    },
    loading,
    error,
  };
}


