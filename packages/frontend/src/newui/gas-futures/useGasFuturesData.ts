import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { SuiClient } from '@mysten/sui/client';
import { createSuiClient, defaultRpc } from '../../lib/network';
import { db } from '../../lib/storage';
import { startWindowTrackers, type IndexerTracker } from '../../lib/indexer';
import { loadSettings } from '../../lib/settings.config';
import type { Candle } from './types';

type MarketInitializedEvent = { market_id: { id: string } | string; expiry_ms: string | number; contract_size: string | number; initial_margin_bps: string | number; maintenance_margin_bps: string | number };
type OrderPlacedEvent = { market_id: { id: string } | string; order_id: string | number; maker: string; is_bid: boolean; price_1e6: string | number; quantity: string | number; expire_ts: string | number };
type OrderFilledEvent = { market_id: { id: string } | string; maker_order_id: string | number; maker: string; taker: string; price_1e6: string | number; base_qty: string | number; timestamp_ms: string | number };
type OrderCanceledEvent = { market_id: { id: string } | string; order_id: string | number; maker: string; remaining_qty: string | number; timestamp_ms: string | number };

export type GasFuturesMarketMeta = { id: string; expiryMs: number; contractSize: number; initialMarginBps: number; maintenanceMarginBps: number };

export type UseGasFuturesData = {
  client: SuiClient;
  markets: GasFuturesMarketMeta[]; // each entry = specific expiry
  candles: Candle[];
  orderbook: { bids: [number, number][]; asks: [number, number][] };
  trades: { ts: number; price: number; qty: number }[];
  lastPrice?: number;
  oi?: { longQty: number; shortQty: number };
  refresh: () => Promise<void>;
  loading: boolean;
};

function asNum(x: any): number { try { return Number(x ?? 0); } catch { return 0; } }
function idOf(v: any): string { return typeof v === 'string' ? v : (v?.id || ''); }

