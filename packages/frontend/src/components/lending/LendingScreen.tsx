import { useState, useMemo } from 'react';
import styles from './LendingScreen.module.css';
import { defaultSettings, getTokenTypeTag, getTokenBySymbol, getDefaultQuoteToken, type TokenInfo } from '../../lib/settings.config';
import { MARKETS } from '../../lib/markets';
import { TrendingUp, TrendingDown, Percent, AlertCircle } from 'lucide-react';
import { ConnectButton, useCurrentAccount } from '@mysten/dapp-kit';

type LendingMarket = {
  id: string;
  symbolPair: string; // e.g. "SUI/USDC"
  collateral: TokenInfo; // volatile asset
  debt: TokenInfo; // stablecoin (USDC)
  supplyApy: number;
  borrowApy: number;
  totalSupplyDebt: number; // total USDC supplied
  totalBorrowDebt: number; // total USDC borrowed
  utilizationRate: number; // %
  totalLiquidityDebt: number; // USDC liquidity
  userSuppliedDebt?: number; // user's USDC supplied
  userBorrowedDebt?: number; // user's USDC borrowed
  userCollateral?: number; // user's posted collateral units
  maxLtv: number; // %
  liquidationThreshold: number; // %
  reserveFactor: number; // %
};

type ViewMode = 'markets' | 'portfolio';
type DrawerMode = 'supplyDebt' | 'depositCollat' | 'borrowDebt';

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
  const [selectedMarket, setSelectedMarket] = useState<LendingMarket | null>(null);
  const [isDrawerOpen, setIsDrawerOpen] = useState(false);
  const [drawerMode, setDrawerMode] = useState<DrawerMode>('supplyDebt');
  const [inputAmount, setInputAmount] = useState<number>(0);
  const [userBalance] = useState<number>(1000); // Mock balance
  const [submitting, setSubmitting] = useState(false);
  const account = useCurrentAccount();
  
  // Generate lending markets (Collat/USDC) with realistic fake data
  const lendingMarkets: LendingMarket[] = useMemo(() => {
    const usdc = getDefaultQuoteToken() || getTokenBySymbol('USDC') || defaultSettings.tokens.find(t => t.symbol === 'USDC');
    if (!usdc) return [];
    const pairs = MARKETS.usdc; // All X/USDC symbols
    const out: LendingMarket[] = [];
    let idx = 0;
    for (const pair of pairs) {
      const [collatSym, debtSym] = pair.split('/');
      if (debtSym !== 'USDC') continue;
      const collat = getTokenBySymbol(collatSym) || defaultSettings.tokens.find(t => t.symbol === collatSym);
      if (!collat) continue;
      // Sample APYs based on collateral class
      const baseSupplyApy = collat.symbol === 'SUI' ? 2.8 :
                           collat.symbol === 'DEEP' ? 5.2 :
                           collat.symbol === 'UNXV' ? 6.1 :
                           collat.symbol.includes('BTC') ? 1.9 :
                           collat.symbol.includes('ETH') ? 2.3 :
                           collat.symbol.startsWith('W') ? 2.1 :
                           collat.symbol.includes('USD') ? 3.8 :
                           Math.random() * 3 + 2.5;
      const borrowApy = baseSupplyApy + Math.random() * 3 + 1.5;
      // Sample totals (USDC notional)
      const baseSupplyDebt = collat.symbol === 'SUI' ? Math.floor(Math.random() * 20_000_000 + 45_000_000) :
                             collat.symbol.includes('BTC') ? Math.floor(Math.random() * 8_000_000 + 12_000_000) :
                             collat.symbol.includes('ETH') ? Math.floor(Math.random() * 6_000_000 + 9_000_000) :
                             collat.symbol === 'DEEP' ? Math.floor(Math.random() * 8_000_000 + 12_000_000) :
                             collat.symbol === 'UNXV' ? Math.floor(Math.random() * 15_000_000 + 25_000_000) :
                             Math.floor(Math.random() * 5_000_000 + 6_000_000);
      const totalBorrowDebt = Math.floor(baseSupplyDebt * (0.3 + Math.random() * 0.4));
      const utilizationRate = (totalBorrowDebt / baseSupplyDebt) * 100;
      // Risk params
      const maxLtv = collat.symbol.includes('USD') ? Math.floor(Math.random() * 5 + 83) :
                     collat.symbol === 'SUI' ? Math.floor(Math.random() * 5 + 73) :
                     (collat.symbol.includes('BTC') || collat.symbol.includes('ETH')) ? Math.floor(Math.random() * 5 + 68) :
                     Math.floor(Math.random() * 10 + 60);
      const liquidationThreshold = collat.symbol.includes('USD') ? Math.floor(Math.random() * 3 + 88) :
                                   collat.symbol === 'SUI' ? Math.floor(Math.random() * 5 + 78) :
                                   (collat.symbol.includes('BTC') || collat.symbol.includes('ETH')) ? Math.floor(Math.random() * 5 + 73) :
                                   Math.floor(Math.random() * 8 + 72);
      const reserveFactor = Math.floor(Math.random() * 15 + 10);

      out.push({
        id: `mkt-${collat.symbol.toLowerCase()}-usdc`,
        symbolPair: pair,
        collateral: collat,
        debt: usdc,
        supplyApy: Number(baseSupplyApy.toFixed(2)),
        borrowApy: Number(borrowApy.toFixed(2)),
        totalSupplyDebt: baseSupplyDebt,
        totalBorrowDebt,
        utilizationRate: Number(utilizationRate.toFixed(1)),
        totalLiquidityDebt: baseSupplyDebt - totalBorrowDebt,
        userSuppliedDebt: idx % 3 === 0 ? Math.floor(Math.random() * 50_000 + 1_000) : undefined,
        userBorrowedDebt: idx % 5 === 0 ? Math.floor(Math.random() * 25_000 + 500) : undefined,
        userCollateral: idx % 4 === 0 ? Math.floor(Math.random() * 1_000 + 50) : undefined,
        maxLtv,
        liquidationThreshold,
        reserveFactor,
      });
      idx += 1;
    }
    return out;
  }, []);

  // Calculate portfolio totals
  const portfolioStats = useMemo(() => {
    const totalSupplied = lendingMarkets.reduce((sum, m) => sum + (m.userSuppliedDebt || 0), 0);
    const totalBorrowed = lendingMarkets.reduce((sum, m) => sum + (m.userBorrowedDebt || 0), 0);
    const netApyAbs = lendingMarkets.reduce((sum, m) => {
      const supplyValue = (m.userSuppliedDebt || 0) * m.supplyApy / 100;
      const borrowValue = (m.userBorrowedDebt || 0) * m.borrowApy / 100;
      return sum + supplyValue - borrowValue;
    }, 0);
    return {
      totalSupplied,
      totalBorrowed,
      netApy: totalSupplied > 0 ? (netApyAbs / totalSupplied) * 100 : 0,
      healthFactor: totalBorrowed > 0 ? (totalSupplied * 0.8) / totalBorrowed : Number.POSITIVE_INFINITY,
    };
  }, [lendingMarkets]);

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

  const applyPercent = (percent: number) => {
    const amount = userBalance * percent;
    setInputAmount(amount);
  };

  const handleSubmit = async () => {
    if (!selectedMarket || inputAmount <= 0 || !account?.address) return;
    const action = drawerMode === 'supplyDebt' ? 'Supply USDC'
                  : drawerMode === 'depositCollat' ? `Deposit ${selectedMarket.collateral.symbol}`
                  : 'Borrow USDC';
    setSubmitting(true);
    try {
      // TODO: Implement actual lending/borrowing transaction logic
      await new Promise(resolve => setTimeout(resolve, 2000)); // Mock delay
      console.log(`${action}: ${inputAmount} (${selectedMarket.symbolPair})`);
      
      // Reset form after successful submission
      setInputAmount(0);
      setIsDrawerOpen(false);
    } catch (error) {
      console.error('Transaction failed:', error);
    } finally {
      setSubmitting(false);
    }
  };

  const handleDrawerAction = (mode: DrawerMode) => {
    setDrawerMode(mode);
    setInputAmount(0);
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
            <span>Market (Collat/USDC)</span>
            <span>Supply APY</span>
            <span>Borrow APY</span>
            <span>Total USDC Supply</span>
            <span>Total USDC Borrow</span>
            <span>Utilization</span>
            <span>USDC Liquidity</span>
            {viewMode === 'portfolio' && <span>Your Position</span>}
            <span>Actions</span>
          </div>
          
          <div className={styles.tableBody}>
            {lendingMarkets.length === 0 ? (
              <div className={styles.emptyState}>
                <p>No lending pools available. Check your settings configuration.</p>
              </div>
            ) : (
              lendingMarkets.map((mkt) => (
                <div 
                  key={mkt.id} 
                  className={`${styles.tableRow} ${selectedMarket?.id === mkt.id ? styles.selected : ''}`}
                  onClick={() => {
                    setSelectedMarket(mkt);
                    setIsDrawerOpen(true);
                  }}
                >
              <div className={styles.assetCell}>
                {mkt.collateral.iconUrl && (
                  <img src={mkt.collateral.iconUrl} alt={mkt.collateral.name} className={styles.tokenIcon} />
                )}
                <div>
                  <div className={styles.tokenSymbol}>{mkt.symbolPair}</div>
                  <div className={styles.tokenName}>{mkt.collateral.name} as Collateral, USDC as Debt</div>
                </div>
              </div>
              
              <span className={styles.positive}>{mkt.supplyApy}%</span>
              <span className={styles.negative}>{mkt.borrowApy}%</span>
              <span>{formatNumber(mkt.totalSupplyDebt)}</span>
              <span>{formatNumber(mkt.totalBorrowDebt)}</span>
              
              <div className={styles.utilizationCell}>
                <div 
                  className={styles.utilizationBar}
                  style={{ 
                    background: `linear-gradient(90deg, ${getUtilizationColor(mkt.utilizationRate)} ${mkt.utilizationRate}%, #1a1d29 ${mkt.utilizationRate}%)` 
                  }}
                />
                <span style={{ color: getUtilizationColor(mkt.utilizationRate) }}>
                  {mkt.utilizationRate}%
                </span>
              </div>
              
              <span>{formatNumber(mkt.totalLiquidityDebt)}</span>
              
              {viewMode === 'portfolio' && (
                <div className={styles.positionCell}>
                  {mkt.userSuppliedDebt && (
                    <div className={styles.positionItem}>
                      <TrendingUp size={12} />
                      <span>{formatNumber(mkt.userSuppliedDebt)} USDC</span>
                    </div>
                  )}
                  {mkt.userBorrowedDebt && (
                    <div className={styles.positionItem}>
                      <TrendingDown size={12} />
                      <span>{formatNumber(mkt.userBorrowedDebt)} USDC</span>
                    </div>
                  )}
                  {!mkt.userSuppliedDebt && !mkt.userBorrowedDebt && <span>-</span>}
                </div>
              )}
              
              <div className={styles.actionButtons}>
                <button className={styles.supplyBtn} onClick={(e) => { e.stopPropagation(); setSelectedMarket(mkt); setIsDrawerOpen(true); setDrawerMode('supplyDebt'); }}>Supply USDC</button>
                <button className={styles.supplyBtn} onClick={(e) => { e.stopPropagation(); setSelectedMarket(mkt); setIsDrawerOpen(true); setDrawerMode('depositCollat'); }}>Deposit {mkt.collateral.symbol}</button>
                <button className={styles.borrowBtn} onClick={(e) => { e.stopPropagation(); setSelectedMarket(mkt); setIsDrawerOpen(true); setDrawerMode('borrowDebt'); }}>Borrow USDC</button>
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
          {selectedMarket && (
            <>
              <div className={styles.drawerHeader}>
                <div className={styles.drawerHeaderLeft}>
                  {selectedMarket.collateral.iconUrl && (
                    <img src={selectedMarket.collateral.iconUrl} alt={selectedMarket.collateral.name} className={styles.drawerTokenIcon} />
                  )}
                  <div>
                    <h3>{selectedMarket.symbolPair} Market</h3>
                    <span className={styles.tokenName}>{selectedMarket.collateral.name} collateral, USDC debt</span>
                  </div>
                </div>
                <button onClick={() => setIsDrawerOpen(false)} className={styles.drawerCloseBtn}>×</button>
              </div>
              
              <div className={styles.drawerBody}>
                <div className={styles.drawerMetrics}>
                  <div className={styles.drawerMetricCard}>
                    <div className={styles.drawerMetricValue}>{selectedMarket.supplyApy}%</div>
                    <div className={styles.drawerMetricLabel}>Supply APY</div>
                  </div>
                  <div className={styles.drawerMetricCard}>
                    <div className={styles.drawerMetricValue}>{selectedMarket.borrowApy}%</div>
                    <div className={styles.drawerMetricLabel}>Borrow APY</div>
                  </div>
                  <div className={styles.drawerMetricCard}>
                    <div className={styles.drawerMetricValue} style={{ color: getUtilizationColor(selectedMarket.utilizationRate) }}>
                      {selectedMarket.utilizationRate}%
                    </div>
                    <div className={styles.drawerMetricLabel}>Utilization</div>
                  </div>
                </div>

                <div className={styles.drawerActions}>
                  <div className={styles.drawerTabs}>
                    <button className={drawerMode === 'supplyDebt' ? styles.active : ''} onClick={() => handleDrawerAction('supplyDebt')}>Supply USDC</button>
                    <button className={drawerMode === 'depositCollat' ? styles.active : ''} onClick={() => handleDrawerAction('depositCollat')}>Deposit {selectedMarket.collateral.symbol}</button>
                    <button className={drawerMode === 'borrowDebt' ? styles.active : ''} onClick={() => handleDrawerAction('borrowDebt')}>Borrow USDC</button>
                  </div>
                  
                  <div className={styles.inputSection}>
                    <div className={styles.balanceInfo}>
                      <span className={styles.balanceLabel}>Available Balance:</span>
                      <span className={styles.balanceAmount}>
                        {userBalance.toFixed(4)} {drawerMode === 'depositCollat' ? selectedMarket.collateral.symbol : 'USDC'}
                      </span>
                    </div>
                    
                    <div className={styles.inputGroup}>
                      <input
                        type="number"
                        value={inputAmount || ''}
                        onChange={(e) => setInputAmount(Number(e.target.value))}
                        placeholder={`Enter ${drawerMode === 'depositCollat' ? 'deposit' : drawerMode === 'supplyDebt' ? 'supply' : 'borrow'} amount`}
                        className={styles.amountInput}
                        max={userBalance}
                        min={0}
                      />
                      <div className={styles.tokenSelector}>
                        <span>{drawerMode === 'depositCollat' ? selectedMarket.collateral.symbol : 'USDC'}</span>
                      </div>
                    </div>
                    
                    <div className={styles.percentButtons}>
                      <button onClick={() => applyPercent(0.25)} className={styles.percentBtn}>25%</button>
                      <button onClick={() => applyPercent(0.5)} className={styles.percentBtn}>50%</button>
                      <button onClick={() => applyPercent(0.75)} className={styles.percentBtn}>75%</button>
                      <button onClick={() => applyPercent(1)} className={styles.percentBtn}>MAX</button>
                    </div>
                    
                    <div className={styles.transactionInfo}>
                      <div className={styles.infoRow}>
                        <span>{drawerMode === 'supplyDebt' ? 'You will earn:' : drawerMode === 'borrowDebt' ? 'You will pay:' : 'You will enable borrowing up to:'}</span>
                        <span className={drawerMode === 'supplyDebt' ? styles.positive : drawerMode === 'borrowDebt' ? styles.negative : ''}>
                          {drawerMode === 'supplyDebt' ? `${selectedMarket.supplyApy}% APY` : drawerMode === 'borrowDebt' ? `${selectedMarket.borrowApy}% APY` : `${selectedMarket.maxLtv}% of collateral value`}
                        </span>
                      </div>
                      {drawerMode === 'borrowDebt' && (
                        <div className={styles.infoRow}>
                          <span>Health Factor:</span>
                          <span className={styles.warning}>1.45</span>
                        </div>
                      )}
                    </div>
                    
                    {!account?.address ? (
                      <div className={styles.connectWallet}>
                        <ConnectButton />
                      </div>
                    ) : (
                      <button
                        onClick={handleSubmit}
                        disabled={submitting || inputAmount <= 0 || inputAmount > userBalance}
                        className={`${styles.submitBtn} ${drawerMode !== 'borrowDebt' ? styles.supplyBtn : styles.borrowBtn}`}
                      >
                        {submitting
                          ? (drawerMode === 'supplyDebt' ? 'Supplying...' : drawerMode === 'depositCollat' ? 'Depositing...' : 'Borrowing...')
                          : inputAmount <= 0
                            ? `Enter amount to ${drawerMode === 'supplyDebt' ? 'supply' : drawerMode === 'depositCollat' ? 'deposit' : 'borrow'}`
                            : drawerMode === 'supplyDebt'
                              ? `Supply ${inputAmount.toLocaleString()} USDC`
                              : drawerMode === 'depositCollat'
                                ? `Deposit ${inputAmount.toLocaleString()} ${selectedMarket.collateral.symbol}`
                                : `Borrow ${inputAmount.toLocaleString()} USDC`}
                      </button>
                    )}
                  </div>
                </div>

                <div className={styles.drawerDetailsGrid}>
                  <div className={styles.drawerDetailCard}>
                    <h4>Pool Information</h4>
                    <div className={styles.drawerDetailRow}>
                      <span>Total USDC Supply:</span>
                      <span>{formatNumber(selectedMarket.totalSupplyDebt)}</span>
                    </div>
                    <div className={styles.drawerDetailRow}>
                      <span>Total USDC Borrow:</span>
                      <span>{formatNumber(selectedMarket.totalBorrowDebt)}</span>
                    </div>
                    <div className={styles.drawerDetailRow}>
                      <span>USDC Liquidity:</span>
                      <span>{formatNumber(selectedMarket.totalLiquidityDebt)}</span>
                    </div>
                    <div className={styles.drawerDetailRow}>
                      <span>Max LTV:</span>
                      <span>{selectedMarket.maxLtv}%</span>
                    </div>
                    <div className={styles.drawerDetailRow}>
                      <span>Liquidation Threshold:</span>
                      <span>{selectedMarket.liquidationThreshold}%</span>
                    </div>
                    <div className={styles.drawerDetailRow}>
                      <span>Reserve Factor:</span>
                      <span>{selectedMarket.reserveFactor}%</span>
                    </div>
                  </div>
                  
                  <div className={styles.drawerDetailCard}>
                    <h4>Your Position</h4>
                    {selectedMarket.userSuppliedDebt || selectedMarket.userBorrowedDebt || selectedMarket.userCollateral ? (
                      <>
                        {selectedMarket.userSuppliedDebt && (
                          <div className={styles.drawerDetailRow}>
                            <span>Supplied (USDC):</span>
                            <span className={styles.positive}>{formatNumber(selectedMarket.userSuppliedDebt)}</span>
                          </div>
                        )}
                        {selectedMarket.userCollateral && (
                          <div className={styles.drawerDetailRow}>
                            <span>Collateral ({selectedMarket.collateral.symbol}):</span>
                            <span>{formatNumber(selectedMarket.userCollateral)}</span>
                          </div>
                        )}
                        {selectedMarket.userBorrowedDebt && (
                          <div className={styles.drawerDetailRow}>
                            <span>Borrowed (USDC):</span>
                            <span className={styles.negative}>{formatNumber(selectedMarket.userBorrowedDebt)}</span>
                          </div>
                        )}
                      </>
                    ) : (
                      <div className={styles.drawerEmptyPosition}>
                        <span>No active positions</span>
                        <span>Start by supplying USDC, depositing collateral, or borrowing USDC</span>
                      </div>
                    )}
                    
                    <div className={styles.drawerDetailRow}>
                      <span>Collateral Type:</span>
                      <span className={styles.contractAddress}>
                        {getTokenTypeTag(selectedMarket.collateral).slice(0, 20)}...
            </span>
                    </div>
                    <div className={styles.drawerDetailRow}>
                      <span>Debt Type:</span>
                      <span className={styles.contractAddress}>
                        {getTokenTypeTag(selectedMarket.debt).slice(0, 20)}...
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


