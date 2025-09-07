import { useEffect, useMemo, useState } from 'react';
import styles from './GasFuturesTradePanel.module.css';
import { useCurrentAccount, useSignAndExecuteTransaction, useSuiClient, ConnectButton } from '@mysten/dapp-kit';
import { loadSettings } from '../../lib/settings.config';
import Slider from 'rc-slider';
import 'rc-slider/assets/index.css';

export function GasFuturesTradePanel({ mid }: { mid: number }) {
  const acct = useCurrentAccount();
  const client = useSuiClient();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  
  const [side, setSide] = useState<'long' | 'short'>('long');
  const [mode, setMode] = useState<'market' | 'limit' | 'margin'>('market');
  const [price, setPrice] = useState<number>(mid || 0.023);
  const [size, setSize] = useState<number>(0);
  const [leverage, setLeverage] = useState<number>(2);
  const [submitting, setSubmitting] = useState(false);
  const [walletTab, setWalletTab] = useState<'assets' | 'positions'>('assets');
  const [usdcBal, setUsdcBal] = useState<number>(0);
  const [positions, setPositions] = useState<any[]>([]);
  const [marginRatio, setMarginRatio] = useState<number>(0);
  const [accountValue, setAccountValue] = useState<number>(0);


  const s = loadSettings();
  const disabled = !acct?.address || submitting;

  // Load balances and positions
  useEffect(() => {
    let mounted = true;
    const load = async () => {
      if (!acct?.address) return;
      try {
        // Mock USDC balance - in real implementation, load from chain
        setUsdcBal(25000); // $25,000 USDC
        setAccountValue(27500); // Total account value including unrealized PnL
        setMarginRatio(0.15); // 15% margin ratio
        
        // Mock positions - in real implementation, load from gas futures contract
        setPositions([
          { 
            side: 'Long', 
            size: 150000, 
            entryPrice: 0.0234, 
            markPrice: 0.0245, 
            pnl: 165, 
            margin: 1250, 
            leverage: 10 
          },
        ]);
      } catch {}
    };
    void load();
    const id = setInterval(load, 5000);
    return () => { mounted = false; clearInterval(id); };
  }, [acct?.address, client]);

  async function submit(): Promise<void> {
    if (size <= 0) return;
    setSubmitting(true);
    try {
      // TODO: Implement gas futures order submission
      // This would involve:
      // 1. Calculate required margin
      // 2. Submit order to gas futures contract
      // 3. Handle leverage and position management
      console.log('Submitting gas futures order:', {
        side,
        mode,
        size,
        price,
        leverage,
      });
      
      // Mock successful submission
      await new Promise(resolve => setTimeout(resolve, 1000));
    } finally {
      setSubmitting(false);
    }
  }

  // Derived calculations
  const effPrice = mode === 'limit' ? (price || mid || 0.023) : (mid || price || 0.023);
  const notionalValue = (size || 0) * effPrice;
  const requiredMargin = notionalValue / (leverage || 1);
  const tradingFee = notionalValue * 0.0005; // 0.05% trading fee
  const borrowFee = mode === 'margin' ? (size || 0) * effPrice * 0.001 : 0;
  const borrowAPR = 12.5; // Example APR - should come from protocol

  const applyPercent = (p: number) => {
    const maxSize = Math.floor((usdcBal * leverage * p) / (price || mid || 0.023));
    setSize(maxSize);
  };

  return (
    <div className={styles.root}>
      {/* Wallet Card */}
      <div className={styles.walletCard}>
        <div className={styles.cardHeader}>
          <div className={styles.cardTitle}>Portfolio</div>
          <div className={styles.subTabs}>
            <button className={walletTab==='assets'?styles.active:''} onClick={()=>setWalletTab('assets')}>Assets</button>
            <button className={walletTab==='positions'?styles.active:''} onClick={()=>setWalletTab('positions')}>Positions</button>
          </div>
        </div>
        {walletTab==='assets' ? (
          <div className={styles.balances}>
            <div className={styles.balanceRow}><span>Available:</span><span>${usdcBal.toLocaleString()}</span></div>
            <div className={styles.balanceRow}><span>Account Value:</span><span>${accountValue.toLocaleString()}</span></div>
            <div className={styles.balanceRow}><span>Margin Ratio:</span><span className={marginRatio < 0.1 ? styles.warning : ''}>{(marginRatio * 100).toFixed(1)}%</span></div>
          </div>
        ) : (
          <div className={styles.balances}>
            {positions.length > 0 ? (
              positions.map((pos, idx) => (
                <div key={idx} className={styles.positionSummary}>
                  <div className={styles.balanceRow}>
                    <span className={pos.side === 'Long' ? styles.longText : styles.shortText}>{pos.side}</span>
                    <span>{pos.size.toLocaleString()}</span>
                  </div>
                  <div className={styles.balanceRow}>
                    <span>PnL:</span>
                    <span className={pos.pnl >= 0 ? styles.positive : styles.negative}>
                      ${pos.pnl >= 0 ? '+' : ''}{pos.pnl}
                    </span>
                  </div>
                </div>
              ))
            ) : (
              <div className={styles.emptyPositions}>No open positions</div>
            )}
          </div>
        )}
      </div>

      {/* Order Card */}
      <div className={styles.orderCard}>
        <div className={styles.modeToggle}>
          <button className={mode==='limit'?styles.active:''} onClick={()=>setMode('limit')}>Limit</button>
          <button className={mode==='market'?styles.active:''} onClick={()=>setMode('market')}>Market</button>
          <button className={mode==='margin'?styles.active:''} onClick={()=>setMode('margin')}>Margin</button>
        </div>
        
        <div className={styles.tabs}>
          <button className={side==='long'?styles.active:''} onClick={()=>setSide('long')}>
            {mode === 'margin' ? 'Buy / Long' : 'Long'}
          </button>
          <button className={side==='short'?styles.active:''} onClick={()=>setSide('short')}>
            {mode === 'margin' ? 'Sell / Short' : 'Short'}
          </button>
        </div>

        <div className={styles.contentArea}>
          <div className={styles.availableToTrade}>
            <div className={styles.availableLabel}>Available Balance</div>
            <div className={styles.availableAmount}>
              ${usdcBal.toLocaleString()} USDC
            </div>
          </div>
          
          {mode==='limit' && (
            <div className={styles.field}>
              <div className={styles.inputGroup}>
                <input 
                  type="number" 
                  value={price || ''} 
                  onChange={(e)=>setPrice(Number(e.target.value))} 
                  placeholder={`Price (USDC)`}
                  className={styles.inputWithLabel}
                />
                <span className={styles.midIndicator}>Mid</span>
              </div>
            </div>
          )}

          <div className={styles.field}>
            <div className={styles.inputGroup}>
              <input 
                type="number" 
                value={size || ''} 
                onChange={(e)=>setSize(Number(e.target.value))} 
placeholder={mode==='market' ? 'Amount (Input)' : mode==='margin' ? 'Position Size' : 'Size'} 
                className={styles.inputWithLabel}
              />
              <div className={styles.tokenSelector}>
                <span>MIST</span>
                <svg className={styles.dropdownIcon} width="12" height="8" viewBox="0 0 12 8" fill="none">
                  <path d="M1 1L6 6L11 1" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
              </div>
            </div>
{mode !== 'margin' && (
              <div className={styles.sliderContainer}>
                <div className={styles.sliderWrapper}>
                  <Slider
                    min={0}
                    max={100}
                    step={1}
                    value={(() => {
                      const maxSize = Math.floor((usdcBal * leverage) / (price || mid || 0.023));
                      return maxSize > 0 ? Math.round((size / maxSize) * 100) : 0;
                    })()}
                    onChange={(value: number | number[]) => {
                      const percent = (value as number) / 100;
                      applyPercent(percent);
                    }}
                    dots
                    marks={{
                      0: '',
                      25: '',
                      50: '',
                      75: '',
                      100: ''
                    }}
                  />
                </div>
                <div className={styles.percentageDisplay}>
                  {(() => {
                    const maxSize = Math.floor((usdcBal * leverage) / (price || mid || 0.023));
                    return maxSize > 0 ? Math.round((size / maxSize) * 100) : 0;
                  })()}%
                </div>
              </div>
            )}
          </div>

{mode==='margin' && (
            <>
              <div className={styles.leverageControl}>
                <div className={styles.leverageHeader}>
                  <span className={styles.leverageLabel}>Leverage</span>
                  <div className={styles.leverageInput}>
                    <input 
                      type="number" 
                      value={leverage || ''} 
                      onChange={(e) => {
                        const val = Number(e.target.value);
if (val >= 0 && val <= 10) setLeverage(val);
                      }}
min="0"
                      max="10"
                      step="0.1"
                      className={styles.customLeverageInput}
                      placeholder="2"
                    />
                    <span>×</span>
                  </div>
                </div>
                <div className={styles.sliderContainer}>
                  <div className={styles.sliderWrapper}>
                    <Slider
                      min={1}
                      max={10}
                      step={0.1}
                      value={leverage}
                      onChange={(value: number | number[]) => {
                        setLeverage(value as number);
                      }}
                      marks={{
                        1: '1×',
                        2.5: '',
                        5: '',
                        7.5: '',
                        10: '10×'
                      }}
                    />
                  </div>
                </div>
              </div>

              <div className={styles.collateralInfo}>
                <div className={styles.marginRow}>
                  <span>Collateral (USDC)</span>
                  <span>{leverage > 0 ? ((size || 0) * (price || mid || 0.023) / leverage).toFixed(2) : '0.00'} USDC</span>
                </div>
                <div className={styles.marginRow}>
                  <span>Borrowing</span>
                  <span>{(size || 0).toFixed(0)} {side === 'long' ? 'MIST' : 'USDC'}</span>
                </div>
              </div>

              <div className={styles.marginInfo}>
                <div className={styles.marginRow}>
                  <span>Liquidation Price</span>
                  <span>
                    {(() => {
                      const entryPrice = price || mid || 0.023;
                      const liqPrice = side === 'long' 
                        ? entryPrice * (1 - 0.75/leverage)
                        : entryPrice * (1 + 0.75/leverage);
                      return liqPrice.toFixed(4);
                    })()} USDC
                  </span>
                </div>
              </div>
            </>
          )}


          <div className={styles.feeDisplay}>
            <div className={styles.feeRow}>
              <span>Trading Fee</span>
              <span>${tradingFee.toFixed(6)} USDC</span>
            </div>
            
            {mode === 'margin' && (
              <>
                <div className={styles.feeRow}>
                  <span>Borrow Fee</span>
                  <span>${borrowFee.toFixed(6)} USDC</span>
                </div>
                <div className={styles.feeRow}>
                  <span>Borrow APR</span>
                  <span>{borrowAPR}%</span>
                </div>
                <div className={styles.feeRow}>
                  <span className={styles.totalFeeLabel}>Total Fee</span>
                  <span className={styles.totalFeeAmount}>
                    ${(tradingFee + borrowFee).toFixed(6)} USDC
                  </span>
                </div>
              </>
            )}
          </div>
        </div>

        <div className={styles.buttonArea}>
          {!acct?.address ? (
            <div className={styles.connectWallet}>
              <ConnectButton />
            </div>
          ) : (
            <button 
              disabled={disabled || size <= 0} 
              className={`${styles.submit} ${side==='long'?styles.longButton:styles.shortButton}`} 
              onClick={() => void submit()}
            >
{submitting ? 'Submitting...' : side==='long'?'Long':'Short'}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
