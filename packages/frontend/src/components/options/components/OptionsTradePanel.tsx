import { useEffect, useState } from 'react';
import panelStyles from '../../gas-futures/GasFuturesTradePanel.module.css';
import { X, ArrowLeft } from 'lucide-react';

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
  const [mode, setMode] = useState<'market' | 'limit'>('limit');
  const [size, setSize] = useState<number>(1);
  const [price, setPrice] = useState<number>(Number(mid?.toFixed(3) || '1'));
  const [strike, setStrike] = useState<number>(Number(mid?.toFixed(2) || '1'));
  const [expiry, setExpiry] = useState<string>('next');

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

  return (
    <div className={panelStyles.root}>
      <div className={panelStyles.header}>
        {showBackButton && onClose && (
          <button 
            onClick={onClose}
            style={{
              background: 'transparent',
              border: 'none',
              color: '#9ca3af',
              cursor: 'pointer',
              padding: '4px',
              borderRadius: '4px',
              transition: 'all 0.2s ease',
              marginRight: '8px'
            }}
            onMouseEnter={(e) => {
              e.currentTarget.style.background = '#1a1d29';
              e.currentTarget.style.color = '#e5e7eb';
            }}
            onMouseLeave={(e) => {
              e.currentTarget.style.background = 'transparent';
              e.currentTarget.style.color = '#9ca3af';
            }}
          >
            <ArrowLeft size={16} />
          </button>
        )}
        <div className={panelStyles.title}>Trade Options</div>
        {!showBackButton && onClose && (
          <button 
            onClick={onClose}
            style={{
              background: 'transparent',
              border: 'none',
              color: '#9ca3af',
              cursor: 'pointer',
              padding: '4px',
              borderRadius: '4px',
              transition: 'all 0.2s ease'
            }}
            onMouseEnter={(e) => {
              e.currentTarget.style.background = '#1a1d29';
              e.currentTarget.style.color = '#e5e7eb';
            }}
            onMouseLeave={(e) => {
              e.currentTarget.style.background = 'transparent';
              e.currentTarget.style.color = '#9ca3af';
            }}
          >
            <X size={16} />
          </button>
        )}
      </div>
      <div className={panelStyles.controls}>
        <div className={panelStyles.row}>
          <div className={panelStyles.segmented}>
            <button className={side==='call'?panelStyles.active:''} onClick={()=>setSide('call')}>Call</button>
            <button className={side==='put'?panelStyles.active:''} onClick={()=>setSide('put')}>Put</button>
          </div>
          <div className={panelStyles.segmented}>
            <button className={action==='buy'?panelStyles.active:''} onClick={()=>setAction('buy')}>Buy</button>
            <button className={action==='sell'?panelStyles.active:''} onClick={()=>setAction('sell')}>Sell</button>
          </div>
        </div>

        <div className={panelStyles.row}>
          <label>Mode</label>
          <div className={panelStyles.segmented}>
            <button className={mode==='market'?panelStyles.active:''} onClick={()=>setMode('market')}>Market</button>
            <button className={mode==='limit'?panelStyles.active:''} onClick={()=>setMode('limit')}>Limit</button>
          </div>
        </div>

        <div className={panelStyles.row}>
          <label>Expiry</label>
          <select value={expiry} onChange={(e)=>setExpiry(e.target.value)}>
            <option value="next">Next Expiry</option>
            <option value="2w">2 Weeks</option>
            <option value="1m">1 Month</option>
          </select>
        </div>

        <div className={panelStyles.row}>
          <label>Strike</label>
          <input type="number" value={strike} onChange={(e)=>setStrike(Number(e.target.value))} />
        </div>

        <div className={panelStyles.row}>
          <label>Size (contracts)</label>
          <input type="number" value={size} onChange={(e)=>setSize(Number(e.target.value))} />
        </div>

        {mode==='limit' && (
          <div className={panelStyles.row}>
            <label>Limit Price ({quoteSymbol})</label>
            <input type="number" value={price} onChange={(e)=>setPrice(Number(e.target.value))} />
          </div>
        )}

        <div className={panelStyles.actions}>
          <button className={action==='buy'?panelStyles.buy:panelStyles.sell} onClick={async ()=>{
            try {
              if (!provider?.submitOrder) return;
              await provider.submitOrder({ side, action, mode, size, price, strike, expiry });
              onClose?.();
            } catch (error) {
              console.error('Failed to submit order:', error);
            }
          }}>{action==='buy'?'Place Buy':'Place Sell'}</button>
        </div>
      </div>
      <div className={panelStyles.footer}>
        <div><span>Base</span><span>{baseSymbol}</span></div>
        <div><span>Quote</span><span>{quoteSymbol}</span></div>
        <div><span>Mid</span><span>{mid ? mid.toFixed(4) : '-'}</span></div>
      </div>
    </div>
  );
}


