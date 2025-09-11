import { useEffect, useState } from 'react';
import styles from './GasFuturesTradePanel.module.css';
import { useCurrentAccount, useSuiClient, ConnectButton } from '@mysten/dapp-kit';
import { loadSettings } from '../../lib/settings.config';
import Slider from 'rc-slider';
import 'rc-slider/assets/index.css';
import type { TradePanelDataProvider } from '../derivatives/types';

export function GasFuturesTradePanel({ mid, provider, baseSymbol = 'MIST', quoteSymbol = 'USDC' }: { mid: number; provider?: TradePanelDataProvider; baseSymbol?: string; quoteSymbol?: string }) {
  const acct = useCurrentAccount();
  const client = useSuiClient();
  
  const [side, setSide] = useState<'long' | 'short'>('long');
  // Futures are limit-only on-chain; UI uses limit exclusively
  const [price, setPrice] = useState<number>(mid || 0.023);
  const [size, setSize] = useState<number>(0);
  const [leverage, setLeverage] = useState<number>(10);
  const [submitting, setSubmitting] = useState(false);
  const [walletTab, setWalletTab] = useState<'assets' | 'staking'>('assets');
  const [usdcBal, setUsdcBal] = useState<number>(0);
  const [mistBal, setMistBal] = useState<number>(0);
  const [_marginRatio, _setMarginRatio] = useState<number>(0);
  const [_accountValue, _setAccountValue] = useState<number>(0);
  const [activeStakeUnxv, setActiveStakeUnxv] = useState<number>(0);
  const [takerBps, setTakerBps] = useState<number>(70); // fallback 0.70 bps
  const [unxvDiscBps, setUnxvDiscBps] = useState<number>(3000); // fallback 30%
  const [feeType, setFeeType] = useState<'unxv' | 'input'>('unxv');

  const s = loadSettings();
  const stakingPoolId = s.staking?.poolId ?? '';
  const feeConfigId = s.dex?.feeConfigId ?? '';
  // derived disabled state not used in current UI

  // Load balances and positions
  useEffect(() => {
    let mounted = true;
    const load = async () => {
      if (!acct?.address) return;
      try {
        if (provider?.getBalances) {
          const { base, quote } = await provider.getBalances();
          if (!mounted) return;
          setMistBal(base);
          setUsdcBal(quote);
        } else {
          setUsdcBal(25000);
          setMistBal(1500000);
        }
        if (provider?.getAccountMetrics) {
          const m = await provider.getAccountMetrics();
          if (!mounted) return;
          _setAccountValue(m.accountValue);
          _setMarginRatio(m.marginRatio);
        } else {
          _setAccountValue(27500);
          _setMarginRatio(0.15);
        }
        // positions data is not displayed here; skip populating
      } catch {}
    };
    void load();
    const id = setInterval(load, 5000);
    return () => { mounted = false; clearInterval(id); };
  }, [acct?.address, client, provider]);

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
      try {
        if (provider?.getFeeInfo) {
          const { takerBps, unxvDiscountBps } = await provider.getFeeInfo();
          if (!mounted) return;
          setTakerBps(takerBps);
          setUnxvDiscBps(unxvDiscountBps);
        } else {
          if (!feeConfigId) return;
          const o = await client.getObject({ id: feeConfigId, options: { showContent: true } });
          const f = (o as any)?.data?.content?.fields;
          const bps = Number(f?.dex_taker_fee_bps ?? 0) || Number(f?.dex_fee_bps ?? 0) || 70;
          const disc = Number(f?.unxv_discount_bps ?? 3000);
          if (!mounted) return;
          setTakerBps(bps);
          setUnxvDiscBps(disc);
        }
      } catch {}
    };
    void load();
  }, [feeConfigId, client, provider]);

  async function submit(): Promise<void> {
    if (size <= 0) return;
    setSubmitting(true);
    try {
      if (provider?.submitOrder) {
        await provider.submitOrder({ side, size, price, leverage });
      } else {
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
    } finally {
      setSubmitting(false);
    }
  }

  // Derived calculations
  const effPrice = (price || mid || 0.023);
  const notionalValue = (size || 0) * effPrice;
  const requiredMargin = leverage > 0 ? notionalValue / leverage : notionalValue;
  const feeInput = notionalValue * (takerBps / 10000);
  const feeUnxvDisc = notionalValue * ((takerBps * (1 - unxvDiscBps / 10000)) / 10000);

  const applyPercent = (p: number) => {
    const maxSize = leverage > 0 
      ? Math.floor((usdcBal * leverage * p) / (price || mid || 0.023))
      : Math.floor((usdcBal * p) / (price || mid || 0.023));
    setSize(maxSize);
  };

  // Max position size calculations
  // Derived inline where needed to avoid unused variable warnings

  return (
    <div className={styles.root}>
      {/* Wallet Card */}
      <div className={styles.walletCard}>
        <div className={styles.cardHeader}>
          <div className={styles.cardTitle}>Wallet</div>
          <div className={styles.subTabs}>
            <button className={walletTab==='assets'?styles.active:''} onClick={()=>setWalletTab('assets')}>Assets</button>
            <button className={walletTab==='staking'?styles.active:''} onClick={()=>setWalletTab('staking')}>Staking</button>
          </div>
        </div>
        {walletTab==='assets' ? (
          <div className={styles.balances}>
            <div className={styles.balanceRow}><span>{baseSymbol}:</span><span>{mistBal.toLocaleString()}</span></div>
            <div className={styles.balanceRow}><span>{quoteSymbol}:</span><span>{usdcBal.toLocaleString()}</span></div>
          </div>
        ) : (
          <div className={styles.balances}>
            <div className={styles.balanceRow}><span>Active UNXV:</span><span>{activeStakeUnxv.toLocaleString(undefined,{maximumFractionDigits:2})}</span></div>
          </div>
        )}
      </div>

      {/* Order Card */}
      <div className={styles.orderCard}>
        <div className={styles.orderHeader}>
          {/* Removed Market/Limit toggle; futures are limit-only */}
          <div className={styles.tabs}>
            <button className={side==='long'?styles.active:''} onClick={()=>setSide('long')}>
              Buy / Long
            </button>
            <button className={side==='short'?styles.active:''} onClick={()=>setSide('short')}>
              Sell / Short
            </button>
          </div>
        </div>

        <div className={styles.contentArea}>
          <div className={styles.availableToTrade}>
            <div className={styles.availableLabel}>Available to Trade</div>
            <div className={styles.availableAmount}>
              {usdcBal.toLocaleString()} {quoteSymbol}
            </div>
          </div>
          
          <div className={styles.field}>
            <div className={styles.fieldLabel}>Price</div>
            <div className={styles.inputGroup}>
              <input 
                type="number" 
                value={price || ''} 
                onChange={(e)=>setPrice(Number(e.target.value))} 
                placeholder="0.023"
                className={styles.inputWithLabel}
              />
              <div className={styles.tokenSelector}><span>{quoteSymbol}</span></div>
              <span className={styles.midIndicator}>Mid</span>
            </div>
          </div>

          <div className={styles.field}>
            <div className={styles.fieldLabel}>Size</div>
            <div className={styles.inputGroup}>
              <input 
                type="number" 
                value={size || ''} 
                onChange={(e)=>setSize(Number(e.target.value))} 
                placeholder="0"
                className={styles.inputWithLabel}
              />
              <div className={styles.tokenSelector}>
                <span>{baseSymbol}</span>
                <svg className={styles.dropdownIcon} width="12" height="8" viewBox="0 0 12 8" fill="none">
                  <path d="M1 1L6 6L11 1" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
              </div>
            </div>
          </div>

          <div className={styles.positionSizeSlider}>
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

          <div className={styles.leverageField}>
            <div className={styles.leverageControl}>
              <div className={styles.leverageHeader}>
                <span className={styles.leverageLabel}>Leverage</span>
                <div className={styles.leverageDisplay}>
                  {leverage}×
                </div>
              </div>
              <div className={styles.sliderContainer}>
                <div className={styles.sliderWrapper}>
                  <Slider
                    min={0}
                    max={6}
                    step={1}
                    value={(() => {
                      const leverageValues = [0, 5, 10, 15, 20, 30, 40];
                      return leverageValues.indexOf(leverage);
                    })()}
                    onChange={(value: number | number[]) => {
                      const leverageValues = [0, 5, 10, 15, 20, 30, 40];
                      const index = Array.isArray(value) ? value[0] : value;
                      setLeverage(leverageValues[index]);
                    }}
                    dots
                    marks={{
                      0: '0×',
                      1: '5×',
                      2: '10×',
                      3: '15×',
                      4: '20×',
                      5: '30×',
                      6: '40×'
                    }}
                  />
                </div>
              </div>
            </div>
          </div>

          <div className={styles.orderSummary}>
            <div className={styles.summaryRow}>
              <span>Order Value</span>
              <span>{notionalValue.toFixed(2)} {quoteSymbol}</span>
            </div>
            <div className={styles.summaryRow}>
              <span>Margin Required</span>
              <span>{requiredMargin.toFixed(2)} {quoteSymbol}</span>
            </div>
            <div className={styles.summaryRow}>
              <span>Collateral ({quoteSymbol})</span>
              <span>
                {leverage > 0 
                  ? ((size || 0) * (price || mid || 0.023) / leverage).toFixed(2)
                  : (size || 0) > 0 
                    ? ((size || 0) * (price || mid || 0.023)).toFixed(2)
                    : '0.00'
                } USDC
              </span>
            </div>
            <div className={styles.summaryRow}>
              <span>Liquidation Price</span>
              <span>
                {(() => {
                  if (leverage === 0) return 'N/A';
                  const entryPrice = price || mid || 0.023;
                  const liqPrice = side === 'long' 
                    ? entryPrice * (1 - 0.75/leverage)
                    : entryPrice * (1 + 0.75/leverage);
                  return liqPrice.toFixed(4) + ' ' + quoteSymbol;
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
                {feeType === 'unxv' ? 'UNXV' : quoteSymbol}
              </button>
            </div>
            
            <div className={styles.feeRow}>
              <span>Trading Fee</span>
              <span>
                {feeType === 'unxv' 
                  ? (feeUnxvDisc ? feeUnxvDisc.toFixed(6) : '-') + ' UNXV' 
                  : (feeInput ? feeInput.toFixed(6) : '-') + ' ' + quoteSymbol
                }
              </span>
            </div>
          </div>

        </div>

        <div className={styles.orderFooter}>
          {!acct?.address ? (
            <div className={styles.connectWallet}>
              <ConnectButton />
            </div>
          ) : (
            <button 
              disabled={submitting || size <= 0} 
              className={`${styles.submit} ${side==='long'?styles.longButton:styles.shortButton}`} 
              onClick={() => void submit()}
              title={size <= 0 ? 'Enter a position size to continue' : ''}
            >
              {submitting ? 'Submitting...' : size <= 0 ? `Enter Size to ${side === 'long' ? 'Long' : 'Short'}` : `${side === 'long' ? 'Long' : 'Short'} ${size.toLocaleString()} ${baseSymbol}`}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
