import styles from './LendingScreen.module.css';

type Market = { id: string; asset: string; supplyApy: number; borrowApy: number; totalSupply: number; totalBorrow: number };

export function LendingScreen() {
  // Placeholder markets; wire to on-chain read later
  const markets: Market[] = [
    { id: 'pool-1', asset: 'SUI', supplyApy: 3.2, borrowApy: 5.6, totalSupply: 1_200_000, totalBorrow: 450_000 },
    { id: 'pool-2', asset: 'USDC', supplyApy: 4.1, borrowApy: 6.9, totalSupply: 3_400_000, totalBorrow: 1_120_000 },
  ];
  return (
    <div className={styles.root}>
      <div className={styles.header}>Lending</div>
      <div className={styles.table}>
        <div className={styles.rowHead}><span>Asset</span><span>Supply APY</span><span>Borrow APY</span><span>Total Supply</span><span>Total Borrow</span><span>Actions</span></div>
        {markets.map((m)=> (
          <div key={m.id} className={styles.row}>
            <span>{m.asset}</span>
            <span>{m.supplyApy.toFixed(2)}%</span>
            <span>{m.borrowApy.toFixed(2)}%</span>
            <span>{m.totalSupply.toLocaleString()}</span>
            <span>{m.totalBorrow.toLocaleString()}</span>
            <span>
              <button className={styles.btn} disabled>Supply</button>
              <button className={styles.btn} disabled>Borrow</button>
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}


