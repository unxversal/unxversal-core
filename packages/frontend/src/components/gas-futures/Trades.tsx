import { useEffect, useState } from 'react';
import styles from './Trades.module.css';

export function Trades() {
  const [rows, setRows] = useState<Array<{ price: number; qty: number; ts: number; side: 'buy' | 'sell' }>>([]);
  
  useEffect(() => {
    let mounted = true;
    const load = async () => {
      try {
        // Generate sample gas futures trade data
        const now = Date.now() / 1000;
        const basePrice = 0.02345;
        const sampleTrades = Array.from({ length: 30 }, (_, i) => ({
          price: basePrice + (Math.random() - 0.5) * 0.002, // Price around base with some variance
          qty: Math.round((Math.random() * 150000 + 5000)), // Random MIST quantity
          ts: now - (i * 30), // Trades every 30 seconds going back
          side: Math.random() > 0.5 ? 'buy' as const : 'sell' as const
        }));
        if (!mounted) return;
        setRows(sampleTrades);
      } catch {}
    };
    void load();
    const id = setInterval(load, 2000);
    return () => { mounted = false; clearInterval(id); };
  }, []);

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
            <span className={r.side === 'buy' ? styles.buyPrice : styles.sellPrice}>{r.price.toFixed(5)}</span>
            <span className={styles.size}>{r.qty.toLocaleString()}</span>
            <span className={styles.time}>{new Date(r.ts * 1000).toLocaleTimeString([], { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' })}</span>
          </div>
        ))}
      </div>
    </div>
  );
}