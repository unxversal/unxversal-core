import React, { useState, useEffect } from 'react';
import { TrendingUp, TrendingDown, BarChart3, Clock, DollarSign } from 'lucide-react';
import { TradingChart } from './TradingChart';
import styles from './DEX.module.css';

interface OrderbookEntry {
  price: number;
  size: number;
  total: number;
}

interface Trade {
  id: string;
  price: number;
  size: number;
  side: 'buy' | 'sell';
  time: number;
}

export function DEX() {
  const [activeTab, setActiveTab] = useState<'buy' | 'sell'>('buy');
  const [orderType, setOrderType] = useState<'market' | 'limit'>('limit');
  const [price, setPrice] = useState('110,850');
  const [amount, setAmount] = useState('');
  const [bottomTab, setBottomTab] = useState('orders');
  
  // Mock data
  const [marketData] = useState({
    pair: 'BTC-USDC',
    price: 110850,
    change24h: 2.34,
    high24h: 112500,
    low24h: 108200,
    volume24h: 4720000,
  });

  const [orderbook] = useState({
    bids: [
      { price: 110849, size: 0.5234, total: 0.5234 },
      { price: 110848, size: 1.2456, total: 1.7690 },
      { price: 110847, size: 0.8901, total: 2.6591 },
      { price: 110846, size: 2.1234, total: 4.7825 },
      { price: 110845, size: 0.6789, total: 5.4614 },
    ] as OrderbookEntry[],
    asks: [
      { price: 110851, size: 0.4567, total: 0.4567 },
      { price: 110852, size: 1.1234, total: 1.5801 },
      { price: 110853, size: 0.7890, total: 2.3691 },
      { price: 110854, size: 1.9876, total: 4.3567 },
      { price: 110855, size: 0.5432, total: 4.8999 },
    ] as OrderbookEntry[],
  });

  const [trades] = useState([
    { id: '1', price: 110850, size: 0.1234, side: 'buy' as const, time: Date.now() - 1000 },
    { id: '2', price: 110849, size: 0.5678, side: 'sell' as const, time: Date.now() - 2000 },
    { id: '3', price: 110851, size: 0.2345, side: 'buy' as const, time: Date.now() - 3000 },
  ] as Trade[]);

  const [balances] = useState([
    { asset: 'BTC', amount: '0.00', usd: '$0.00' },
    { asset: 'USDC', amount: '0.00', usd: '$0.00' },
  ]);

  const spread = orderbook.asks[0]?.price - orderbook.bids[0]?.price || 0;
  const spreadPercent = ((spread / orderbook.bids[0]?.price) * 100) || 0;

  const formatPrice = (price: number) => {
    return new Intl.NumberFormat('en-US', {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    }).format(price);
  };

  const formatTime = (timestamp: number) => {
    return new Date(timestamp).toLocaleTimeString();
  };

  const handleSubmitOrder = () => {
    console.log('Submit order:', { activeTab, orderType, price, amount });
  };

  return (
    <div className={styles.dexContainer}>
      {/* Title Bar */}
      <div className={styles.titleBar}>
        <div className={styles.pairInfo}>
          <div className={styles.pairName}>{marketData.pair}</div>
        </div>
        
        <div className={styles.priceInfo}>
          <div className={styles.priceItem}>
            <div className={styles.priceLabel}>Price</div>
            <div className={`${styles.priceValue} ${marketData.change24h >= 0 ? styles.positive : styles.negative}`}>
              ${formatPrice(marketData.price)}
            </div>
          </div>
          
          <div className={styles.priceItem}>
            <div className={styles.priceLabel}>24h Change</div>
            <div className={`${styles.priceValue} ${marketData.change24h >= 0 ? styles.positive : styles.negative}`}>
              {marketData.change24h >= 0 ? '+' : ''}{marketData.change24h.toFixed(2)}%
            </div>
          </div>
          
          <div className={styles.priceItem}>
            <div className={styles.priceLabel}>24h High</div>
            <div className={styles.priceValue}>${formatPrice(marketData.high24h)}</div>
          </div>
          
          <div className={styles.priceItem}>
            <div className={styles.priceLabel}>24h Low</div>
            <div className={styles.priceValue}>${formatPrice(marketData.low24h)}</div>
          </div>
          
          <div className={styles.priceItem}>
            <div className={styles.priceLabel}>24h Volume</div>
            <div className={styles.priceValue}>${(marketData.volume24h / 1000000).toFixed(2)}M</div>
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

        {/* Middle Section - Orderbook */}
        <div className={styles.middleSection}>
          <div className={styles.orderbookContainer}>
            <div className={styles.orderbookHeader}>
              <div className={styles.orderbookTitle}>Order Book</div>
              <div className={styles.spreadInfo}>
                Spread: {spreadPercent.toFixed(3)}%
              </div>
            </div>
            
            <div className={styles.orderbookContent}>
              {/* Asks */}
              {[...orderbook.asks].reverse().map((ask, index) => (
                <div key={`ask-${index}`} className={`${styles.orderRow} ${styles.ask}`}>
                  <div>{formatPrice(ask.price)}</div>
                  <div>{ask.size.toFixed(4)}</div>
                  <div>{ask.total.toFixed(4)}</div>
                </div>
              ))}
              
              {/* Spread */}
              <div style={{ padding: '0.5rem 0', textAlign: 'center', color: '#888', fontSize: '0.75rem' }}>
                Spread: ${spread.toFixed(2)}
              </div>
              
              {/* Bids */}
              {orderbook.bids.map((bid, index) => (
                <div key={`bid-${index}`} className={`${styles.orderRow} ${styles.bid}`}>
                  <div>{formatPrice(bid.price)}</div>
                  <div>{bid.size.toFixed(4)}</div>
                  <div>{bid.total.toFixed(4)}</div>
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* Right Section */}
        <div className={styles.rightSection}>
          {/* Wallet Balance */}
          <div className={styles.walletBalance}>
            <div className={styles.balanceTitle}>Wallet Balance</div>
            {balances.map((balance) => (
              <div key={balance.asset} className={styles.balanceItem}>
                <div className={styles.balanceAsset}>{balance.asset}</div>
                <div className={styles.balanceAmount}>
                  {balance.amount} <span style={{ color: '#666' }}>({balance.usd})</span>
                </div>
              </div>
            ))}
          </div>

          {/* Trading Panel */}
          <div className={styles.tradingPanel}>
            <div className={styles.tradingTabs}>
              <button
                className={`${styles.tradingTab} ${styles.buy} ${activeTab === 'buy' ? styles.active : ''}`}
                onClick={() => setActiveTab('buy')}
              >
                Buy
              </button>
              <button
                className={`${styles.tradingTab} ${styles.sell} ${activeTab === 'sell' ? styles.active : ''}`}
                onClick={() => setActiveTab('sell')}
              >
                Sell
              </button>
            </div>

            <div className={styles.tradingForm}>
              <div className={styles.formGroup}>
                <label className={styles.formLabel}>Order Type</label>
                <select
                  className={styles.orderTypeSelect}
                  value={orderType}
                  onChange={(e) => setOrderType(e.target.value as 'market' | 'limit')}
                >
                  <option value="limit">Limit</option>
                  <option value="market">Market</option>
                </select>
              </div>

              {orderType === 'limit' && (
                <div className={styles.formGroup}>
                  <label className={styles.formLabel}>Price (USDC)</label>
                  <input
                    type="text"
                    className={styles.formInput}
                    value={price}
                    onChange={(e) => setPrice(e.target.value)}
                    placeholder="0.00"
                  />
                </div>
              )}

              <div className={styles.formGroup}>
                <label className={styles.formLabel}>Amount (BTC)</label>
                <input
                  type="text"
                  className={styles.formInput}
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                  placeholder="0.00"
                />
              </div>

              <button
                className={`${styles.submitButton} ${activeTab === 'buy' ? styles.buy : styles.sell}`}
                onClick={handleSubmitOrder}
              >
                {activeTab === 'buy' ? 'Buy' : 'Sell'} BTC
              </button>
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
              <button
                className={`${styles.tabHeader} ${bottomTab === 'trades' ? styles.active : ''}`}
                onClick={() => setBottomTab('trades')}
              >
                Trade History
              </button>
            </div>
            
            <div className={styles.tabContent}>
              {bottomTab === 'orders' && (
                <div className={styles.emptyState}>
                  <BarChart3 className={styles.emptyStateIcon} size={48} />
                  <div>No open orders</div>
                </div>
              )}
              {bottomTab === 'history' && (
                <div className={styles.emptyState}>
                  <Clock className={styles.emptyStateIcon} size={48} />
                  <div>No order history</div>
                </div>
              )}
              {bottomTab === 'trades' && (
                <div className={styles.emptyState}>
                  <DollarSign className={styles.emptyStateIcon} size={48} />
                  <div>No trade history</div>
                </div>
              )}
            </div>
          </div>
        </div>

        <div className={styles.bottomPanel}>
          <div className={styles.panelTitle}>Recent Trades</div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: '0.5rem' }}>
            {trades.map((trade) => (
              <div key={trade.id} style={{ display: 'flex', justifyContent: 'space-between', fontSize: '0.875rem' }}>
                <span style={{ color: trade.side === 'buy' ? '#00d4aa' : '#ff6b6b' }}>
                  {formatPrice(trade.price)}
                </span>
                <span style={{ color: '#888' }}>{trade.size.toFixed(4)}</span>
                <span style={{ color: '#666' }}>{formatTime(trade.time)}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
