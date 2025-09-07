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
  const [mode, setMode] = useState<'market' | 'limit'>('market');
  const [price, setPrice] = useState<number>(mid || 0.023);
  const [size, setSize] = useState<number>(0);
  const [leverage, setLeverage] = useState<number>(10);
  const [submitting, setSubmitting] = useState(false);
  const [walletTab, setWalletTab] = useState<'assets' | 'staking'>('assets');
  const [usdcBal, setUsdcBal] = useState<number>(0);
  const [positions, setPositions] = useState<any[]>([]);
  const [marginRatio, setMarginRatio] = useState<number>(0);
  const [accountValue, setAccountValue] = useState<number>(0);
  const [activeStakeUnxv, setActiveStakeUnxv] = useState<number>(0);
  const [takerBps, setTakerBps] = useState<number>(70); // fallback 0.70 bps
  const [unxvDiscBps, setUnxvDiscBps] = useState<number>(3000); // fallback 30%
  const [feeType, setFeeType] = useState<'unxv' | 'input'>('unxv');


  const s = loadSettings();
  const stakingPoolId = s.staking?.poolId ?? '';
  const feeConfigId = s.dex?.feeConfigId ?? '';
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

  // Load staking active stake (via dynamic field on staking pool)
  useEffect(() => {
    let mounted = true;
    const load = async () => {
      if (!acct?.address || !stakingPoolId) return;
      try {
        const obj = await client.getDynamicFieldObject({ parentId: stakingPoolId, name: { type: 'address', value: acct.address } as any });
        const fields = (obj as any)?.data?.content?.fields ?? {};
        const active = Number(fields.active_stake ?? 0);
        if (!mounted) return;
        setActiveStakeUnxv(active / 1e9); // assume UNXV 9 decimals by convention; adjust if needed
      } catch {
        if (mounted) setActiveStakeUnxv(0);
      }
    };
    void load();
  }, [acct?.address, stakingPoolId, client]);

  // Load fee config (bps)
  useEffect(() => {
    let mounted = true;
    const load = async () => {
      if (!feeConfigId) return;
      try {
        const o = await client.getObject({ id: feeConfigId, options: { showContent: true } });
        const f = (o as any)?.data?.content?.fields;
        const bps = Number(f?.dex_taker_fee_bps ?? 0) || Number(f?.dex_fee_bps ?? 0) || 70;
        const disc = Number(f?.unxv_discount_bps ?? 3000);
        if (!mounted) return;
        setTakerBps(bps);
        setUnxvDiscBps(disc);
      } catch {}
    };
    void load();
  }, [feeConfigId, client]);

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
  const requiredMargin = leverage > 0 ? notionalValue / leverage : notionalValue;
  const feeInput = notionalValue * (takerBps / 10000);
  const feeUnxvDisc = notionalValue * ((takerBps * (1 - unxvDiscBps / 10000)) / 10000);
  const inputFeeSym = 'USDC';

  const applyPercent = (p: number) => {
    const maxSize = leverage > 0 
      ? Math.floor((usdcBal * leverage * p) / (price || mid || 0.023))
      : Math.floor((usdcBal * p) / (price || mid || 0.023));
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
            <button className={walletTab==='staking'?styles.active:''} onClick={()=>setWalletTab('staking')}>Staking</button>
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
            <div className={styles.balanceRow}><span>Active UNXV:</span><span>{activeStakeUnxv.toLocaleString(undefined,{maximumFractionDigits:2})}</span></div>
          </div>
        )}
      </div>

      {/* Order Card */}
      <div className={styles.orderCard}>
        <div className={styles.modeToggle}>
          <button className={mode==='limit'?styles.active:''} onClick={()=>setMode('limit')}>Limit</button>
          <button className={mode==='market'?styles.active:''} onClick={()=>setMode('market')}>Market</button>
        </div>
        
        <div className={styles.tabs}>
          <button className={side==='long'?styles.active:''} onClick={()=>setSide('long')}>
            Buy / Long
          </button>
          <button className={side==='short'?styles.active:''} onClick={()=>setSide('short')}>
            Sell / Short
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
            <div className={styles.sliderContainer}>
              <div className={styles.sliderWrapper}>
                <Slider
                  min={0}
                  max={100}
                  step={1}
                  value={(() => {
                    const maxSize = leverage > 0 
                      ? Math.floor((usdcBal * leverage) / (price || mid || 0.023))
                      : Math.floor(usdcBal / (price || mid || 0.023));
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
                  handleStyle={{
                    backgroundColor: '#00d4aa',
                    borderColor: '#00d4aa',
                    width: 16,
                    height: 16,
                    marginTop: -6,
                    opacity: 1,
                    boxShadow: 'none'
                  }}
                  trackStyle={{
                    backgroundColor: '#00d4aa',
                    height: 4
                  }}
                  railStyle={{
                    backgroundColor: '#1e2230',
                    height: 4
                  }}
                />
              </div>
              <div className={styles.percentageDisplay}>
                {(() => {
                  const maxSize = leverage > 0 
                    ? Math.floor((usdcBal * leverage) / (price || mid || 0.023))
                    : Math.floor(usdcBal / (price || mid || 0.023));
                  return maxSize > 0 ? Math.round((size / maxSize) * 100) : 0;
                })()}%
              </div>
            </div>
          </div>

          <div className={styles.leverageControl}>
            <div className={styles.leverageHeader}>
              <span className={styles.leverageLabel}>Leverage</span>
              <div className={styles.leverageDisplay}>
                {leverage}×
              </div>
            </div>
            <div className={styles.leverageButtons}>
              {[0, 5, 10, 15, 20, 30, 40].map(lev => (
                <button 
                  key={lev}
                  className={`${styles.leverageBtn} ${leverage === lev ? styles.activeLeverage : ''}`}
                  onClick={() => setLeverage(lev)}
                >
                  {lev}×
                </button>
              ))}
            </div>
          </div>

          <div className={styles.collateralInfo}>
            <div className={styles.marginRow}>
              <span>Collateral (USDC)</span>
              <span>
                {leverage > 0 
                  ? ((size || 0) * (price || mid || 0.023) / leverage).toFixed(2)
                  : (size || 0) > 0 
                    ? ((size || 0) * (price || mid || 0.023)).toFixed(2)
                    : '0.00'
                } USDC
              </span>
            </div>
            <div className={styles.marginRow}>
              <span>Position Size</span>
              <span>{(size || 0).toFixed(0)} MIST</span>
            </div>
          </div>

          <div className={styles.marginInfo}>
            <div className={styles.marginRow}>
              <span>Liquidation Price</span>
              <span>
                {(() => {
                  if (leverage === 0) return 'N/A';
                  const entryPrice = price || mid || 0.023;
                  const liqPrice = side === 'long' 
                    ? entryPrice * (1 - 0.75/leverage)
                    : entryPrice * (1 + 0.75/leverage);
                  return liqPrice.toFixed(4) + ' USDC';
                })()}
              </span>
            </div>
          </div>

          <div className={styles.feeSection}>
            <div className={styles.feeSelector}>
              <span className={styles.feeLabel}>Fee Payment</span>
              <button 
                className={`${styles.feeToggle} ${feeType === 'unxv' ? styles.active : ''}`}
                onClick={() => setFeeType(feeType === 'unxv' ? 'input' : 'unxv')}
              >
                {feeType === 'unxv' ? 'UNXV' : inputFeeSym}
              </button>
            </div>
            
            <div className={styles.feeDisplay}>
              <div className={styles.feeRow}>
                <span>Trading Fee</span>
                <span>{feeType === 'unxv' ? (feeUnxvDisc ? feeUnxvDisc.toFixed(6) : '-') + ' UNXV' : (feeInput ? feeInput.toFixed(6) : '-') + ' ' + inputFeeSym}</span>
              </div>
              
            </div>
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
