import { useEffect, useState } from 'react';
import styles from './OptionsTradePanel.module.css';
import { X, ChevronLeft } from 'lucide-react';

export function OptionsTradePanel({ 
  baseSymbol, 
  quoteSymbol, 
  mid, 
  provider,
  selectedStrike,
  selectedIsCall,
  selectedPrice,
  onClose,
  showBackButton = false
}: { 
  baseSymbol: string; 
  quoteSymbol: string; 
  mid: number; 
  provider?: any;
  selectedStrike?: number;
  selectedIsCall?: boolean;
  selectedPrice?: number;
  onClose?: () => void;
  showBackButton?: boolean;
}) {
  const [side, setSide] = useState<'call' | 'put'>('call');
  const [action, setAction] = useState<'buy' | 'sell'>('buy');
  // Options are limit-only on-chain; UI uses limit exclusively
  const [size, setSize] = useState<number>(1);
  const [price, setPrice] = useState<number>(Number(mid?.toFixed(3) || '1'));
  const [strike, setStrike] = useState<number>(Number(mid?.toFixed(2) || '1'));
  const [expiry, setExpiry] = useState<string>('next');
  const [feeType, setFeeType] = useState<'input' | 'unxv'>('input');

  useEffect(() => {
    if (selectedStrike) setStrike(selectedStrike);
    if (selectedIsCall !== undefined) setSide(selectedIsCall ? 'call' : 'put');
    if (selectedPrice) setPrice(selectedPrice);
  }, [selectedStrike, selectedIsCall, selectedPrice]);

  useEffect(() => {
    if (!mid) return;
    if (!selectedPrice) setPrice(Number((mid * 0.1).toFixed(3)));
    if (!selectedStrike) setStrike(Number(mid.toFixed(2)));
  }, [mid, selectedPrice, selectedStrike]);

  // Fee calculations
  const notionalValue = size * price;
  const tradingFee = notionalValue * 0.001; // 0.1% fee
  const feeUnxvDisc = tradingFee * 0.7; // 30% discount with UNXV

  return (
    <div className={styles.root}>
      <div className={styles.header}>
        {showBackButton && onClose && (
          <button className={styles.backButton} onClick={onClose}>
            <ChevronLeft size={16} />
          </button>
        )}
        <div className={styles.title}>Trade Options</div>
        {!showBackButton && onClose && (
          <button className={styles.closeButton} onClick={onClose}>
            <X size={16} />
          </button>
        )}
      </div>

      {/* Order Card */}
      <div className={styles.orderCard}>
        <div className={styles.orderHeader}>
          {/* Removed Market/Limit toggle; options are limit-only */}
          
          <div className={styles.tabs}>
            <button className={action==='buy'?styles.active:''} onClick={()=>setAction('buy')}>Buy</button>
            <button className={action==='sell'?styles.active:''} onClick={()=>setAction('sell')}>Sell</button>
          </div>
        </div>

        <div className={styles.contentArea}>
          <div className={styles.optionTypeSegmented}>
            <button className={side==='call'?styles.active:''} onClick={()=>setSide('call')}>Call</button>
            <button className={side==='put'?styles.active:''} onClick={()=>setSide('put')}>Put</button>
          </div>

          <div className={styles.field}>
            <label className={styles.fieldLabel}>Strike Price ({quoteSymbol})</label>
            <input 
              className={styles.input}
              type="number" 
              value={strike} 
              onChange={(e)=>setStrike(Number(e.target.value))} 
              placeholder="0.00"
            />
          </div>

          <div className={styles.field}>
            <label className={styles.fieldLabel}>Expiry</label>
            <select className={styles.select} value={expiry} onChange={(e)=>setExpiry(e.target.value)}>
              <option value="next">Next Expiry</option>
              <option value="2w">2 Weeks</option>
              <option value="1m">1 Month</option>
            </select>
          </div>

          <div className={styles.field}>
            <label className={styles.fieldLabel}>Size (Contracts)</label>
            <input 
              className={styles.input}
              type="number" 
              value={size} 
              onChange={(e)=>setSize(Number(e.target.value))} 
              placeholder="1"
            />
          </div>

          <div className={styles.field}>
            <label className={styles.fieldLabel}>Limit Price ({quoteSymbol})</label>
            <input 
              className={styles.input}
              type="number" 
              value={price} 
              onChange={(e)=>setPrice(Number(e.target.value))} 
              placeholder="0.00"
            />
          </div>

          <div className={styles.orderSummary}>
            <div className={styles.summaryRow}>
              <span>Premium</span>
              <span>${(size * price).toFixed(2)}</span>
            </div>
            <div className={styles.summaryRow}>
              <span>Max Profit</span>
              <span>{side === 'call' ? 'Unlimited' : `$${(strike * size - size * price).toFixed(2)}`}</span>
            </div>
            <div className={styles.summaryRow}>
              <span>Max Loss</span>
              <span>${(size * price).toFixed(2)}</span>
            </div>
          </div>

          <div className={styles.marketInfo}>
            <div className={styles.infoRow}>
              <span>Base</span>
              <span>{baseSymbol}</span>
            </div>
            <div className={styles.infoRow}>
              <span>Quote</span>
              <span>{quoteSymbol}</span>
            </div>
            <div className={styles.infoRow}>
              <span>Mid</span>
              <span>{mid ? mid.toFixed(4) : '-'}</span>
            </div>
          </div>

          <div className={styles.feeSection}>
            <div className={styles.feeSelector}>
              <span className={styles.feeLabel}>Fee Payment</span>
              <button 
                className={`${styles.feeToggle} ${feeType === 'unxv' ? styles.active : ''}`}
                onClick={() => setFeeType(feeType === 'unxv' ? 'input' : 'unxv')}
              >
                {feeType === 'unxv' ? 'UNXV' : quoteSymbol}
              </button>
            </div>
            
            <div className={styles.feeRow}>
              <span>Trading Fee</span>
              <span>
                {feeType === 'unxv' 
                  ? `${feeUnxvDisc.toFixed(6)} UNXV` 
                  : `${tradingFee.toFixed(6)} ${quoteSymbol}`
                }
              </span>
            </div>
          </div>
        </div>

        <div className={styles.orderFooter}>
          <div className={styles.buttonContainer}>
            <button 
              className={`${styles.submitButton} ${action === 'sell' ? styles.sell : ''}`}
              onClick={async ()=>{
                try {
                  if (!provider?.submitOrder) return;
                  await provider.submitOrder({ side, action, size, price, strike, expiry });
                  onClose?.();
                } catch (error) {
                  console.error('Failed to submit order:', error);
                }
              }}
            >
              {action === 'buy' ? 'Buy' : 'Sell'} {side === 'call' ? 'Call' : 'Put'}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}



