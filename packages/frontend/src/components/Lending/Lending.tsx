import React, { useState } from 'react';
import { Banknote, TrendingUp, TrendingDown, Wallet, PiggyBank } from 'lucide-react';
import styles from './Lending.module.css';

interface LendingAsset {
  id: string;
  name: string;
  symbol: string;
  supplyApy: number;
  borrowApy: number;
  totalSupply: number;
  totalBorrow: number;
  utilization: number;
  liquidity: number;
}

interface Position {
  asset: string;
  symbol: string;
  type: 'supply' | 'borrow';
  amount: number;
  value: number;
  apy: number;
}

export function Lending() {
  const [activeMarketTab, setActiveMarketTab] = useState<'all' | 'supply' | 'borrow'>('all');
  const [activeActionTab, setActiveActionTab] = useState<'supply' | 'borrow'>('supply');
  const [selectedAsset, setSelectedAsset] = useState('usdc');
  const [amount, setAmount] = useState('');

  const [assets] = useState<LendingAsset[]>([
    {
      id: 'usdc',
      name: 'USD Coin',
      symbol: 'USDC',
      supplyApy: 4.25,
      borrowApy: 6.80,
      totalSupply: 125000000,
      totalBorrow: 89000000,
      utilization: 71.2,
      liquidity: 36000000,
    },
    {
      id: 'eth',
      name: 'Ethereum',
      symbol: 'ETH',
      supplyApy: 3.15,
      borrowApy: 5.45,
      totalSupply: 45000,
      totalBorrow: 32000,
      utilization: 71.1,
      liquidity: 13000,
    },
    {
      id: 'btc',
      name: 'Bitcoin',
      symbol: 'BTC',
      supplyApy: 2.85,
      borrowApy: 4.95,
      totalSupply: 2500,
      totalBorrow: 1800,
      utilization: 72.0,
      liquidity: 700,
    },
    {
      id: 'sol',
      name: 'Solana',
      symbol: 'SOL',
      supplyApy: 5.60,
      borrowApy: 8.20,
      totalSupply: 8500000,
      totalBorrow: 5200000,
      utilization: 61.2,
      liquidity: 3300000,
    },
  ]);

  const [positions] = useState<Position[]>([
    {
      asset: 'USD Coin',
      symbol: 'USDC',
      type: 'supply',
      amount: 10000,
      value: 10000,
      apy: 4.25,
    },
    {
      asset: 'Ethereum',
      symbol: 'ETH',
      type: 'borrow',
      amount: 2.5,
      value: 8750,
      apy: 5.45,
    },
  ]);

  const [marketStats] = useState({
    totalSupply: 2450000000,
    totalBorrow: 1680000000,
    totalLiquidity: 770000000,
    avgSupplyApy: 3.96,
    avgBorrowApy: 6.35,
  });

  const selectedAssetData = assets.find(a => a.id === selectedAsset);
  const filteredAssets = assets.filter(asset => {
    if (activeMarketTab === 'supply') return asset.supplyApy > 0;
    if (activeMarketTab === 'borrow') return asset.borrowApy > 0;
    return true;
  });

  const totalSupplyValue = positions
    .filter(p => p.type === 'supply')
    .reduce((sum, p) => sum + p.value, 0);

  const totalBorrowValue = positions
    .filter(p => p.type === 'borrow')
    .reduce((sum, p) => sum + p.value, 0);

  const netWorth = totalSupplyValue - totalBorrowValue;
  const healthFactor = totalSupplyValue > 0 ? (totalSupplyValue * 0.8) / totalBorrowValue : 0;

  const formatCurrency = (amount: number, symbol?: string) => {
    if (symbol && symbol !== 'USDC') {
      return `${amount.toLocaleString()} ${symbol}`;
    }
    return new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: 'USD',
      minimumFractionDigits: 0,
      maximumFractionDigits: 0,
    }).format(amount);
  };

  const formatPercent = (percent: number) => {
    return `${percent.toFixed(2)}%`;
  };

  const handleSubmitAction = () => {
    console.log('Submit lending action:', {
      action: activeActionTab,
      asset: selectedAsset,
      amount,
    });
  };

  return (
    <div className={styles.lendingContainer}>
      {/* Title Bar */}
      <div className={styles.titleBar}>
        <div className={styles.titleInfo}>
          <Banknote size={24} style={{ color: '#00d4aa' }} />
          <div className={styles.titleName}>Lending Markets</div>
        </div>
        
        <div className={styles.marketStats}>
          <div className={styles.statItem}>
            <div className={styles.statLabel}>Total Supply</div>
            <div className={styles.statValue}>
              {formatCurrency(marketStats.totalSupply)}
            </div>
          </div>
          
          <div className={styles.statItem}>
            <div className={styles.statLabel}>Total Borrow</div>
            <div className={styles.statValue}>
              {formatCurrency(marketStats.totalBorrow)}
            </div>
          </div>
          
          <div className={styles.statItem}>
            <div className={styles.statLabel}>Available Liquidity</div>
            <div className={styles.statValue}>
              {formatCurrency(marketStats.totalLiquidity)}
            </div>
          </div>
          
          <div className={styles.statItem}>
            <div className={styles.statLabel}>Avg Supply APY</div>
            <div className={`${styles.statValue} ${styles.positive}`}>
              {formatPercent(marketStats.avgSupplyApy)}
            </div>
          </div>
          
          <div className={styles.statItem}>
            <div className={styles.statLabel}>Avg Borrow APY</div>
            <div className={styles.statValue}>
              {formatPercent(marketStats.avgBorrowApy)}
            </div>
          </div>
        </div>
      </div>

      {/* Main Content */}
      <div className={styles.mainContent}>
        {/* Markets Section */}
        <div className={styles.marketsSection}>
          <div className={styles.marketsHeader}>
            <div className={styles.marketsTitle}>Markets</div>
            <div className={styles.marketsTabs}>
              <button
                className={`${styles.marketTab} ${activeMarketTab === 'all' ? styles.active : ''}`}
                onClick={() => setActiveMarketTab('all')}
              >
                All Markets
              </button>
              <button
                className={`${styles.marketTab} ${activeMarketTab === 'supply' ? styles.active : ''}`}
                onClick={() => setActiveMarketTab('supply')}
              >
                Supply
              </button>
              <button
                className={`${styles.marketTab} ${activeMarketTab === 'borrow' ? styles.active : ''}`}
                onClick={() => setActiveMarketTab('borrow')}
              >
                Borrow
              </button>
            </div>
          </div>

          <div className={styles.marketsTable}>
            <div className={styles.tableHeader}>
              <div>Asset</div>
              <div>Supply APY</div>
              <div>Borrow APY</div>
              <div>Total Supply</div>
              <div>Total Borrow</div>
              <div>Utilization</div>
            </div>

            {filteredAssets.map((asset) => (
              <div
                key={asset.id}
                className={`${styles.tableRow} ${selectedAsset === asset.id ? styles.selected : ''}`}
                onClick={() => setSelectedAsset(asset.id)}
              >
                <div className={styles.assetInfo}>
                  <div className={styles.assetIcon}>
                    {asset.symbol.slice(0, 2)}
                  </div>
                  <div className={styles.assetDetails}>
                    <div className={styles.assetName}>{asset.name}</div>
                    <div className={styles.assetSymbol}>{asset.symbol}</div>
                  </div>
                </div>
                
                <div className={`${styles.tableCell} ${styles.positive}`}>
                  {formatPercent(asset.supplyApy)}
                </div>
                
                <div className={styles.tableCell}>
                  {formatPercent(asset.borrowApy)}
                </div>
                
                <div className={styles.tableCell}>
                  {formatCurrency(asset.totalSupply, asset.symbol)}
                </div>
                
                <div className={styles.tableCell}>
                  {formatCurrency(asset.totalBorrow, asset.symbol)}
                </div>
                
                <div className={styles.tableCell}>
                  {formatPercent(asset.utilization)}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Right Section */}
        <div className={styles.rightSection}>
          {/* Action Panel */}
          <div className={styles.actionPanel}>
            <div className={styles.actionTabs}>
              <button
                className={`${styles.actionTab} ${activeActionTab === 'supply' ? styles.active : ''}`}
                onClick={() => setActiveActionTab('supply')}
              >
                Supply
              </button>
              <button
                className={`${styles.actionTab} ${activeActionTab === 'borrow' ? styles.active : ''}`}
                onClick={() => setActiveActionTab('borrow')}
              >
                Borrow
              </button>
            </div>

            <div className={styles.actionForm}>
              <div className={styles.formGroup}>
                <label className={styles.formLabel}>Asset</label>
                <select
                  className={styles.assetSelect}
                  value={selectedAsset}
                  onChange={(e) => setSelectedAsset(e.target.value)}
                >
                  {assets.map((asset) => (
                    <option key={asset.id} value={asset.id}>
                      {asset.name} ({asset.symbol})
                    </option>
                  ))}
                </select>
              </div>

              <div className={styles.formGroup}>
                <label className={styles.formLabel}>
                  Amount ({selectedAssetData?.symbol})
                </label>
                <input
                  type="text"
                  className={styles.formInput}
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                  placeholder="0.00"
                />
              </div>

              {selectedAssetData && (
                <div className={styles.formGroup}>
                  <label className={styles.formLabel}>
                    {activeActionTab === 'supply' ? 'Supply' : 'Borrow'} APY
                  </label>
                  <div style={{ color: '#00d4aa', fontWeight: '600', fontSize: '1.1rem' }}>
                    {formatPercent(
                      activeActionTab === 'supply' 
                        ? selectedAssetData.supplyApy 
                        : selectedAssetData.borrowApy
                    )}
                  </div>
                </div>
              )}

              <button
                className={styles.submitButton}
                onClick={handleSubmitAction}
                disabled={!amount || !selectedAssetData}
              >
                {activeActionTab === 'supply' ? 'Supply' : 'Borrow'} {selectedAssetData?.symbol}
              </button>
            </div>
          </div>

          {/* Portfolio Panel */}
          <div className={styles.portfolioPanel}>
            <div className={styles.portfolioTitle}>Your Portfolio</div>
            
            <div className={styles.portfolioStats}>
              <div className={styles.portfolioStat}>
                <div className={styles.portfolioStatLabel}>Net Worth</div>
                <div className={`${styles.portfolioStatValue} ${netWorth >= 0 ? styles.positive : styles.negative}`}>
                  {formatCurrency(netWorth)}
                </div>
              </div>
              
              <div className={styles.portfolioStat}>
                <div className={styles.portfolioStatLabel}>Total Supply</div>
                <div className={styles.portfolioStatValue}>
                  {formatCurrency(totalSupplyValue)}
                </div>
              </div>
              
              <div className={styles.portfolioStat}>
                <div className={styles.portfolioStatLabel}>Total Borrow</div>
                <div className={styles.portfolioStatValue}>
                  {formatCurrency(totalBorrowValue)}
                </div>
              </div>
              
              <div className={styles.portfolioStat}>
                <div className={styles.portfolioStatLabel}>Health Factor</div>
                <div className={`${styles.portfolioStatValue} ${healthFactor > 1.5 ? styles.positive : healthFactor > 1.1 ? '' : styles.negative}`}>
                  {healthFactor > 0 ? healthFactor.toFixed(2) : '--'}
                </div>
              </div>
            </div>

            <div className={styles.portfolioPositions}>
              {positions.length > 0 ? (
                positions.map((position, index) => (
                  <div key={index} className={styles.positionItem}>
                    <div className={styles.positionAsset}>
                      <div className={styles.positionAssetIcon}>
                        {position.symbol.slice(0, 2)}
                      </div>
                      <div>
                        <div style={{ color: '#ffffff', fontWeight: '600' }}>
                          {position.asset}
                        </div>
                        <div style={{ fontSize: '0.75rem', color: '#888' }}>
                          {position.type === 'supply' ? 'Supplying' : 'Borrowing'}
                        </div>
                      </div>
                    </div>
                    
                    <div className={styles.positionInfo}>
                      <div className={styles.positionAmount}>
                        {formatCurrency(position.amount, position.symbol)}
                      </div>
                      <div className={styles.positionValue}>
                        {formatPercent(position.apy)} APY
                      </div>
                    </div>
                  </div>
                ))
              ) : (
                <div className={styles.emptyState}>
                  <PiggyBank className={styles.emptyStateIcon} size={48} />
                  <div>No positions yet</div>
                  <div style={{ fontSize: '0.875rem', marginTop: '0.5rem' }}>
                    Supply or borrow assets to get started
                  </div>
                </div>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
