import { useEffect, useState } from 'react';
import styles from './Orderbook.module.css';

export function Orderbook() {
  const [bids, setBids] = useState<[number, number][]>([]);
  const [asks, setAsks] = useState<[number, number][]>([]);

  useEffect(() => {
    let mounted = true;
    const load = async () => {
      try {
        // Generate sample gas futures orderbook data
        const midPrice = 0.02345;
        const spread = 0.00005;
        
        const sampleBids = Array.from({ length: 16 }, (_, i) => [
          midPrice - (spread / 2) - (i * 0.00002), 
          Math.round((Math.random() * 100000 + 5000) * (16 - i) / 16)
        ]);
        const sampleAsks = Array.from({ length: 16 }, (_, i) => [
          midPrice + (spread / 2) + (i * 0.00002), 
          Math.round((Math.random() * 100000 + 5000) * (16 - i) / 16)
        ]);
        
        if (!mounted) return;
        setBids(sampleBids as [number, number][]);
        setAsks(sampleAsks as [number, number][]);
      } catch {}
    };
    void load();
    const id = setInterval(load, 1500);
    return () => { mounted = false; clearInterval(id); };
  }, []);

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
              <span className={styles.askPrice}>{p.toFixed(5)}</span>
              <span>{q.toLocaleString()}</span>
            </div>
          );
        })}
      </div>
      
      <div className={styles.spread}>
        <span>Spread: {bids.length && asks.length ? (asks[0][0] - bids[0][0]).toFixed(5) : '-'}</span>
        <span>{bids.length && asks.length ? (((asks[0][0] - bids[0][0]) / bids[0][0]) * 100).toFixed(3) + '%' : '-'}</span>
      </div>
      
      <div className={styles.bidsSection}>
        {bids.slice(0, 16).map(([p,q], i) => {
          const depthPercent = (q / maxSize) * 100;
          return (
            <div key={`b-${i}`} className={styles.bid} style={{ '--depth': `${depthPercent}%` } as any}>
              <div className={styles.depthBar} />
              <span className={styles.bidPrice}>{p.toFixed(5)}</span>
              <span>{q.toLocaleString()}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}