export function useGasFuturesData(): UseGasFuturesData {
  const settings = loadSettings();
  const pkg = settings.contracts.pkgUnxversal;
  const [client] = useState<SuiClient>(() => createSuiClient(defaultRpc(settings.network)));
  const [markets, setMarkets] = useState<GasFuturesMarketMeta[]>([]);
  const [candles, setCandles] = useState<Candle[]>([]);
  const [orderbook, setOrderbook] = useState<{ bids: [number, number][], asks: [number, number][] }>({ bids: [], asks: [] });
  const [trades, setTrades] = useState<{ ts: number; price: number; qty: number }[]>([]);
  const [lastPrice, setLastPrice] = useState<number | undefined>(undefined);
  const [oi, setOi] = useState<{ longQty: number; shortQty: number } | undefined>(undefined);
  const [loading, setLoading] = useState(false);
  const startedRef = useRef(false);

  useEffect(() => {
    if (!pkg || startedRef.current) return;
    startedRef.current = true;
    const tracker: IndexerTracker = { id: 'gas-futures-module', filter: { MoveModule: { package: pkg, module: 'gas_futures' } } };
    void startWindowTrackers(client, [tracker]);
  }, [client, pkg]);

  const decodeMarkets = useCallback(async (): Promise<GasFuturesMarketMeta[]> => {
    const t = `${pkg}::gas_futures::MarketInitialized`;
    const rows = await db.events.where('type').equals(t).toArray();
    const out: GasFuturesMarketMeta[] = [];
    const seen = new Set<string>();
    for (const r of rows) {
      const pj = r.parsedJson as any as MarketInitializedEvent;
      const id = idOf((pj as any).market_id);
      if (!id || seen.has(id)) continue; seen.add(id);
      out.push({ id, expiryMs: asNum((pj as any).expiry_ms), contractSize: asNum((pj as any).contract_size), initialMarginBps: asNum((pj as any).initial_margin_bps), maintenanceMarginBps: asNum((pj as any).maintenance_margin_bps) });
    }
    out.sort((a, b) => a.expiryMs - b.expiryMs);
    return out;
  }, [pkg]);

  const buildTrades = useCallback(async (): Promise<{ ts: number; price: number; qty: number }[]> => {
    const rows = await db.events.where('type').equals(`${pkg}::gas_futures::OrderFilled`).toArray();
    const out: { ts: number; price: number; qty: number }[] = [];
    for (const r of rows) {
      const pj = r.parsedJson as any as OrderFilledEvent;
      out.push({ ts: asNum((pj as any).timestamp_ms) || (r.tsMs ?? Date.now()), price: asNum((pj as any).price_1e6) / 1_000_000, qty: asNum((pj as any).base_qty) });
    }
    out.sort((a, b) => a.ts - b.ts);
    return out;
  }, [pkg]);

  const buildOrderbook = useCallback(async (): Promise<{ bids: [number, number][], asks: [number, number][] }> => {
    const placed = await db.events.where('type').equals(`${pkg}::gas_futures::OrderPlaced`).toArray();
    const canceled = await db.events.where('type').equals(`${pkg}::gas_futures::OrderCanceled`).toArray();
    const filled = await db.events.where('type').equals(`${pkg}::gas_futures::OrderFilled`).toArray();
    const canceledIds = new Set<string>(canceled.map(r => String((r.parsedJson as any)?.order_id)));
    const fillsByOrder = new Map<string, number>();
    for (const fr of filled) {
      const pj = fr.parsedJson as any as OrderFilledEvent;
      const id = String((pj as any).maker_order_id);
      fillsByOrder.set(id, (fillsByOrder.get(id) || 0) + asNum((pj as any).base_qty));
    }
    type LiveOrder = { price: number; qty: number; isBid: boolean };
    const live: LiveOrder[] = [];
    for (const pr of placed) {
      const pj = pr.parsedJson as any as OrderPlacedEvent;
      const id = String((pj as any).order_id);
      if (canceledIds.has(id)) continue;
      const rem = Math.max(0, asNum((pj as any).quantity) - (fillsByOrder.get(id) || 0));
      if (rem <= 0) continue;
      live.push({ price: asNum((pj as any).price_1e6) / 1_000_000, qty: rem, isBid: Boolean((pj as any).is_bid) });
    }
    const agg = (rows: [number, number][]) => Object.values(rows.reduce((m, [p, q]) => { const key = p.toFixed(6); (m[key] ||= [p, 0])[1] += q; return m; }, {} as Record<string, [number, number]>));
    const bids = agg(live.filter(l => l.isBid).map(l => [l.price, l.qty] as [number, number])).sort((a, b) => b[0] - a[0]).slice(0, 50);
    const asks = agg(live.filter(l => !l.isBid).map(l => [l.price, l.qty] as [number, number])).sort((a, b) => a[0] - b[0]).slice(0, 50);
    return { bids, asks };
  }, [pkg]);

  const buildCandles = useCallback(async (): Promise<Candle[]> => {
    const trades = await buildTrades();
    const bucketed = new Map<number, { o: number; h: number; l: number; c: number; v: number }>();
    for (const t of trades) {
      const bucket = Math.floor(t.ts / 60) * 60; // second-based buckets
      const b = bucketed.get(bucket) || { o: t.price, h: t.price, l: t.price, c: t.price, v: 0 };
      b.h = Math.max(b.h, t.price); b.l = Math.min(b.l, t.price); b.c = t.price; b.v += t.qty;
      bucketed.set(bucket, b);
    }
    return Array.from(bucketed.entries()).sort((a, b) => a[0] - b[0]).map(([time, v]) => ({ time, open: v.o, high: v.h, low: v.l, close: v.c, volume: v.v }));
  }, [buildTrades]);

  const buildLastAndOI = useCallback(async (mkts: GasFuturesMarketMeta[]) => {
    try {
      // Use front expiry market for last price and OI
      const front = mkts.sort((a, b) => a.expiryMs - b.expiryMs)[0];
      if (!front) return;
      const obj = await client.getObject({ id: front.id, options: { showContent: true } });
      const fields: any = (obj as any)?.data?.content?.fields || {};
      setLastPrice(asNum(fields.last_price_1e6) / 1_000_000 || undefined);
      setOi({ longQty: asNum(fields.total_long_qty), shortQty: asNum(fields.total_short_qty) });
    } catch {}
  }, [client]);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const mkts = await decodeMarkets();
      setMarkets(mkts);
      setOrderbook(await buildOrderbook());
      setTrades(await buildTrades());
      setCandles(await buildCandles());
      await buildLastAndOI(mkts);
    } finally {
      setLoading(false);
    }
  }, [decodeMarkets, buildOrderbook, buildTrades, buildCandles, buildLastAndOI]);

  useEffect(() => {
    void refresh();
    const id = setInterval(() => void refresh(), 1500);
    return () => clearInterval(id);
  }, [refresh]);

  return useMemo<UseGasFuturesData>(() => ({ client, markets, candles, orderbook, trades, lastPrice, oi, refresh, loading }), [client, markets, candles, orderbook, trades, lastPrice, oi, refresh, loading]);
}


