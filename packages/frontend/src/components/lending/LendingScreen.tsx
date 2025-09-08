import { useState, useMemo } from 'react';
import styles from './LendingScreen.module.css';
import { defaultSettings, getTokenTypeTag, type TokenInfo } from '../../lib/settings.config';
import { TrendingUp, TrendingDown, Percent, AlertCircle } from 'lucide-react';

type LendingPool = {
  id: string;
  token: TokenInfo;
  supplyApy: number;
  borrowApy: number;
  totalSupply: number;
  totalBorrow: number;
  utilizationRate: number;
  totalLiquidity: number;
  userSupplied?: number;
  userBorrowed?: number;
  maxLtv: number;
  liquidationThreshold: number;
  reserveFactor: number;
};

type ViewMode = 'markets' | 'portfolio';

export function LendingScreen({ started: _started, network, protocolStatus }: { 
  started?: boolean;
  network?: string;
  protocolStatus?: {
    options: boolean;
    futures: boolean;
    perps: boolean;
    lending: boolean;
    staking: boolean;
    dex: boolean;
  }
}) {
  // Suppress unused parameter warning
  _started;
  const [viewMode, setViewMode] = useState<ViewMode>('markets');
  const [selectedPool, setSelectedPool] = useState<LendingPool | null>(null);
  const [isDrawerOpen, setIsDrawerOpen] = useState(false);
  
  // Generate lending pools for all tokens with realistic fake data
  const lendingPools: LendingPool[] = useMemo(() => {
    
    return defaultSettings.tokens.map((token, index) => {
      // Generate realistic APYs based on token type
      const baseSupplyApy = token.symbol === 'SUI' ? 2.8 : 
                           token.symbol === 'USDC' ? 4.5 :
                           token.symbol === 'USDT' || token.symbol === 'suiUSDT' ? 4.2 :
                           token.symbol.includes('USD') ? 3.8 :
                           token.symbol === 'WBTC' || token.symbol === 'suiBTC' || token.symbol === 'xBTC' ? 1.9 :
                           token.symbol === 'WETH' || token.symbol === 'suiETH' ? 2.3 :
                           token.symbol === 'DEEP' ? 5.2 :
                           token.symbol === 'UNXV' ? 6.1 :
                           token.symbol === 'DRF' ? 4.8 :
                           token.symbol === 'NS' ? 7.2 :
                           token.symbol === 'TYPUS' ? 5.5 :
                           token.symbol === 'WAL' ? 4.1 :
                           token.symbol === 'IKA' ? 6.8 :
                           token.symbol === 'SEND' ? 3.9 :
                           token.symbol === 'APT' ? 3.2 :
                           token.symbol === 'CELO' ? 2.9 :
                           token.symbol.startsWith('W') ? 2.1 : // Other wrapped tokens
                           Math.random() * 3 + 2.5; // Default for other tokens
      
      const borrowApy = baseSupplyApy + Math.random() * 3 + 1.5;
      
      // Generate realistic supply/borrow amounts based on token
      const baseSupply = token.symbol === 'SUI' ? Math.floor(Math.random() * 20_000_000 + 45_000_000) :
                        token.symbol === 'USDC' ? Math.floor(Math.random() * 10_000_000 + 20_000_000) :
                        token.symbol === 'USDT' || token.symbol === 'suiUSDT' ? Math.floor(Math.random() * 8_000_000 + 15_000_000) :
                        token.symbol.includes('USD') ? Math.floor(Math.random() * 5_000_000 + 8_000_000) :
                        token.symbol === 'WBTC' || token.symbol === 'suiBTC' || token.symbol === 'xBTC' ? Math.floor(Math.random() * 800 + 1_000) :
                        token.symbol === 'WETH' || token.symbol === 'suiETH' ? Math.floor(Math.random() * 5_000 + 7_500) :
                        token.symbol === 'DEEP' ? Math.floor(Math.random() * 8_000_000 + 12_000_000) :
                        token.symbol === 'UNXV' ? Math.floor(Math.random() * 15_000_000 + 25_000_000) :
                        token.symbol === 'DRF' ? Math.floor(Math.random() * 2_000_000 + 3_000_000) :
                        token.symbol === 'NS' ? Math.floor(Math.random() * 1_500_000 + 2_500_000) :
                        token.symbol === 'TYPUS' ? Math.floor(Math.random() * 3_000_000 + 4_000_000) :
                        token.symbol === 'WAL' ? Math.floor(Math.random() * 5_000_000 + 8_000_000) :
                        token.symbol === 'IKA' ? Math.floor(Math.random() * 800_000 + 1_200_000) :
                        token.symbol === 'SEND' ? Math.floor(Math.random() * 1_000_000 + 1_800_000) :
                        token.symbol === 'APT' ? Math.floor(Math.random() * 2_000_000 + 3_500_000) :
                        token.symbol === 'CELO' ? Math.floor(Math.random() * 1_200_000 + 2_000_000) :
                        token.symbol.startsWith('W') ? Math.floor(Math.random() * 1_500_000 + 2_500_000) : // Other wrapped tokens
                        Math.floor(Math.random() * 3_000_000 + 1_000_000); // Default for other tokens
      
      const totalBorrow = Math.floor(baseSupply * (0.3 + Math.random() * 0.4));
      const utilizationRate = (totalBorrow / baseSupply) * 100;
      
      return {
        id: `pool-${token.symbol.toLowerCase()}`,
        token,
        supplyApy: Number(baseSupplyApy.toFixed(2)),
        borrowApy: Number(borrowApy.toFixed(2)),
        totalSupply: baseSupply,
        totalBorrow,
        utilizationRate: Number(utilizationRate.toFixed(1)),
        totalLiquidity: baseSupply - totalBorrow,
        // Simulate some user positions (about 30% of pools have user activity)
        userSupplied: index % 3 === 0 ? Math.floor(Math.random() * 50000 + 1000) : undefined,
        userBorrowed: index % 5 === 0 ? Math.floor(Math.random() * 25000 + 500) : undefined,
        maxLtv: token.symbol.includes('USD') ? Math.floor(Math.random() * 5 + 83) : // 83-87%
                token.symbol === 'SUI' ? Math.floor(Math.random() * 5 + 73) : // 73-77%
                token.symbol.includes('BTC') || token.symbol.includes('ETH') ? Math.floor(Math.random() * 5 + 68) : // 68-72%
                token.symbol === 'DEEP' || token.symbol === 'UNXV' ? Math.floor(Math.random() * 5 + 70) : // 70-74%
                Math.floor(Math.random() * 10 + 60), // 60-69% for others
        liquidationThreshold: token.symbol.includes('USD') ? Math.floor(Math.random() * 3 + 88) : // 88-90%
                             token.symbol === 'SUI' ? Math.floor(Math.random() * 5 + 78) : // 78-82%
                             token.symbol.includes('BTC') || token.symbol.includes('ETH') ? Math.floor(Math.random() * 5 + 73) : // 73-77%
                             Math.floor(Math.random() * 8 + 72), // 72-79% for others
        reserveFactor: Math.floor(Math.random() * 15 + 10) // 10-24%
      };
    });
  }, []);

  // Calculate portfolio totals
  const portfolioStats = useMemo(() => {
    const totalSupplied = lendingPools.reduce((sum, pool) => sum + (pool.userSupplied || 0), 0);
    const totalBorrowed = lendingPools.reduce((sum, pool) => sum + (pool.userBorrowed || 0), 0);
    const netApy = lendingPools.reduce((sum, pool) => {
      const supplyValue = (pool.userSupplied || 0) * pool.supplyApy / 100;
      const borrowValue = (pool.userBorrowed || 0) * pool.borrowApy / 100;
      return sum + supplyValue - borrowValue;
    }, 0);
    
    return {
      totalSupplied,
      totalBorrowed,
      netApy: totalSupplied > 0 ? (netApy / totalSupplied) * 100 : 0,
      healthFactor: totalBorrowed > 0 ? (totalSupplied * 0.8) / totalBorrowed : Number.POSITIVE_INFINITY
    };
  }, [lendingPools]);

  const formatNumber = (num: number, decimals: number = 2) => {
    if (num >= 1_000_000) return `${(num / 1_000_000).toFixed(1)}M`;
    if (num >= 1_000) return `${(num / 1_000).toFixed(1)}K`;
    return num.toFixed(decimals);
  };

  const getUtilizationColor = (rate: number) => {
    if (rate < 60) return '#10b981';
    if (rate < 80) return '#f59e0b';
    return '#ef4444';
  };

  return (
    <div className={styles.root}>
      {/* Header */}
      <div className={styles.header}>
        <div className={styles.pairBar}>
          <div className={styles.pair}>
            Unxversal Lending
          </div>
          <div className={styles.metrics}>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>$2.4B</div>
              <div className={styles.metricLabel}>TVL</div>
            </div>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>12.3K</div>
              <div className={styles.metricLabel}>Active Users</div>
            </div>
            <div className={styles.viewToggle}>
              <button 
                className={viewMode === 'markets' ? styles.active : ''} 
                onClick={() => setViewMode('markets')}
              >
                Markets
              </button>
              <button 
                className={viewMode === 'portfolio' ? styles.active : ''} 
                onClick={() => setViewMode('portfolio')}
              >
                Portfolio
              </button>
            </div>
          </div>
        </div>
      </div>

      {/* Content */}
      <div className={styles.content}>
        {viewMode === 'portfolio' && (
          <div className={styles.portfolioSummary}>
            <div className={styles.summaryCard}>
              <div className={styles.cardHeader}>
                <TrendingUp size={20} />
                <span>Total Supplied</span>
              </div>
              <div className={styles.cardValue}>${formatNumber(portfolioStats.totalSupplied)}</div>
            </div>
            <div className={styles.summaryCard}>
              <div className={styles.cardHeader}>
                <TrendingDown size={20} />
                <span>Total Borrowed</span>
              </div>
              <div className={styles.cardValue}>${formatNumber(portfolioStats.totalBorrowed)}</div>
            </div>
            <div className={styles.summaryCard}>
              <div className={styles.cardHeader}>
                <Percent size={20} />
                <span>Net APY</span>
              </div>
              <div className={`${styles.cardValue} ${portfolioStats.netApy >= 0 ? styles.positive : styles.negative}`}>
                {portfolioStats.netApy.toFixed(2)}%
              </div>
            </div>
            <div className={styles.summaryCard}>
              <div className={styles.cardHeader}>
                <AlertCircle size={20} />
                <span>Health Factor</span>
              </div>
              <div className={`${styles.cardValue} ${
                portfolioStats.healthFactor > 2 ? styles.positive : 
                portfolioStats.healthFactor > 1.2 ? styles.warning : styles.negative
              }`}>
                {portfolioStats.healthFactor === Number.POSITIVE_INFINITY ? '∞' : portfolioStats.healthFactor.toFixed(2)}
              </div>
            </div>
          </div>
        )}

        <div className={styles.marketsTable}>
          <div className={styles.tableHeader}>
            <span>Asset</span>
            <span>Supply APY</span>
            <span>Borrow APY</span>
            <span>Total Supply</span>
            <span>Total Borrow</span>
            <span>Utilization</span>
            <span>Liquidity</span>
            {viewMode === 'portfolio' && <span>Your Position</span>}
            <span>Actions</span>
          </div>
          
          <div className={styles.tableBody}>
            {lendingPools.length === 0 ? (
              <div className={styles.emptyState}>
                <p>No lending pools available. Check your settings configuration.</p>
              </div>
            ) : (
              lendingPools.map((pool) => (
                <div 
                  key={pool.id} 
                  className={`${styles.tableRow} ${selectedPool?.id === pool.id ? styles.selected : ''}`}
                  onClick={() => {
                    setSelectedPool(pool);
                    setIsDrawerOpen(true);
                  }}
                >
              <div className={styles.assetCell}>
                {pool.token.iconUrl && (
                  <img src={pool.token.iconUrl} alt={pool.token.name} className={styles.tokenIcon} />
                )}
                <div>
                  <div className={styles.tokenSymbol}>{pool.token.symbol}</div>
                  <div className={styles.tokenName}>{pool.token.name}</div>
                </div>
              </div>
              
              <span className={styles.positive}>{pool.supplyApy}%</span>
              <span className={styles.negative}>{pool.borrowApy}%</span>
              <span>{formatNumber(pool.totalSupply)}</span>
              <span>{formatNumber(pool.totalBorrow)}</span>
              
              <div className={styles.utilizationCell}>
                <div 
                  className={styles.utilizationBar}
                  style={{ 
                    background: `linear-gradient(90deg, ${getUtilizationColor(pool.utilizationRate)} ${pool.utilizationRate}%, #1a1d29 ${pool.utilizationRate}%)` 
                  }}
                />
                <span style={{ color: getUtilizationColor(pool.utilizationRate) }}>
                  {pool.utilizationRate}%
                </span>
              </div>
              
              <span>{formatNumber(pool.totalLiquidity)}</span>
              
              {viewMode === 'portfolio' && (
                <div className={styles.positionCell}>
                  {pool.userSupplied && (
                    <div className={styles.positionItem}>
                      <TrendingUp size={12} />
                      <span>{formatNumber(pool.userSupplied)}</span>
                    </div>
                  )}
                  {pool.userBorrowed && (
                    <div className={styles.positionItem}>
                      <TrendingDown size={12} />
                      <span>{formatNumber(pool.userBorrowed)}</span>
                    </div>
                  )}
                  {!pool.userSupplied && !pool.userBorrowed && <span>-</span>}
                </div>
              )}
              
              <div className={styles.actionButtons}>
                <button className={styles.supplyBtn}>Supply</button>
                <button className={styles.borrowBtn}>Borrow</button>
              </div>
            </div>
              ))
            )}
          </div>
        </div>
      </div>

      {/* Pool Details Drawer */}
      <div className={`${styles.drawer} ${isDrawerOpen ? styles.drawerOpen : ''}`}>
        <div className={styles.drawerOverlay} onClick={() => setIsDrawerOpen(false)} />
        <div className={styles.drawerContent}>
          {selectedPool && (
            <>
              <div className={styles.drawerHeader}>
                <div className={styles.drawerHeaderLeft}>
                  {selectedPool.token.iconUrl && (
                    <img src={selectedPool.token.iconUrl} alt={selectedPool.token.name} className={styles.drawerTokenIcon} />
                  )}
                  <div>
                    <h3>{selectedPool.token.symbol} Pool Details</h3>
                    <span className={styles.tokenName}>{selectedPool.token.name}</span>
                  </div>
                </div>
                <button onClick={() => setIsDrawerOpen(false)} className={styles.drawerCloseBtn}>×</button>
              </div>
              
              <div className={styles.drawerBody}>
                <div className={styles.drawerMetrics}>
                  <div className={styles.drawerMetricCard}>
                    <div className={styles.drawerMetricValue}>{selectedPool.supplyApy}%</div>
                    <div className={styles.drawerMetricLabel}>Supply APY</div>
                  </div>
                  <div className={styles.drawerMetricCard}>
                    <div className={styles.drawerMetricValue}>{selectedPool.borrowApy}%</div>
                    <div className={styles.drawerMetricLabel}>Borrow APY</div>
                  </div>
                  <div className={styles.drawerMetricCard}>
                    <div className={styles.drawerMetricValue} style={{ color: getUtilizationColor(selectedPool.utilizationRate) }}>
                      {selectedPool.utilizationRate}%
                    </div>
                    <div className={styles.drawerMetricLabel}>Utilization</div>
                  </div>
                </div>

                <div className={styles.drawerActions}>
                  <button className={styles.drawerSupplyBtn}>Supply {selectedPool.token.symbol}</button>
                  <button className={styles.drawerBorrowBtn}>Borrow {selectedPool.token.symbol}</button>
                </div>

                <div className={styles.drawerDetailsGrid}>
                  <div className={styles.drawerDetailCard}>
                    <h4>Pool Information</h4>
                    <div className={styles.drawerDetailRow}>
                      <span>Total Supply:</span>
                      <span>{formatNumber(selectedPool.totalSupply)}</span>
                    </div>
                    <div className={styles.drawerDetailRow}>
                      <span>Total Borrow:</span>
                      <span>{formatNumber(selectedPool.totalBorrow)}</span>
                    </div>
                    <div className={styles.drawerDetailRow}>
                      <span>Available Liquidity:</span>
                      <span>{formatNumber(selectedPool.totalLiquidity)}</span>
                    </div>
                    <div className={styles.drawerDetailRow}>
                      <span>Max LTV:</span>
                      <span>{selectedPool.maxLtv}%</span>
                    </div>
                    <div className={styles.drawerDetailRow}>
                      <span>Liquidation Threshold:</span>
                      <span>{selectedPool.liquidationThreshold}%</span>
                    </div>
                    <div className={styles.drawerDetailRow}>
                      <span>Reserve Factor:</span>
                      <span>{selectedPool.reserveFactor}%</span>
                    </div>
                  </div>
                  
                  <div className={styles.drawerDetailCard}>
                    <h4>Your Position</h4>
                    {selectedPool.userSupplied || selectedPool.userBorrowed ? (
                      <>
                        {selectedPool.userSupplied && (
                          <div className={styles.drawerDetailRow}>
                            <span>Supplied:</span>
                            <span className={styles.positive}>{formatNumber(selectedPool.userSupplied)}</span>
                          </div>
                        )}
                        {selectedPool.userBorrowed && (
                          <div className={styles.drawerDetailRow}>
                            <span>Borrowed:</span>
                            <span className={styles.negative}>{formatNumber(selectedPool.userBorrowed)}</span>
                          </div>
                        )}
                      </>
                    ) : (
                      <div className={styles.drawerEmptyPosition}>
                        <span>No active positions</span>
                        <span>Start by supplying or borrowing {selectedPool.token.symbol}</span>
                      </div>
                    )}
                    
                    <div className={styles.drawerDetailRow}>
                      <span>Token Contract:</span>
                      <span className={styles.contractAddress}>
                        {getTokenTypeTag(selectedPool.token).slice(0, 20)}...
            </span>
                    </div>
                  </div>
                </div>
              </div>
            </>
          )}
        </div>
      </div>

      {/* Footer status */}
      <footer className={styles.footer}>
        <div className={styles.statusBadges}>
          <div className={`${styles.badge} ${protocolStatus?.options ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.options ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>Options</span>
          </div>
          
          <div className={`${styles.badge} ${protocolStatus?.futures ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.futures ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>Futures</span>
          </div>
          
          <div className={`${styles.badge} ${protocolStatus?.perps ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.perps ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>Perps</span>
          </div>
          
          <div className={`${styles.badge} ${protocolStatus?.lending ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.lending ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>Lending</span>
          </div>
          
          <div className={`${styles.badge} ${protocolStatus?.staking ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.staking ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>Staking</span>
          </div>
          
          <div className={`${styles.badge} ${protocolStatus?.dex ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.dex ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>DEX</span>
          </div>
        </div>
        
        <div className={styles.networkBadge}>
          <span>{(network || 'testnet').toUpperCase()}</span>
        </div>
      </footer>
    </div>
  );
}


