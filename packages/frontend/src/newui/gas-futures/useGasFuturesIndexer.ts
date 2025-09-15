import { useEffect, useRef, useState } from 'react';
import type { SuiClient } from '@mysten/sui/client';
import { toast } from 'sonner';
import { loadSettings } from '../../lib/settings.config';

export type UseGasFuturesIndexerArgs = {
  client: SuiClient;
  selectedSymbol: string;
  selectedExpiryMs: number | null;
  address?: string | null;
  enabled?: boolean;
};

export function useGasFuturesIndexer({ client, selectedSymbol, selectedExpiryMs, address, enabled = true }: UseGasFuturesIndexerArgs): {
  props: {
    selectedSymbol: string;
    allSymbols?: string[];
    onSelectSymbol?: (s: string) => void;
    selectedExpiryMs: number | null;
    availableExpiriesMs: number[];
    onSelectExpiry?: (ms: number) => void;
    marketId: string;
    summary: { last?: number; openInterest?: number; vol24h?: number; change24h?: number; twap5m?: number; expiryMs?: number | null };
    orderBook: { bids: { price: number; qty: number }[]; asks: { price: number; qty: number }[] };
    recentTrades: { priceQuote: number; baseQty: number; tsMs: number }[];
    openOrders: { orderId: string; isBid: boolean; qtyRemaining: number; priceQuote: number; status?: string }[];
  } & { getOhlc?: (tf: '1m'|'5m'|'15m'|'1h'|'1d'|'7d') => { candles: { time: number; open: number; high: number; low: number; close: number }[]; volumes?: { time: number; value: number }[] } };
  loading: boolean;
  error?: string;
} {
  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | undefined>();
  const settings = loadSettings();
  const [availableExpiriesMs, setAvailableExpiriesMs] = useState<number[]>([]);
  const [marketId, setMarketId] = useState<string>('');
  const [summary, setSummary] = useState<{ last?: number; openInterest?: number; vol24h?: number; change24h?: number; twap5m?: number; expiryMs?: number | null }>({});
  const [orderBook, setOrderBook] = useState<{ bids: { price: number; qty: number }[]; asks: { price: number; qty: number }[] }>({ bids: [], asks: [] });
  const [recentTrades, setRecentTrades] = useState<{ priceQuote: number; baseQty: number; tsMs: number }[]>([]);
  const [openOrders, setOpenOrders] = useState<{ orderId: string; isBid: boolean; qtyRemaining: number; priceQuote: number; status?: string }[]>([]);

  // RGP samples (price1e6 as per on-chain convention), store last 24h
  const rgpSamplesRef = useRef<Array<{ t: number; p1e6: number }>>([]);

  useEffect(() => {
    if (!enabled) { setLoading(false); return; }
    let stopped = false;
    setAvailableExpiriesMs([]);
    setOrderBook({ bids: [], asks: [] });
    setRecentTrades([]);
    setOpenOrders([]);
    setSummary({});

    const run = async () => {
      setError(undefined); setLoading(true);
      const pkg = settings.contracts.pkgUnxversal || settings.contracts.pkgDeepbook;
      if (!pkg) { setError('Set packages in Settings'); setLoading(false); return; }
      const QUERY = { MoveModule: { package: pkg, module: 'gas_futures' } } as const;

      const handleEvent = (ev: any) => {
        const t: string = ev.type;
        const pj: any = ev.parsedJson || {};
        if (t.endsWith('::gas_futures::MarketInitialized')) {
          const sym = String(pj.symbol ?? selectedSymbol);
          const expiryMs = Number(pj.expiry_ms ?? 0) || null;
          const mId = String(pj.market_id?.id ?? pj.market_id ?? '');
          if (sym === selectedSymbol && mId) {
            setMarketId(mId);
            if (expiryMs) setAvailableExpiriesMs((prev) => Array.from(new Set(prev.concat(expiryMs))).sort((a,b)=>a-b));
          }
        } else if (t.endsWith('::gas_futures::OrderPlaced')) {
          const mId = String(pj.market_id?.id ?? pj.market_id ?? marketId);
          if (mId !== marketId) return;
          const rec = {
            orderId: String(pj.order_id),
            isBid: Boolean(pj.is_bid),
            qtyRemaining: Number(pj.quantity ?? 0),
            priceQuote: Number(pj.price_1e6 ?? pj.price ?? 0) / 1_000_000,
            status: 'Open',
          };
          setOpenOrders((prev) => [rec, ...prev.filter(o => o.orderId !== rec.orderId)].slice(0, 200));
        } else if (t.endsWith('::gas_futures::OrderFilled')) {
          const mId = String(pj.market_id?.id ?? pj.market_id ?? marketId);
          if (mId !== marketId) return;
          const ts = Number(pj.timestamp_ms ?? ev.timestampMs ?? Date.now());
          const price = Number(pj.price_1e6 ?? pj.price ?? 0) / 1_000_000;
          const qty = Number(pj.base_qty ?? 0);
          setRecentTrades((prev) => prev.concat({ priceQuote: price, baseQty: qty, tsMs: ts }).slice(-200));
          const id = String(pj.maker_order_id ?? pj.order_id ?? '');
          if (id) setOpenOrders((prev) => prev.map(o => o.orderId === id ? { ...o, qtyRemaining: Math.max(0, o.qtyRemaining - qty) } : o));
        } else if (t.endsWith('::gas_futures::OrderCanceled')) {
          const id = String(pj.order_id);
          setOpenOrders((prev) => prev.filter(o => o.orderId !== id));
        }
      };

      const follow = async () => {
        let c: { txDigest: string; eventSeq: string } | null = null;
        while (!stopped) {
          try {
            const res = await client.queryEvents({ query: QUERY, cursor: c, limit: 100, order: 'ascending' });
            const evs = res.data ?? [];
            if (evs.length) {
              for (const ev of evs) handleEvent(ev);
              c = res.nextCursor ?? { txDigest: evs[evs.length - 1].id.txDigest, eventSeq: String(evs[evs.length - 1].id.eventSeq) };
              continue;
            }
            await new Promise(r => setTimeout(r, 300));
          } catch { await new Promise(r => setTimeout(r, 500)); }
        }
      };

      void follow();

      // Poll market object and RGP
      const poll = async () => {
        try {
          const nowMs = Date.now();
          // RGP in MIST units; treat as 1e6-scaled per on-chain convention
          const rgp = Number(await client.getReferenceGasPrice());
          const p1e6 = rgp; // already treated as 1e6-scaled units
          rgpSamplesRef.current.push({ t: Math.floor(nowMs/1000), p1e6 });
          // keep last 24h
          const cutoffSec = Math.floor((nowMs - 24*3600*1000)/1000);
          if (rgpSamplesRef.current.length > 0) {
            const i = rgpSamplesRef.current.findIndex(s => s.t >= cutoffSec);
            if (i > 0) rgpSamplesRef.current.splice(0, i);
          }
          const last = p1e6 / 1_000_000;
          // compute 24h stats from rgp samples
          const samples24 = rgpSamplesRef.current;
          const vol24h = samples24.length; // no volume notion; use count
          const price24 = samples24.length ? samples24[0].p1e6 / 1_000_000 : last;
          const change24h = last != null && price24 != null && price24 > 0 ? ((last - price24) / price24) * 100 : undefined;
          setSummary((prev) => ({ ...prev, last, vol24h, change24h }));
        } catch {}
        if (marketId) {
          try {
            const res = await client.getObject({ id: marketId, options: { showContent: true } });
            const f: any = (res.data as any)?.content?.fields;
            if (f) {
              const totalLong = Number(f.total_long_qty ?? 0);
              const totalShort = Number(f.total_short_qty ?? 0);
              setSummary((prev) => ({ ...prev, openInterest: totalLong + totalShort, expiryMs: f.series?.fields?.expiry_ms ?? null }));
            }
          } catch {}
        }
      };
      const id = setInterval(poll, 1000);
      await poll();
      setLoading(false);
      return () => { clearInterval(id); };
    };

    void run();
    return () => { stopped = true; };
  }, [client, selectedSymbol, selectedExpiryMs, address, enabled, settings.contracts.pkgUnxversal, settings.contracts.pkgDeepbook, marketId]);

  useEffect(() => { if (error) toast.error(error, { position: 'top-center', id: 'gas-indexer-error' }); }, [error]);

  const getOhlc = (tf: '1m'|'5m'|'15m'|'1h'|'1d'|'7d') => {
    const step = tf === '1m' ? 60 : tf === '5m' ? 300 : tf === '15m' ? 900 : tf === '1h' ? 3600 : tf === '1d' ? 86400 : 604800;
    const samples = rgpSamplesRef.current;
    if (samples.length === 0) return { candles: [] };
    const start = samples[0].t;
    const end = samples[samples.length - 1].t;
    const buckets: Record<number, { o: number; h: number; l: number; c: number } & { t: number }> = {};
    for (const s of samples) {
      const b = Math.floor(s.t / step) * step;
      const px = s.p1e6 / 1_000_000;
      if (!buckets[b]) buckets[b] = { t: b, o: px, h: px, l: px, c: px };
      const bk = buckets[b];
      if (px > bk.h) bk.h = px;
      if (px < bk.l) bk.l = px;
      bk.c = px;
    }
    const keys = Object.keys(buckets).map(k => Number(k)).sort((a,b)=>a-b);
    const candles = keys.map(k => ({ time: buckets[k].t, open: buckets[k].o, high: buckets[k].h, low: buckets[k].l, close: buckets[k].c }));
    return { candles };
  };

  return { props: { selectedSymbol, selectedExpiryMs, availableExpiriesMs, marketId, summary, orderBook, recentTrades, openOrders, getOhlc }, loading, error };
}


