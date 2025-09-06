import { useEffect, useState } from 'react';
import styles from './Trades.module.css';

export function Trades({ pool, indexer }: { pool: string; indexer: ReturnType<typeof import('../../lib/indexer').buildDeepbookPublicIndexer> }) {
  const [rows, setRows] = useState<Array<{ price: number; qty: number; ts: number }>>([]);
  useEffect(() => {
    let mounted = true;
    const load = async () => {
      try {
        const t = await indexer.trades(pool, { limit: 50 });
        if (!mounted) return; setRows(t.reverse());
      } catch {}
    };
    void load();
    const id = setInterval(load, 2000);
    return () => { mounted = false; clearInterval(id); };
  }, [pool, indexer]);
  return (
    <div className={styles.root}>
      <div className={styles.header}>Trades</div>
      <div className={styles.table}>
        {rows.map((r,i)=> (
          <div key={i} className={styles.row}>
            <span>{new Date(r.ts*1000).toLocaleTimeString()}</span>
            <span>{r.price.toLocaleString()}</span>
            <span>{r.qty.toLocaleString()}</span>
          </div>
        ))}
      </div>
    </div>
  );
}



