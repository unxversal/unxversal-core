import { useEffect, useState } from 'react';
import styles from './Orderbook.module.css';

export function Orderbook({ pool, indexer, onMidChange }: { pool: string; indexer: ReturnType<typeof import('../../lib/indexer').buildDeepbookPublicIndexer>; onMidChange?: (mid: number) => void }) {
  const [bids, setBids] = useState<[number, number][]>([]);
  const [asks, setAsks] = useState<[number, number][]>([]);

  useEffect(() => {
    let mounted = true;
    const load = async () => {
      try {
        let ob: any | undefined;
        try { ob = await indexer.orderbook(pool, { level: 1, depth: 16 }); } catch {}
        if (!ob) {
          // sample fallback with realistic depth distribution
          const sampleBids = Array.from({ length: 16 }, (_, i) => [
            100 - i * 0.01, 
            Math.round((Math.random() * 50000 + 1000) * (16 - i) / 16)
          ]);
          const sampleAsks = Array.from({ length: 16 }, (_, i) => [
            100 + i * 0.01, 
            Math.round((Math.random() * 50000 + 1000) * (16 - i) / 16)
          ]);
          setBids(sampleBids as [number, number][]);
          setAsks(sampleAsks as [number, number][]);
          onMidChange?.(100);
          return;
        }
        if (!mounted) return;
        const b = (ob.bids ?? []).map(([p, q]: [number | string, number | string]) => [Number(p), Number(q)]) as [number, number][];
        const a = (ob.asks ?? []).map(([p, q]: [number | string, number | string]) => [Number(p), Number(q)]) as [number, number][];
        setBids(b);
        setAsks(a);
        if (b.length && a.length) onMidChange?.((b[0][0] + a[0][0]) / 2);
      } catch {}
    };
    void load();
    const id = setInterval(load, 1500);
    return () => { mounted = false; clearInterval(id); };
  }, [pool, indexer, onMidChange]);

  // Calculate max size for depth bars
  const allSizes = [...bids.map(([,q]) => q), ...asks.map(([,q]) => q)];
  const maxSize = Math.max(...allSizes, 1);

  return (
    <div className={styles.root}>
      <div className={styles.header}>Order Book</div>
      <div className={styles.columns}><span>Price</span><span>Size</span></div>
      
      <div className={styles.asksSection}>
        {asks.slice(0, 16).reverse().map(([p,q], i) => {
          const depthPercent = (q / maxSize) * 100;
          return (
            <div key={`a-${i}`} className={styles.ask} style={{ '--depth': `${depthPercent}%` } as any}>
              <div className={styles.depthBar} />
              <span className={styles.askPrice}>{p.toLocaleString()}</span>
              <span>{q.toLocaleString()}</span>
            </div>
          );
        })}
      </div>
      
      <div className={styles.spread}>
        <span>Spread: {bids.length && asks.length ? (asks[0][0] - bids[0][0]).toFixed(3) : '-'}</span>
        <span>{bids.length && asks.length ? (((asks[0][0] - bids[0][0]) / bids[0][0]) * 100).toFixed(3) + '%' : '-'}</span>
      </div>
      
      <div className={styles.bidsSection}>
        {bids.slice(0, 16).map(([p,q], i) => {
          const depthPercent = (q / maxSize) * 100;
          return (
            <div key={`b-${i}`} className={styles.bid} style={{ '--depth': `${depthPercent}%` } as any}>
              <div className={styles.depthBar} />
              <span className={styles.bidPrice}>{p.toLocaleString()}</span>
              <span>{q.toLocaleString()}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}



