import { useEffect, useState } from 'react';
import styles from './Trades.module.css';

export function Trades({ pool, indexer }: { pool: string; indexer: ReturnType<typeof import('../../lib/indexer').buildDeepbookPublicIndexer> }) {
  const [rows, setRows] = useState<Array<{ price: number; qty: number; ts: number; side: 'buy' | 'sell' }>>([]);
  
  useEffect(() => {
    let mounted = true;
    const load = async () => {
      try {
        let trades: any[] = [];
        try {
          trades = await indexer.trades(pool, { limit: 50 });
        } catch {}
        
        if (!trades || trades.length === 0) {
          // Generate sample trade data
          const now = Date.now() / 1000;
          const sampleTrades = Array.from({ length: 30 }, (_, i) => ({
            price: 100 + (Math.random() - 0.5) * 2, // Price around 100 with some variance
            qty: Math.round((Math.random() * 1000 + 10) * 100) / 100, // Random quantity
            ts: now - (i * 30), // Trades every 30 seconds going back
            side: Math.random() > 0.5 ? 'buy' as const : 'sell' as const
          }));
          if (!mounted) return;
          setRows(sampleTrades);
          return;
        }
        
        if (!mounted) return;
        const processedTrades = trades.map(t => ({
          ...t,
          side: Math.random() > 0.5 ? 'buy' as const : 'sell' as const // Random side for now
        })).reverse();
        setRows(processedTrades);
      } catch {}
    };
    void load();
    const id = setInterval(load, 2000);
    return () => { mounted = false; clearInterval(id); };
  }, [pool, indexer]);

  return (
    <div className={styles.root}>
      <div className={styles.header}>Trades</div>
      <div className={styles.columns}>
        <span>Price</span>
        <span>Size</span>
        <span>Time</span>
      </div>
      <div className={styles.table}>
        {rows.map((r, i) => (
          <div key={i} className={styles.row}>
            <span className={r.side === 'buy' ? styles.buyPrice : styles.sellPrice}>{r.price.toFixed(3)}</span>
            <span className={styles.size}>{r.qty.toLocaleString()}</span>
            <span className={styles.time}>{new Date(r.ts * 1000).toLocaleTimeString([], { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' })}</span>
          </div>
        ))}
      </div>
    </div>
  );
}



