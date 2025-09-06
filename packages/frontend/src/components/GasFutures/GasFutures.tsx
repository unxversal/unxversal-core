import React, { useState } from 'react';
import { Fuel, BarChart3, Clock, DollarSign, TrendingUp, TrendingDown } from 'lucide-react';
import { TradingChart } from '../DEX/TradingChart';
import styles from './GasFutures.module.css';

interface GasContract {
  id: string;
  name: string;
  expiry: string;
  price: number;
  change24h: number;
  volume: number;
  openInterest: number;
}

export function GasFutures() {
  const [activeTab, setActiveTab] = useState<'buy' | 'sell'>('buy');
  const [selectedContract, setSelectedContract] = useState('gas-dec-2024');
  const [amount, setAmount] = useState('');
  const [price, setPrice] = useState('25.50');
  const [bottomTab, setBottomTab] = useState('positions');

  const [contracts] = useState<GasContract[]>([
    {
      id: 'gas-dec-2024',
      name: 'GAS-DEC24',
      expiry: 'Dec 31, 2024',
      price: 25.50,
      change24h: 2.1,
      volume: 125000,
      openInterest: 450000,
    },
    {
      id: 'gas-jan-2025',
      name: 'GAS-JAN25',
      expiry: 'Jan 31, 2025',
      price: 26.80,
      change24h: -1.5,
      volume: 89000,
      openInterest: 320000,
    },
    {
      id: 'gas-feb-2025',
      name: 'GAS-FEB25',
      expiry: 'Feb 28, 2025',
      price: 28.20,
      change24h: 0.8,
      volume: 67000,
      openInterest: 280000,
    },
  ]);

  const [gasMetrics] = useState({
    currentGasPrice: 23.45,
    gasChange24h: 1.8,
    avgBlockTime: 2.1,
    blockTimeChange: -0.2,
    networkUtilization: 78.5,
    utilizationChange: 3.2,
    baseFee: 15.2,
    baseFeeChange: -2.1,
  });

  const selectedContractData = contracts.find(c => c.id === selectedContract);

  const formatPrice = (price: number) => {
    return new Intl.NumberFormat('en-US', {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    }).format(price);
  };

  const formatVolume = (volume: number) => {
    if (volume >= 1000000) {
      return `${(volume / 1000000).toFixed(1)}M`;
    }
    if (volume >= 1000) {
      return `${(volume / 1000).toFixed(0)}K`;
    }
    return volume.toString();
  };

  const handleSubmitOrder = () => {
    console.log('Submit gas futures order:', { 
      contract: selectedContract, 
      side: activeTab, 
      amount, 
      price 
    });
  };

  return (
    <div className={styles.gasFuturesContainer}>
      {/* Title Bar */}
      <div className={styles.titleBar}>
        <div className={styles.pairInfo}>
          <Fuel size={24} style={{ color: '#00d4aa' }} />
          <div className={styles.pairName}>Gas Futures</div>
        </div>
        
        <div className={styles.priceInfo}>
          <div className={styles.priceItem}>
            <div className={styles.priceLabel}>Current Gas Price</div>
            <div className={`${styles.priceValue} ${gasMetrics.gasChange24h >= 0 ? styles.positive : styles.negative}`}>
              {formatPrice(gasMetrics.currentGasPrice)} Gwei
            </div>
          </div>
          
          <div className={styles.priceItem}>
            <div className={styles.priceLabel}>24h Change</div>
            <div className={`${styles.priceValue} ${gasMetrics.gasChange24h >= 0 ? styles.positive : styles.negative}`}>
              {gasMetrics.gasChange24h >= 0 ? '+' : ''}{gasMetrics.gasChange24h.toFixed(2)}%
            </div>
          </div>
          
          <div className={styles.priceItem}>
            <div className={styles.priceLabel}>Network Utilization</div>
            <div className={styles.priceValue}>{gasMetrics.networkUtilization.toFixed(1)}%</div>
          </div>
          
          <div className={styles.priceItem}>
            <div className={styles.priceLabel}>Base Fee</div>
            <div className={styles.priceValue}>{formatPrice(gasMetrics.baseFee)} Gwei</div>
          </div>
          
          <div className={styles.priceItem}>
            <div className={styles.priceLabel}>Avg Block Time</div>
            <div className={styles.priceValue}>{gasMetrics.avgBlockTime.toFixed(1)}s</div>
          </div>
        </div>
      </div>

      {/* Main Content */}
      <div className={styles.mainContent}>
        {/* Chart Section */}
        <div className={styles.chartSection}>
          <div className={styles.chartContainer}>
            <TradingChart />
          </div>
        </div>

        {/* Middle Section - Contracts */}
        <div className={styles.middleSection}>
          <div className={styles.contractsPanel}>
            <div className={styles.contractsTitle}>Gas Futures Contracts</div>
            <div className={styles.contractsList}>
              {contracts.map((contract) => (
                <div
                  key={contract.id}
                  className={`${styles.contractItem} ${selectedContract === contract.id ? styles.active : ''}`}
                  onClick={() => setSelectedContract(contract.id)}
                >
                  <div className={styles.contractInfo}>
                    <div className={styles.contractName}>{contract.name}</div>
                    <div className={styles.contractExpiry}>{contract.expiry}</div>
                  </div>
                  <div className={styles.contractPrice}>
                    <div className={styles.contractPriceValue}>
                      {formatPrice(contract.price)} Gwei
                    </div>
                    <div className={`${styles.contractChange} ${contract.change24h >= 0 ? styles.positive : styles.negative}`}>
                      {contract.change24h >= 0 ? '+' : ''}{contract.change24h.toFixed(2)}%
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* Right Section */}
        <div className={styles.rightSection}>
          {/* Trading Panel */}
          <div className={styles.tradingPanel}>
            <div className={styles.tradingTabs}>
              <button
                className={`${styles.tradingTab} ${styles.buy} ${activeTab === 'buy' ? styles.active : ''}`}
                onClick={() => setActiveTab('buy')}
              >
                Long
              </button>
              <button
                className={`${styles.tradingTab} ${styles.sell} ${activeTab === 'sell' ? styles.active : ''}`}
                onClick={() => setActiveTab('sell')}
              >
                Short
              </button>
            </div>

            <div className={styles.tradingForm}>
              <div className={styles.formGroup}>
                <label className={styles.formLabel}>Contract</label>
                <div style={{ color: '#ffffff', fontWeight: '600' }}>
                  {selectedContractData?.name || 'Select Contract'}
                </div>
              </div>

              <div className={styles.formGroup}>
                <label className={styles.formLabel}>Price (Gwei)</label>
                <input
                  type="text"
                  className={styles.formInput}
                  value={price}
                  onChange={(e) => setPrice(e.target.value)}
                  placeholder="0.00"
                />
              </div>

              <div className={styles.formGroup}>
                <label className={styles.formLabel}>Amount (Contracts)</label>
                <input
                  type="text"
                  className={styles.formInput}
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                  placeholder="0"
                />
              </div>

              <button
                className={`${styles.submitButton} ${activeTab === 'buy' ? styles.buy : styles.sell}`}
                onClick={handleSubmitOrder}
              >
                {activeTab === 'buy' ? 'Long' : 'Short'} Gas
              </button>
            </div>
          </div>

          {/* Position Info */}
          <div className={styles.positionInfo}>
            <div className={styles.positionTitle}>Position Info</div>
            <div className={styles.positionItem}>
              <div className={styles.positionLabel}>Available Balance</div>
              <div className={styles.positionValue}>$0.00</div>
            </div>
            <div className={styles.positionItem}>
              <div className={styles.positionLabel}>Margin Required</div>
              <div className={styles.positionValue}>$0.00</div>
            </div>
            <div className={styles.positionItem}>
              <div className={styles.positionLabel}>Est. Liquidation</div>
              <div className={styles.positionValue}>--</div>
            </div>
          </div>
        </div>
      </div>

      {/* Bottom Section */}
      <div className={styles.bottomSection}>
        <div className={styles.bottomPanel}>
          <div className={styles.tabContainer}>
            <div className={styles.tabHeaders}>
              <button
                className={`${styles.tabHeader} ${bottomTab === 'positions' ? styles.active : ''}`}
                onClick={() => setBottomTab('positions')}
              >
                Positions
              </button>
              <button
                className={`${styles.tabHeader} ${bottomTab === 'orders' ? styles.active : ''}`}
                onClick={() => setBottomTab('orders')}
              >
                Open Orders
              </button>
              <button
                className={`${styles.tabHeader} ${bottomTab === 'history' ? styles.active : ''}`}
                onClick={() => setBottomTab('history')}
              >
                Order History
              </button>
            </div>
            
            <div className={styles.tabContent}>
              {bottomTab === 'positions' && (
                <div className={styles.emptyState}>
                  <BarChart3 className={styles.emptyStateIcon} size={48} />
                  <div>No open positions</div>
                </div>
              )}
              {bottomTab === 'orders' && (
                <div className={styles.emptyState}>
                  <Clock className={styles.emptyStateIcon} size={48} />
                  <div>No open orders</div>
                </div>
              )}
              {bottomTab === 'history' && (
                <div className={styles.emptyState}>
                  <DollarSign className={styles.emptyStateIcon} size={48} />
                  <div>No order history</div>
                </div>
              )}
            </div>
          </div>
        </div>

        <div className={styles.bottomPanel}>
          <div className={styles.panelTitle}>Gas Metrics</div>
          <div className={styles.gasMetrics}>
            <div className={styles.metricCard}>
              <div className={styles.metricLabel}>Current Gas</div>
              <div className={styles.metricValue}>{formatPrice(gasMetrics.currentGasPrice)}</div>
              <div className={`${styles.metricChange} ${gasMetrics.gasChange24h >= 0 ? styles.positive : styles.negative}`}>
                {gasMetrics.gasChange24h >= 0 ? <TrendingUp size={14} /> : <TrendingDown size={14} />}
                {Math.abs(gasMetrics.gasChange24h).toFixed(1)}%
              </div>
            </div>
            
            <div className={styles.metricCard}>
              <div className={styles.metricLabel}>Network Usage</div>
              <div className={styles.metricValue}>{gasMetrics.networkUtilization.toFixed(1)}%</div>
              <div className={`${styles.metricChange} ${gasMetrics.utilizationChange >= 0 ? styles.positive : styles.negative}`}>
                {gasMetrics.utilizationChange >= 0 ? <TrendingUp size={14} /> : <TrendingDown size={14} />}
                {Math.abs(gasMetrics.utilizationChange).toFixed(1)}%
              </div>
            </div>
            
            <div className={styles.metricCard}>
              <div className={styles.metricLabel}>Base Fee</div>
              <div className={styles.metricValue}>{formatPrice(gasMetrics.baseFee)}</div>
              <div className={`${styles.metricChange} ${gasMetrics.baseFeeChange >= 0 ? styles.positive : styles.negative}`}>
                {gasMetrics.baseFeeChange >= 0 ? <TrendingUp size={14} /> : <TrendingDown size={14} />}
                {Math.abs(gasMetrics.baseFeeChange).toFixed(1)}%
              </div>
            </div>
            
            <div className={styles.metricCard}>
              <div className={styles.metricLabel}>Block Time</div>
              <div className={styles.metricValue}>{gasMetrics.avgBlockTime.toFixed(1)}s</div>
              <div className={`${styles.metricChange} ${gasMetrics.blockTimeChange >= 0 ? styles.positive : styles.negative}`}>
                {gasMetrics.blockTimeChange >= 0 ? <TrendingUp size={14} /> : <TrendingDown size={14} />}
                {Math.abs(gasMetrics.blockTimeChange).toFixed(1)}%
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
