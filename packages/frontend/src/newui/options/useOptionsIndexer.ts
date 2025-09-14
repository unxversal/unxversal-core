import { useEffect, useRef, useState } from 'react';
import type { OptionsComponentProps, OptionChainRow, OptionsSummary, OpenInterestByExpiry, PositionRow, UserOrderRow, TradeFill, OrderHistoryRow } from './types';
import { SuiClient } from '@mysten/sui/client';
import { loadSettings } from '../../lib/settings.config';

export type UseOptionsIndexerArgs = {
  client: SuiClient;
  selectedSymbol: string; // e.g., "SUI/USDC"
  selectedExpiryMs: number | null;
  enabled?: boolean;
};

// Helpers to decode symbol bytes from parsedJson
function decodeSymbolBytes(sb: any): string {
  try {
    if (!sb) return '';
    if (Array.isArray(sb)) {
      return String.fromCharCode(...(sb as number[]));
    }
    if (typeof sb === 'string') {
      try {
        const bin = atob(sb);
        return bin;
      } catch {
        return sb;
      }
    }
    return String(sb);
  } catch {
    return '';
  }
}

export function useOptionsIndexer({ client, selectedSymbol, selectedExpiryMs, enabled = true }: UseOptionsIndexerArgs): {
  props: Partial<OptionsComponentProps> & Pick<OptionsComponentProps, 'selectedSymbol' | 'allSymbols' | 'onSelectSymbol' | 'selectedExpiryMs' | 'availableExpiriesMs' | 'onSelectExpiry' | 'summary' | 'oiByExpiry' | 'chainRows' | 'positions' | 'openOrders' | 'tradeHistory' | 'orderHistory'>;
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

  // core data
  const [summary, setSummary] = useState<OptionsSummary>({});
  const [oiByExpiry, setOiByExpiry] = useState<OpenInterestByExpiry[]>([]);
  const [chainRows, setChainRows] = useState<OptionChainRow[]>([]);

  // user
  const [positions, setPositions] = useState<PositionRow[]>([]);
  const [openOrders, setOpenOrders] = useState<UserOrderRow[]>([]);
  const [tradeHistory, setTradeHistory] = useState<TradeFill[]>([]);
  const [orderHistory, setOrderHistory] = useState<OrderHistoryRow[]>([]);

  const onSelectSymbol = (_sym: string) => {};
  const onSelectExpiry = (_ms: number) => {};

  // Internal indexer state
  type SeriesMeta = { key: string; expiryMs: number; strike1e6: number; isCall: boolean; symbol: string; marketId: string };
  type OrderMeta = { orderId: string; key: string; isBid: boolean; price_1e6: number; qtyRemaining: number; maker: string; expireTs: number };

  const seriesByKey = useRef<Map<string, SeriesMeta>>(new Map());
  const expiriesBySymbol = useRef<Map<string, Set<number>>>(new Map());
  const ordersBySeries = useRef<Map<string, Map<string, OrderMeta>>>(new Map());
  const oiBySeries = useRef<Map<string, number>>(new Map());
  const vol24hBySymbol = useRef<Map<string, number>>(new Map());
  const marketIdBySymbol = useRef<Map<string, string>>(new Map());

  const stopRef = useRef<boolean>(false);

  const rebuildChainRows = () => {
    const targetExp = selectedExpiryMs;
    const rows: OptionChainRow[] = [];
    if (!targetExp) return setChainRows([]);
    const strikes = new Map<number, { callKey?: string; putKey?: string }>();
    for (const s of seriesByKey.current.values()) {
      if (s.symbol === selectedSymbol && s.expiryMs === targetExp) {
        const strike = s.strike1e6 / 1_000_000;
        const entry = strikes.get(strike) || {};
        if (s.isCall) entry.callKey = s.key; else entry.putKey = s.key;
        strikes.set(strike, entry);
      }
    }
    const sorted = Array.from(strikes.entries()).sort((a, b) => a[0] - b[0]);
    for (const [strike, ref] of sorted) {
      const callOrders = ref.callKey ? ordersBySeries.current.get(ref.callKey) : undefined;
      const putOrders = ref.putKey ? ordersBySeries.current.get(ref.putKey) : undefined;
      let callBid: number | null = null;
      let callAsk: number | null = null;
      let putBid: number | null = null;
      let putAsk: number | null = null;
      if (callOrders) {
        for (const o of callOrders.values()) {
          if (o.qtyRemaining <= 0) continue;
          const px = o.price_1e6 / 1_000_000;
          if (o.isBid) callBid = callBid === null ? px : Math.max(callBid, px);
          else callAsk = callAsk === null ? px : Math.min(callAsk, px);
        }
      }
      if (putOrders) {
        for (const o of putOrders.values()) {
          if (o.qtyRemaining <= 0) continue;
          const px = o.price_1e6 / 1_000_000;
          if (o.isBid) putBid = putBid === null ? px : Math.max(putBid, px);
          else putAsk = putAsk === null ? px : Math.min(putAsk, px);
        }
      }
      rows.push({ strike, callBid, callAsk, putBid, putAsk });
    }
    setChainRows(rows);
  };

  const rebuildOiByExpiry = () => {
    const expSet = expiriesBySymbol.current.get(selectedSymbol);
    if (!expSet) return setOiByExpiry([]);
    const list: OpenInterestByExpiry[] = [];
    for (const exp of expSet.values()) {
      let oiSum = 0;
      for (const s of seriesByKey.current.values()) {
        if (s.symbol === selectedSymbol && s.expiryMs === exp) {
          oiSum += oiBySeries.current.get(s.key) || 0;
        }
      }
      list.push({ expiryMs: exp, oiUnits: oiSum });
    }
    list.sort((a, b) => a.expiryMs - b.expiryMs);
    setOiByExpiry(list);
  };

  const rebuildAvailableExpiries = () => {
    const set = expiriesBySymbol.current.get(selectedSymbol);
    const values = set ? Array.from(set.values()).sort((a, b) => a - b) : [];
    setAvailableExpiriesMs(values);
  };

  useEffect(() => {
    if (!enabled) {
      setLoading(false);
      return;
    }
    
    stopRef.current = false;
    seriesByKey.current.clear();
    expiriesBySymbol.current.clear();
    ordersBySeries.current.clear();
    oiBySeries.current.clear();
    vol24hBySymbol.current.clear();
    setChainRows([]);
    setOiByExpiry([]);
    setPositions([]);
    setOpenOrders([]);
    setTradeHistory([]);
    setOrderHistory([]);

    const run = async () => {
      if (!pkg) {
        setError('Set pkgUnxversal in Settings');
        setLoading(false);
        return;
      }
      setError(undefined);
      setLoading(true);

      const QUERY = { MoveModule: { package: pkg, module: 'options' } } as const;
      const PAGE_LIMIT = 100;

      const now = Date.now();
      const since = now - 30 * 24 * 3600 * 1000;

      const handleEvent = (ev: any) => {
        const t: string = ev.type;
        const pj: any = ev.parsedJson || {};
        if (t.endsWith('::options::SeriesCreatedV2')) {
          const sym = decodeSymbolBytes(pj.symbol_bytes);
          const key = String(pj.key);
          const expiryMs = Number(pj.expiry_ms);
          const strike1e6 = Number(pj.strike_1e6);
          const isCall = Boolean(pj.is_call);
          const marketId = String(pj.market_id);
          marketIdBySymbol.current.set(sym, marketId);
          seriesByKey.current.set(key, { key, expiryMs, strike1e6, isCall, symbol: sym, marketId });
          const set = expiriesBySymbol.current.get(sym) || new Set<number>();
          set.add(expiryMs);
          expiriesBySymbol.current.set(sym, set);
          if (sym === selectedSymbol) rebuildAvailableExpiries();
        }
        else if (t.endsWith('::options::OrderPlaced')) {
          const key = String(pj.key);
          const orderId = String(pj.order_id);
          const price = Number(pj.price);
          const qty = Number(pj.quantity);
          const isBid = Boolean(pj.is_bid);
          const expireTs = Number(pj.expire_ts);
          const maker = String(pj.maker);
          if (!ordersBySeries.current.has(key)) ordersBySeries.current.set(key, new Map());
          const m = ordersBySeries.current.get(key)!;
          m.set(orderId, { orderId, key, isBid, price_1e6: price, qtyRemaining: qty, maker, expireTs });
        }
        else if (t.endsWith('::options::OrderFilled')) {
          const key = String(pj.key);
          const orderId = String(pj.maker_order_id);
          const price = Number(pj.price);
          const baseQty = Number(pj.base_qty);
          const premium = Number(pj.premium_quote);
          const makerRemaining = Number(pj.maker_remaining_qty);
          const ts = Number(pj.timestamp_ms ?? ev.timestampMs ?? Date.now());
          const maker = String(pj.maker);
          const taker = String(pj.taker);
          const m = ordersBySeries.current.get(key);
          if (m && m.has(orderId)) {
            const o = m.get(orderId)!;
            o.qtyRemaining = makerRemaining;
            m.set(orderId, o);
          }
          const sm = seriesByKey.current.get(key);
          if (sm && sm.symbol === selectedSymbol) {
            setTradeHistory(prev => {
              const next = prev.concat({ maker, taker, priceQuote: price / 1_000_000, baseQty, tsMs: ts });
              return next.slice(-500);
            });
            const prevVol = vol24hBySymbol.current.get(sm.symbol) || 0;
            vol24hBySymbol.current.set(sm.symbol, prevVol + premium);
          }
        }
        else if (t.endsWith('::options::OrderCanceled')) {
          const key = String(pj.key);
          const orderId = String(pj.order_id);
          const m = ordersBySeries.current.get(key);
          if (m) m.delete(orderId);
          setOrderHistory(prev => prev.concat({ kind: 'canceled', orderId, seriesKey: key, tsMs: Number(ev.timestampMs ?? Date.now()) }));
        }
        else if (t.endsWith('::options::OrderExpired')) {
          const key = String(pj.key);
          const orderId = String(pj.order_id);
          const m = ordersBySeries.current.get(key);
          if (m) m.delete(orderId);
          setOrderHistory(prev => prev.concat({ kind: 'expired', orderId, seriesKey: key, tsMs: Number(ev.timestampMs ?? Date.now()) }));
        }
        else if (t.endsWith('::options::OptionPositionUpdated')) {
          const key = String(pj.key);
          const increase = Boolean(pj.increase);
          const delta = Number(pj.delta_units);
          const cur = oiBySeries.current.get(key) || 0;
          oiBySeries.current.set(key, increase ? cur + delta : Math.max(0, cur - delta));
        }
        else if (t.endsWith('::options::SeriesSettled')) {
          // no-op
        }
      };

      const drainWindow = async (startMs: number, endMs: number) => {
        let localCursor: { txDigest: string; eventSeq: string } | null = null;
        while (!stopRef.current) {
          const res = await client.queryEvents({
            query: { Any: [QUERY, { TimeRange: { startTime: String(startMs), endTime: String(endMs) } }] },
            cursor: localCursor,
            limit: PAGE_LIMIT,
            order: 'ascending',
          });
          const events = res.data ?? [];
          if (events.length === 0) break;
          for (const ev of events) handleEvent(ev);
          if (!res.hasNextPage) break;
          localCursor = res.nextCursor ?? null;
        }
      };

      try {
        const WIN = 7 * 24 * 3600 * 1000;
        for (let s = since; s < now; s += WIN) {
          const e = Math.min(s + WIN, now);
          await drainWindow(s, e);
        }
        rebuildAvailableExpiries();
        rebuildOiByExpiry();
        rebuildChainRows();
        const v24 = vol24hBySymbol.current.get(selectedSymbol) || 0;
        setSummary(prev => ({ ...prev, vol24h: v24 }));
      } finally {
        setLoading(false);
      }

      const follow = async () => {
        let c: { txDigest: string; eventSeq: string } | null = null;
        while (!stopRef.current) {
          try {
            const res = await client.queryEvents({ query: QUERY, cursor: c, limit: PAGE_LIMIT, order: 'ascending' });
            const events = res.data ?? [];
            if (events.length > 0) {
              for (const ev of events) handleEvent(ev);
              rebuildAvailableExpiries();
              rebuildOiByExpiry();
              rebuildChainRows();
              const v24 = vol24hBySymbol.current.get(selectedSymbol) || 0;
              setSummary(prev => ({ ...prev, vol24h: v24 }));
              c = res.nextCursor ?? { txDigest: events[events.length - 1].id.txDigest, eventSeq: String(events[events.length - 1].id.eventSeq) };
              continue;
            }
            await new Promise(r => setTimeout(r, 300));
          } catch {
            await new Promise(r => setTimeout(r, 400 + Math.random() * 400));
          }
        }
      };
      void follow();
    };

    void run();
    return () => { stopRef.current = true; };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [client, selectedSymbol, selectedExpiryMs, pkg, enabled]);

  return {
    props: {
      selectedSymbol,
      allSymbols,
      onSelectSymbol,
      selectedExpiryMs,
      availableExpiriesMs,
      onSelectExpiry,
      summary,
      oiByExpiry,
      chainRows,
      positions,
      openOrders,
      tradeHistory,
      orderHistory,
    },
    loading,
    error,
  };
}
