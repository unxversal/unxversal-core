import { useMemo } from 'react';
import styles from '../../components/lending/LendingScreen.module.css';
import { TrendingUp, TrendingDown, Percent, AlertCircle } from 'lucide-react';
import type { LendingComponentProps, LendingMarketSummary } from './types';

function formatNumber(num: number, decimals: number = 2) {
  if (num === Infinity) return '∞';
  if (num >= 1_000_000_000) return `${(num / 1_000_000_000).toFixed(1)}B`;
  if (num >= 1_000_000) return `${(num / 1_000_000).toFixed(1)}M`;
  if (num >= 1_000) return `${(num / 1_000).toFixed(1)}K`;
  return num.toFixed(decimals);
}

function getUtilizationColor(rate: number) {
  if (rate < 60) return '#10b981';
  if (rate < 80) return '#f59e0b';
  return '#ef4444';
}

export function LendingComponent(props: LendingComponentProps) {
  const {
    address,
    network,
    protocolStatus,
    tvlUsd = 0,
    activeUsers = 0,
    markets,
    viewMode,
    selectedMarketId,
    isDrawerOpen,
    drawerMode,
    inputAmount,
    userBalance,
    submitting,
    onChangeViewMode,
    onSelectMarket,
    onOpenDrawer,
    onCloseDrawer,
    onChangeDrawerMode,
    onChangeInputAmount,
    onSupplyDebt,
    onDepositCollateral,
    onBorrowDebt,
    renderConnect,
  } = props;

  const selectedMarket: LendingMarketSummary | undefined = useMemo(() => {
    if (!selectedMarketId) return undefined;
    return markets.find((m) => m.id === selectedMarketId);
  }, [selectedMarketId, markets]);

  async function handleSubmit() {
    if (!selectedMarket || inputAmount <= 0) return;
    if (drawerMode === 'supplyDebt') {
      await onSupplyDebt({ marketId: selectedMarket.id, amount: inputAmount });
      return;
    }
    if (drawerMode === 'depositCollat') {
      await onDepositCollateral({ marketId: selectedMarket.id, amount: inputAmount });
      return;
    }
    if (drawerMode === 'borrowDebt') {
      await onBorrowDebt({ marketId: selectedMarket.id, amount: inputAmount });
      return;
    }
  }

  const portfolioStats = useMemo(() => {
    const totalSupplied = markets.reduce((sum, m) => sum + (m.userSuppliedDebt || 0), 0);
    const totalBorrowed = markets.reduce((sum, m) => sum + (m.userBorrowedDebt || 0), 0);
    const netApyAbs = markets.reduce((sum, m) => {
      const supplyValue = (m.userSuppliedDebt || 0) * m.supplyApy / 100;
      const borrowValue = (m.userBorrowedDebt || 0) * m.borrowApy / 100;
      return sum + supplyValue - borrowValue;
    }, 0);
    return {
      totalSupplied,
      totalBorrowed,
      netApy: totalSupplied > 0 ? (netApyAbs / totalSupplied) * 100 : 0,
      healthFactor: totalBorrowed > 0 ? (totalSupplied * 0.8) / totalBorrowed : Infinity,
    };
  }, [markets]);

  const applyPercent = (pct: number) => {
    onChangeInputAmount(userBalance * pct);
  };

  return (
    <div className={styles.root}>
      <div className={styles.header}>
        <div className={styles.pairBar}>
          <div className={styles.pair}>
            <span>Unxversal Lending</span>
          </div>
          <div className={styles.metrics}>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>${formatNumber(tvlUsd)}</div>
              <div className={styles.metricLabel}>TVL</div>
            </div>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>{formatNumber(activeUsers, 0)}</div>
              <div className={styles.metricLabel}>Active Users</div>
            </div>
            <div className={styles.viewToggle}>
              <button className={viewMode === 'markets' ? styles.active : ''} onClick={() => onChangeViewMode('markets')}>Markets</button>
              <button className={viewMode === 'portfolio' ? styles.active : ''} onClick={() => onChangeViewMode('portfolio')}>Portfolio</button>
            </div>
          </div>
        </div>
      </div>

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
                {portfolioStats.healthFactor === Infinity ? '∞' : portfolioStats.healthFactor.toFixed(2)}
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
            {markets.length === 0 ? (
              <div className={styles.emptyState}>
                <p>No lending pools available.</p>
              </div>
            ) : (
              markets.map((mkt) => (
                <div
                  key={mkt.id}
                  className={`${styles.tableRow} ${selectedMarketId === mkt.id ? styles.selected : ''}`}
                  onClick={() => { onSelectMarket(mkt.id); onOpenDrawer(); }}
                >
                  <div className={styles.assetCell}>
                    {mkt.collateral.iconUrl && (
                      <img src={mkt.collateral.iconUrl} alt={mkt.collateral.name} className={styles.tokenIcon} />
                    )}
                    <div>
                      <div className={styles.tokenSymbol}>{mkt.symbolPair}</div>
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
                    <button className={styles.supplyBtn} onClick={(e) => { e.stopPropagation(); onSelectMarket(mkt.id); onOpenDrawer(); onChangeDrawerMode('supplyDebt'); }}>Supply USDC</button>
                    <button className={styles.supplyBtn} onClick={(e) => { e.stopPropagation(); onSelectMarket(mkt.id); onOpenDrawer(); onChangeDrawerMode('depositCollat'); }}>Deposit {mkt.collateral.symbol}</button>
                    <button className={styles.borrowBtn} onClick={(e) => { e.stopPropagation(); onSelectMarket(mkt.id); onOpenDrawer(); onChangeDrawerMode('borrowDebt'); }}>Borrow USDC</button>
                  </div>
                </div>
              ))
            )}
          </div>
        </div>
      </div>

      <div className={`${styles.drawer} ${isDrawerOpen ? styles.drawerOpen : ''}`}>
        <div className={styles.drawerOverlay} onClick={onCloseDrawer} />
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
                <button onClick={onCloseDrawer} className={styles.drawerCloseBtn}>×</button>
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
                    <button className={drawerMode === 'supplyDebt' ? styles.active : ''} onClick={() => onChangeDrawerMode('supplyDebt')}>Supply USDC</button>
                    <button className={drawerMode === 'depositCollat' ? styles.active : ''} onClick={() => onChangeDrawerMode('depositCollat')}>Deposit {selectedMarket.collateral.symbol}</button>
                    <button className={drawerMode === 'borrowDebt' ? styles.active : ''} onClick={() => onChangeDrawerMode('borrowDebt')}>Borrow USDC</button>
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
                        onChange={(e) => onChangeInputAmount(Number(e.target.value))}
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
                          <span className={
                            selectedMarket.userHealthFactor != null
                              ? (selectedMarket.userHealthFactor > 2
                                  ? styles.positive
                                  : selectedMarket.userHealthFactor > 1.2
                                    ? styles.warning
                                    : styles.negative)
                              : styles.warning
                          }>
                            {selectedMarket.userHealthFactor != null
                              ? selectedMarket.userHealthFactor.toFixed(2)
                              : '—'}
                          </span>
                        </div>
                      )}
                    </div>

                    {!address ? (
                      <div className={styles.connectWallet}>
                        {renderConnect}
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
                        {selectedMarket.collateral.typeTag.slice(0, 20)}...
                      </span>
                    </div>
                    <div className={styles.drawerDetailRow}>
                      <span>Debt Type:</span>
                      <span className={styles.contractAddress}>
                        {selectedMarket.debt.typeTag.slice(0, 20)}...
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            </>
          )}
        </div>
      </div>

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

export default LendingComponent;


