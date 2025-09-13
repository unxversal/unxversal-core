import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { SuiClient } from '@mysten/sui/client';
import { createSuiClient, defaultRpc } from '../../lib/network';
import { db } from '../../lib/storage';
import { startWindowTrackers, type IndexerTracker } from '../../lib/indexer';
import { loadSettings } from '../../lib/settings.config';
import type { Candle } from './types';

type MarketInitializedEvent = {
  market_id: { id: string } | string;
  symbol: string | { bytes: number[] } | { vec: number[] } | any;
  expiry_ms: string | number;
  contract_size: string | number;
  initial_margin_bps: string | number;
  maintenance_margin_bps: string | number;
};

type OrderPlacedEvent = {
  market_id: { id: string } | string;
  order_id: string | number;
  maker: string;
  is_bid: boolean;
  price_1e6: string | number;
  quantity: string | number;
  expire_ts: string | number;
};

type OrderFilledEvent = {
  market_id: { id: string } | string;
  maker_order_id: string | number;
  maker: string;
  taker: string;
  price_1e6: string | number;
  base_qty: string | number;
  timestamp_ms: string | number;
};

type OrderCanceledEvent = {
  market_id: { id: string } | string;
  order_id: string | number;
  maker: string;
  remaining_qty: string | number;
  timestamp_ms: string | number;
};

export type FuturesMarketMeta = {
  id: string;            // market object id (per expiry)
  symbol: string;        // e.g. "SUI/USDC"
  expiryMs: number;
  contractSize: number;
  initialMarginBps: number;
  maintenanceMarginBps: number;
};

type OrderbookMap = { [marketId: string]: { bids: [number, number][], asks: [number, number][] } };
type TradesMap = { [marketId: string]: { ts: number; price: number; qty: number }[] };
type CandlesBySymbolMap = { [symbol: string]: Candle[] };
type OIMap = { [marketId: string]: { longQty: number; shortQty: number } };
type LastPriceMap = { [marketId: string]: number };

export type UseFuturesData = {
  client: SuiClient;
  markets: FuturesMarketMeta[]; // each entry corresponds to a specific expiry market
  candlesBySymbol: CandlesBySymbolMap;
  tradesByMarket: TradesMap; // marketId -> fills
  orderbookByMarket: OrderbookMap;
  oiByMarket: OIMap;
  lastPriceByMarket: LastPriceMap;
  refresh: () => Promise<void>;
  loading: boolean;
};

function asNum(x: any): number { try { return Number(x ?? 0); } catch { return 0; } }
function btoi(b: any): string {
  try {
    if (!b) return '';
    if (typeof b === 'string') return b;
    const arr: number[] = b.bytes || b.vec || b;
    if (Array.isArray(arr)) return String.fromCharCode(...arr);
    return '';
  } catch { return ''; }
}
function idOf(v: any): string { return typeof v === 'string' ? v : (v?.id || ''); }

