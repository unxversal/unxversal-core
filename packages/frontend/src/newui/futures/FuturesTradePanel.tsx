import { useEffect, useMemo, useState } from 'react';
import styles from '../../components/gas-futures/GasFuturesTradePanel.module.css';
import Slider from 'rc-slider';
import 'rc-slider/assets/index.css';
import type { TradePanelDataProvider } from '../../components/derivatives/types';
import { useCurrentAccount, ConnectButton } from '@mysten/dapp-kit';

export function FuturesTradePanel({ mid, provider, baseSymbol = 'SUI', quoteSymbol = 'USDC' }: { mid: number; provider?: TradePanelDataProvider; baseSymbol?: string; quoteSymbol?: string }) {
  const acct = useCurrentAccount();
  const [side, setSide] = useState<'long' | 'short'>('long');
  const [price, setPrice] = useState<number>(mid || 0);
  const [size, setSize] = useState<number>(0);
  const [leverage, setLeverage] = useState<number>(10);
  const [submitting, setSubmitting] = useState(false);
  const [walletTab, setWalletTab] = useState<'assets' | 'staking'>('assets');
  const [quoteBal, setQuoteBal] = useState<number>(0);
  const [baseBal, setBaseBal] = useState<number>(0);
  const [activeStakeUnxv, setActiveStakeUnxv] = useState<number>(0);
  const [takerBps, setTakerBps] = useState<number>(70);
  const [unxvDiscBps, setUnxvDiscBps] = useState<number>(3000);
  const [feeType, setFeeType] = useState<'unxv' | 'input'>('unxv');

  useEffect(() => {
    let live = true;
    (async () => {
      try {
        const b = await provider?.getBalances?.();
        if (live && b) { setBaseBal(b.base || 0); setQuoteBal(b.quote || 0); }
      } catch {}
      try {
        const f = await provider?.getFeeInfo?.();
        if (live && f) { setTakerBps(f.takerBps ?? 70); setUnxvDiscBps(f.unxvDiscountBps ?? 3000); }
      } catch {}
      try {
        if (acct?.address) {
          const st = await provider?.getActiveStake?.(acct.address);
          if (live && typeof st === 'number') setActiveStakeUnxv(st);
        }
      } catch {}
    })();
    const id = setInterval(async () => {
      try {
        const b = await provider?.getBalances?.();
        if (b) { setBaseBal(b.base || 0); setQuoteBal(b.quote || 0); }
      } catch {}
    }, 5000);
    return () => { live = false; clearInterval(id); };
  }, [acct?.address, provider]);

  useEffect(() => { if (mid && !price) setPrice(mid); }, [mid]);

  const effPrice = price || mid || 0;
  const notional = (size || 0) * (effPrice || 0);
  const feeInput = notional * (takerBps / 10000);
  const feeUnxv = notional * ((takerBps * (1 - unxvDiscBps / 10000)) / 10000);
  const requiredMargin = leverage > 0 ? notional / leverage : notional;

  const applyPercent = (p: number) => {
    const maxSize = leverage > 0 ? (quoteBal * leverage) / (effPrice || 1) : (quoteBal / (effPrice || 1));
    setSize(Math.max(0, maxSize * p));
  };

  async function submit() {
    if (!provider?.submitOrder) return;
    if (!size || size <= 0) return;
    setSubmitting(true);
    try {
      await provider.submitOrder({ side, size, price: effPrice, leverage });
      setSize(0);
    } finally { setSubmitting(false); }
  }

  const posPercent = useMemo(() => {
    const maxSize = leverage > 0 ? (quoteBal * leverage) / (effPrice || 1) : (quoteBal / (effPrice || 1));
    return maxSize > 0 ? Math.round((size / maxSize) * 100) : 0;
  }, [quoteBal, leverage, effPrice, size]);

  return (
    <div className={styles.root}>
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
            <div className={styles.balanceRow}><span>{baseSymbol}:</span><span>{baseBal.toLocaleString()}</span></div>
            <div className={styles.balanceRow}><span>{quoteSymbol}:</span><span>{quoteBal.toLocaleString()}</span></div>
          </div>
        ) : (
          <div className={styles.balances}>
            <div className={styles.balanceRow}><span>Active UNXV:</span><span>{activeStakeUnxv.toLocaleString(undefined,{maximumFractionDigits:2})}</span></div>
          </div>
        )}
      </div>

      <div className={styles.orderCard}>
        <div className={styles.orderHeader}>
          <div className={styles.tabs}>
            <button className={side==='long'?styles.active:''} onClick={()=>setSide('long')}>Buy / Long</button>
            <button className={side==='short'?styles.active:''} onClick={()=>setSide('short')}>Sell / Short</button>
          </div>
        </div>

        <div className={styles.contentArea}>
          <div className={styles.availableToTrade}>
            <div className={styles.availableLabel}>Available to Trade</div>
            <div className={styles.availableAmount}>{quoteBal.toLocaleString()} {quoteSymbol}</div>
          </div>

          <div className={styles.field}>
            <div className={styles.fieldLabel}>Price</div>
            <div className={styles.inputGroup}>
              <input type="number" value={price || ''} onChange={(e)=>setPrice(Number(e.target.value))} placeholder={String(mid || 0)} className={styles.inputWithLabel} />
              <div className={styles.tokenSelector}><span>{quoteSymbol}</span></div>
              <span className={styles.midIndicator}>Mid</span>
            </div>
          </div>

          <div className={styles.field}>
            <div className={styles.fieldLabel}>Size</div>
            <div className={styles.inputGroup}>
              <input type="number" value={size || ''} onChange={(e)=>setSize(Number(e.target.value))} placeholder="0" className={styles.inputWithLabel} />
              <div className={styles.tokenSelector}><span>{baseSymbol}</span></div>
            </div>
          </div>

          <div className={styles.positionSizeSlider}>
            <div className={styles.sliderContainer}>
              <div className={styles.sliderWrapper}>
                <Slider min={0} max={100} step={1} value={posPercent} onChange={(v)=>applyPercent((v as number)/100)} dots marks={{0:'',25:'',50:'',75:'',100:''}} />
              </div>
              <div className={styles.percentageDisplay}>{posPercent}%</div>
            </div>
          </div>

          <div className={styles.leverageField}>
            <div className={styles.leverageControl}>
              <div className={styles.leverageHeader}>
                <span className={styles.leverageLabel}>Leverage</span>
                <div className={styles.leverageDisplay}>{leverage}×</div>
              </div>
              <div className={styles.sliderContainer}>
                <div className={styles.sliderWrapper}>
                  <Slider min={0} max={6} step={1} value={[0,5,10,15,20,30,40].indexOf(leverage)} onChange={(val)=>{
                    const arr = [0,5,10,15,20,30,40];
                    const idx = Array.isArray(val) ? val[0] : (val as number);
                    const next = arr[idx] ?? 10;
                    setLeverage(next);
                  }} dots marks={{0:'0×',1:'5×',2:'10×',3:'15×',4:'20×',5:'30×',6:'40×'}} />
                </div>
              </div>
            </div>
          </div>

          <div className={styles.orderSummary}>
            <div className={styles.summaryRow}><span>Order Value</span><span>{notional.toFixed(2)} {quoteSymbol}</span></div>
            <div className={styles.summaryRow}><span>Margin Required</span><span>{requiredMargin.toFixed(2)} {quoteSymbol}</span></div>
            <div className={styles.summaryRow}><span>Trading Fee</span><span>{feeType==='unxv' ? `${feeUnxv.toFixed(6)} UNXV` : `${feeInput.toFixed(6)} ${quoteSymbol}`}</span></div>
          </div>

          <div className={styles.feeSection}>
            <div className={styles.feeSelector}>
              <span className={styles.feeLabel}>Fee Payment</span>
              <button className={`${styles.feeToggle} ${feeType==='unxv'?styles.active:''}`} onClick={()=>setFeeType(feeType==='unxv'?'input':'unxv')}>{feeType==='unxv' ? 'UNXV' : quoteSymbol}</button>
            </div>
          </div>
        </div>

        <div className={styles.orderFooter}>
          {!acct?.address ? (
            <div className={styles.connectWallet}><ConnectButton /></div>
          ) : (
            <button disabled={submitting || size<=0} className={`${styles.submit} ${side==='long'?styles.longButton:styles.shortButton}`} onClick={()=>void submit()}>
              {submitting ? 'Submitting…' : `${side==='long'?'Long':'Short'} ${Math.floor(size).toLocaleString()} ${baseSymbol}`}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}


