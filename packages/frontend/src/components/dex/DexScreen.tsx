import { useEffect, useMemo, useRef, useState } from 'react';
import styles from './DexScreen.module.css';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';
import { createChart, type IChartApi, type CandlestickData, type UTCTimestamp, CandlestickSeries } from 'lightweight-charts';
import { Orderbook } from './Orderbook';
import { Trades } from './Trades';
import { TradePanel } from './TradePanel';
import { loadSettings } from '../../lib/settings.config';

export function DexScreen() {
  const s = loadSettings();
  const deepbookIndexerUrl = s.dex.deepbookIndexerUrl;
  const pool = s.dex.poolId;
  const db = useMemo(() => buildDeepbookPublicIndexer(deepbookIndexerUrl), [deepbookIndexerUrl]);

  const [summary, setSummary] = useState<{ last?: number; vol24h?: number; high24h?: number; low24h?: number }>({});
  const [mid, setMid] = useState<number>(0);
  const chartRef = useRef<HTMLDivElement | null>(null);
  const chartApi = useRef<IChartApi | null>(null);

  useEffect(() => {
    let mounted = true;
    const load = async () => {
      try {
        const tick = await db.ticker();
        const m = Object.values(tick)[0] as any;
        if (!mounted) return;
        setSummary({ last: m?.last_price, vol24h: m?.quote_volume, high24h: undefined, low24h: undefined });
      } catch {}
    };
    void load();
    const id = setInterval(load, 3000);
    return () => { mounted = false; clearInterval(id); };
  }, [db]);

  useEffect(() => {
    let disposed = false;
    if (!chartRef.current) return;
    const chart = createChart(chartRef.current, {
      layout: { background: { color: '#0a0c12' }, textColor: '#e5e7eb' },
      rightPriceScale: { borderColor: '#1b1e27' },
      timeScale: { borderColor: '#1b1e27' },
      grid: { horzLines: { color: '#12141a' }, vertLines: { color: '#12141a' } },
    });
    const series = chart.addSeries(CandlestickSeries, {
      upColor: '#10b981', downColor: '#ef4444', borderVisible: false, wickUpColor: '#10b981', wickDownColor: '#ef4444',
    });
    chartApi.current = chart;
    (async () => {
      try {
        const trades = await db.trades(pool, { limit: 200 });
        // Convert trades to OHLC with 1m bucket (simple agg for demo)
        const bucket = new Map<number, { o: number; h: number; l: number; c: number }>();
        for (const t of trades) {
          const minute = (Math.floor(t.ts / 60) * 60) as UTCTimestamp;
          const b = bucket.get(minute) ?? { o: t.price, h: t.price, l: t.price, c: t.price };
          b.h = Math.max(b.h, t.price); b.l = Math.min(b.l, t.price); b.c = t.price; bucket.set(minute, b);
        }
        const data: CandlestickData<UTCTimestamp>[] = Array.from(bucket.entries()).sort((a,b)=>a[0]-b[0]).map(([time, v]) => ({ time: time as UTCTimestamp, open: v.o, high: v.h, low: v.l, close: v.c }));
        series.setData(data);
        chart.timeScale().fitContent();
      } catch {}
    })();
    const resize = () => {
      if (!chartRef.current) return;
      const rect = chartRef.current.getBoundingClientRect();
      chart.applyOptions({ width: rect.width, height: rect.height });
    };
    resize();
    window.addEventListener('resize', resize);
    return () => { if (!disposed) { chart.remove(); } disposed = true; window.removeEventListener('resize', resize); };
  }, [db, pool]);

  return (
    <div className={styles.root}>
      <div className={styles.topbar}>
        <div className={styles.pair}>DEX / {pool}</div>
        <div className={styles.metrics}>
          <span>Last: {summary.last ?? '-'}</span>
          <span>24h Vol: {summary.vol24h ?? '-'}</span>
        </div>
      </div>
      <div className={styles.middle}>
        <div className={styles.left}>
          <div ref={chartRef} className={styles.chart} />
        </div>
        <div className={styles.center}>
          <Orderbook pool={pool} indexer={db} onMidChange={setMid} />
          <Trades pool={pool} indexer={db} />
        </div>
        <div className={styles.right}>
          <TradePanel pool={pool} mid={mid} />
        </div>
      </div>
      <div className={styles.bottomTabs}>
        <button className={styles.active}>Open Orders</button>
        <button>Order History</button>
        <button>Trade History</button>
        <button>Points</button>
      </div>
      <div className={styles.bottomBody}>
        <div className={styles.placeholder}>No open orders yet.</div>
      </div>
    </div>
  );
}



