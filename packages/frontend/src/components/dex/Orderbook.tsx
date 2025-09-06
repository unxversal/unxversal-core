import { useEffect, useState } from 'react';
import styles from './Orderbook.module.css';

export function Orderbook({ pool, indexer, onMidChange }: { pool: string; indexer: ReturnType<typeof import('../../lib/indexer').buildDeepbookPublicIndexer>; onMidChange?: (mid: number) => void }) {
  const [bids, setBids] = useState<[number, number][]>([]);
  const [asks, setAsks] = useState<[number, number][]>([]);

  useEffect(() => {
    let mounted = true;
    const load = async () => {
      try {
        const ob = await indexer.orderbook(pool, { level: 1, depth: 16 });
        if (!mounted) return;
        const b = (ob.bids ?? []).map(([p, q]) => [Number(p), Number(q)]) as [number, number][];
        const a = (ob.asks ?? []).map(([p, q]) => [Number(p), Number(q)]) as [number, number][];
        setBids(b);
        setAsks(a);
        if (b.length && a.length) onMidChange?.((b[0][0] + a[0][0]) / 2);
      } catch {}
    };
    void load();
    const id = setInterval(load, 1500);
    return () => { mounted = false; clearInterval(id); };
  }, [pool, indexer, onMidChange]);

  return (
    <div className={styles.root}>
      <div className={styles.header}>Order Book</div>
      <div className={styles.columns}><span>Price</span><span>Size</span></div>
      <div className={styles.rows}>
        {asks.slice(0, 16).reverse().map(([p,q], i) => (
          <div key={`a-${i}`} className={styles.ask}><span>{p.toLocaleString()}</span><span>{q.toLocaleString()}</span></div>
        ))}
        {bids.slice(0, 16).map(([p,q], i) => (
          <div key={`b-${i}`} className={styles.bid}><span>{p.toLocaleString()}</span><span>{q.toLocaleString()}</span></div>
        ))}
      </div>
    </div>
  );
}