export function useFuturesData(): UseFuturesData {
  const settings = loadSettings();
  const pkg = settings.contracts.pkgUnxversal;
  const [client] = useState<SuiClient>(() => createSuiClient(defaultRpc(settings.network)));
  const [markets, setMarkets] = useState<FuturesMarketMeta[]>([]);
  const [lastPriceByMarket, setLastPriceByMarket] = useState<LastPriceMap>({});
  const [oiByMarket, setOiByMarket] = useState<OIMap>({});
  const [orderbookByMarket, setOrderbookByMarket] = useState<OrderbookMap>({});
  const [tradesByMarket, setTradesByMarket] = useState<TradesMap>({});
  const [candlesBySymbol, setCandlesBySymbol] = useState<CandlesBySymbolMap>({});
  const [loading, setLoading] = useState(false);
  const startedRef = useRef(false);

  useEffect(() => {
    if (!pkg || startedRef.current) return;
    startedRef.current = true;
    const tracker: IndexerTracker = { id: 'futures-module', filter: { MoveModule: { package: pkg, module: 'futures' } } };
    void startWindowTrackers(client, [tracker]);
  }, [client, pkg]);

  const decodeMarkets = useCallback(async (): Promise<FuturesMarketMeta[]> => {
    const t = `${pkg}::futures::MarketInitialized`;
    const rows = await db.events.where('type').equals(t).toArray();
    const out: FuturesMarketMeta[] = [];
    const seen = new Set<string>();
    for (const r of rows) {
      const pj = r.parsedJson as any as MarketInitializedEvent;
      const marketId = idOf((pj as any).market_id);
      if (!marketId || seen.has(marketId)) continue;
      seen.add(marketId);
      const expiryMs = asNum((pj as any).expiry_ms);
      const symbol = typeof (pj as any).symbol === 'string' ? (pj as any).symbol : btoi((pj as any).symbol);
      const contractSize = asNum((pj as any).contract_size);
      const initialMarginBps = asNum((pj as any).initial_margin_bps);
      const maintenanceMarginBps = asNum((pj as any).maintenance_margin_bps);
      out.push({ id: marketId, symbol, expiryMs, contractSize, initialMarginBps, maintenanceMarginBps });
    }
    // Sort by symbol, then expiry asc
    out.sort((a, b) => a.symbol === b.symbol ? (a.expiryMs - b.expiryMs) : a.symbol.localeCompare(b.symbol));
    return out;
  }, [pkg]);

  const buildTrades = useCallback(async (): Promise<TradesMap> => {
    const rows = await db.events.where('type').equals(`${pkg}::futures::OrderFilled`).toArray();
    const out: TradesMap = {};
    for (const r of rows) {
      const pj = r.parsedJson as any as OrderFilledEvent;
      const marketId = idOf((pj as any).market_id);
      (out[marketId] ||= []).push({ ts: asNum((pj as any).timestamp_ms) || (r.tsMs ?? Date.now()), price: asNum((pj as any).price_1e6) / 1_000_000, qty: asNum((pj as any).base_qty) });
    }
    for (const k of Object.keys(out)) out[k].sort((a, b) => a.ts - b.ts);
    return out;
  }, [pkg]);

  const buildOrderbook = useCallback(async (): Promise<OrderbookMap> => {
    const placed = await db.events.where('type').equals(`${pkg}::futures::OrderPlaced`).toArray();
    const canceled = await db.events.where('type').equals(`${pkg}::futures::OrderCanceled`).toArray();
    const filled = await db.events.where('type').equals(`${pkg}::futures::OrderFilled`).toArray();
    const canceledIds = new Set<string>(canceled.map(r => String((r.parsedJson as any)?.order_id)));
    const fillsByOrder = new Map<string, number>();
    for (const fr of filled) {
      const pj = fr.parsedJson as any as OrderFilledEvent;
      const id = String((pj as any).maker_order_id);
      fillsByOrder.set(id, (fillsByOrder.get(id) || 0) + asNum((pj as any).base_qty));
    }
    type LiveOrder = { marketId: string; id: string; price: number; qty: number; isBid: boolean };
    const live: LiveOrder[] = [];
    for (const pr of placed) {
      const pj = pr.parsedJson as any as OrderPlacedEvent;
      const id = String((pj as any).order_id);
      if (canceledIds.has(id)) continue;
      const rem = Math.max(0, asNum((pj as any).quantity) - (fillsByOrder.get(id) || 0));
      if (rem <= 0) continue;
      const price = asNum((pj as any).price_1e6) / 1_000_000;
      const isBid = Boolean((pj as any).is_bid);
      const marketId = idOf((pj as any).market_id);
      live.push({ marketId, id, price, qty: rem, isBid });
    }
    const out: OrderbookMap = {};
    for (const lo of live) {
      const book = (out[lo.marketId] ||= { bids: [], asks: [] });
      if (lo.isBid) book.bids.push([lo.price, lo.qty]); else book.asks.push([lo.price, lo.qty]);
    }
    // aggregate by price level and sort
    for (const k of Object.keys(out)) {
      const aggObj: { [priceKey: string]: [number, number] } = {};
      for (const [p, q] of out[k].bids) {
        const key = p.toFixed(6);
        if (aggObj[key]) aggObj[key][1] += q; else aggObj[key] = [p, q];
      }
      const bids = Object.values(aggObj).sort((a, b) => b[0] - a[0]).slice(0, 50);
      const aggObjAsk: { [priceKey: string]: [number, number] } = {};
      for (const [p, q] of out[k].asks) {
        const key = p.toFixed(6);
        if (aggObjAsk[key]) aggObjAsk[key][1] += q; else aggObjAsk[key] = [p, q];
      }
      const asks = Object.values(aggObjAsk).sort((a, b) => a[0] - b[0]).slice(0, 50);
      out[k] = { bids, asks };
    }
    return out;
  }, [pkg]);

  const buildCandlesBySymbol = useCallback(async (mkts: FuturesMarketMeta[]): Promise<CandlesBySymbolMap> => {
    const trades = await buildTrades();
    const out: CandlesBySymbolMap = {};
    const byMarket = new Map<string, FuturesMarketMeta>();
    for (const m of mkts) byMarket.set(m.id, m);
    const bySymbol = new Map<string, { ts: number; price: number; qty: number }[]>();
    for (const [mid, arr] of Object.entries(trades)) {
      const meta = byMarket.get(mid);
      if (!meta) continue;
      const existing = bySymbol.get(meta.symbol);
      if (existing) existing.push(...arr);
      else bySymbol.set(meta.symbol, [...arr]);
    }
    for (const [sym, arr] of bySymbol.entries()) {
      const bucketed = new Map<number, { o: number; h: number; l: number; c: number; v: number }>();
      for (const t of arr) {
        const bucket = Math.floor(t.ts / 60) * 60; // minute buckets (seconds)
        const b = bucketed.get(bucket) || { o: t.price, h: t.price, l: t.price, c: t.price, v: 0 };
        b.h = Math.max(b.h, t.price); b.l = Math.min(b.l, t.price); b.c = t.price; b.v += t.qty;
        bucketed.set(bucket, b);
      }
      const candles: Candle[] = Array.from(bucketed.entries()).sort((a, b) => a[0] - b[0]).map(([time, v]) => ({ time, open: v.o, high: v.h, low: v.l, close: v.c, volume: v.v }));
      out[sym] = candles;
    }
    return out;
  }, [buildTrades]);

  const buildLastPriceAndOI = useCallback(async (mkts: FuturesMarketMeta[]) => {
    const last: Record<string, number> = {};
    const oi: Record<string, { longQty: number; shortQty: number }> = {};
    for (const m of mkts) {
      try {
        const obj = await client.getObject({ id: m.id, options: { showContent: true } });
        const fields: any = (obj as any)?.data?.content?.fields || {};
        const lp = asNum(fields.last_price_1e6) / 1_000_000;
        last[m.id] = lp || 0;
        oi[m.id] = { longQty: asNum(fields.total_long_qty), shortQty: asNum(fields.total_short_qty) };
      } catch {}
    }
    setLastPriceByMarket(last);
    setOiByMarket(oi);
  }, [client]);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const mkts = await decodeMarkets();
      setMarkets(mkts);
      const [book, trades] = await Promise.all([
        buildOrderbook(),
        buildTrades(),
      ]);
      setOrderbookByMarket(book);
      setTradesByMarket(trades);
      setCandlesBySymbol(await buildCandlesBySymbol(mkts));
      await buildLastPriceAndOI(mkts);
    } finally {
      setLoading(false);
    }
  }, [decodeMarkets, buildOrderbook, buildTrades, buildCandlesBySymbol, buildLastPriceAndOI]);

  useEffect(() => {
    void refresh();
    const id = setInterval(() => void refresh(), 1500);
    return () => clearInterval(id);
  }, [refresh]);

  return useMemo<UseFuturesData>(() => ({ client, markets, candlesBySymbol, tradesByMarket, orderbookByMarket, oiByMarket, lastPriceByMarket, refresh, loading }), [client, markets, candlesBySymbol, tradesByMarket, orderbookByMarket, oiByMarket, lastPriceByMarket, refresh, loading]);
}


