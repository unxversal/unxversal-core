import { useEffect, useMemo, useState } from 'react';
import styles from '../../components/gas-futures/GasFuturesTradePanel.module.css';
import Slider from 'rc-slider';
import 'rc-slider/assets/index.css';
import type { TradePanelDataProvider } from '../../components/derivatives/types';
import { useCurrentAccount, ConnectButton, useSuiClient } from '@mysten/dapp-kit';
import { loadSettings, getTokenBySymbol } from '../../lib/settings.config';

export function FuturesTradePanel({ mid, provider, baseSymbol = 'SUI', quoteSymbol = 'USDC' }: { mid: number; provider?: TradePanelDataProvider; baseSymbol?: string; quoteSymbol?: string }) {
  const acct = useCurrentAccount();
  const sui = useSuiClient();
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
  const [lockingNotional, setLockingNotional] = useState<boolean>(true);
  const [targetNotional, setTargetNotional] = useState<number>(0);
  const [showDepositModal, setShowDepositModal] = useState<boolean>(false);
  const [coinOptions, setCoinOptions] = useState<Array<{ id: string; balance: bigint }>>([]);
  const [showWithdrawModal, setShowWithdrawModal] = useState<boolean>(false);
  const [withdrawAmount, setWithdrawAmount] = useState<string>('');

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
  const liqPrice = useMemo(() => {
    if (!effPrice || leverage <= 0) return 'N/A';
    const lp = side === 'long' ? effPrice * (1 - 0.75 / leverage) : effPrice * (1 + 0.75 / leverage);
    return `${lp.toFixed(4)} ${quoteSymbol}`;
  }, [effPrice, leverage, side, quoteSymbol]);

  // Keep notional constant when editing price
  useEffect(() => {
    if (!lockingNotional) return;
    if (targetNotional > 0 && effPrice > 0) {
      setSize(targetNotional / effPrice);
    }
  }, [effPrice]);

  const onChangePrice = (v: number) => {
    const pv = Number(v) || 0;
    if (lockingNotional) {
      if (notional <= 0 && size > 0) setTargetNotional(size * (effPrice || 0));
      else if (notional > 0) setTargetNotional(notional);
    }
    setPrice(pv);
  };

  const applyPercent = (p: number) => {
    const maxSize = leverage > 0 ? (quoteBal * leverage) / (effPrice || 1) : (quoteBal / (effPrice || 1));
    setSize(Math.max(0, maxSize * p));
    if (lockingNotional) setTargetNotional(Math.max(0, maxSize * p) * effPrice);
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

  const openDepositModal = async () => {
    if (!acct?.address) return;
    try {
      const settings = loadSettings();
      const tokenInfo = getTokenBySymbol(quoteSymbol, settings);
      const coinType = tokenInfo?.typeTag || '';
      const coins = coinType
        ? await sui.getCoins({ owner: acct.address, coinType })
        : { data: [] as any[] };
      const list = (coins.data ?? []).map(c => ({ id: c.coinObjectId, balance: BigInt(c.balance ?? '0') }));
      setCoinOptions(list);
      setShowDepositModal(true);
    } catch { setCoinOptions([]); setShowDepositModal(true); }
  };

  const submitWithdraw = () => {
    const amt = Number(withdrawAmount);
    if (!isFinite(amt) || amt <= 0) return;
    provider?.withdrawCollateral?.(amt);
    setShowWithdrawModal(false);
    setWithdrawAmount('');
  };

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
            <div className={styles.walletActions}>
              <button className={styles.walletActionBtn} onClick={openDepositModal}>Deposit</button>
              <button className={styles.walletActionBtn} onClick={() => setShowWithdrawModal(true)}>Withdraw</button>
              <button className={styles.walletActionBtn} onClick={() => provider?.claimPnlCredit?.()}>Claim PnL</button>
            </div>
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
              <input type="number" value={price || ''} onChange={(e)=>onChangePrice(Number(e.target.value))} placeholder={String(mid || 0)} className={styles.inputWithLabel} />
              <div className={styles.tokenSelector}><span>{quoteSymbol}</span></div>
              <span className={styles.midIndicator}>Mid</span>
            </div>
          </div>

          <div className={styles.field}>
            <div className={styles.fieldLabel}>Size</div>
            <div className={styles.inputGroup}>
              <input type="number" value={size || ''} onChange={(e)=>{ const v = Number(e.target.value) || 0; setSize(v); if (lockingNotional) setTargetNotional(v * effPrice); }} placeholder="0" className={styles.inputWithLabel} />
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
                    if (lockingNotional) setTargetNotional((size || 0) * effPrice);
                  }} dots marks={{0:'0×',1:'5×',2:'10×',3:'15×',4:'20×',5:'30×',6:'40×'}} />
                </div>
              </div>
            </div>
          </div>

          <div className={styles.feeSection}>
            <div className={styles.feeSelector}>
              <span className={styles.feeLabel}>Fee Payment</span>
              <button className={`${styles.feeToggle} ${feeType==='unxv'?styles.active:''}`} onClick={()=>setFeeType(feeType==='unxv'?'input':'unxv')}>{feeType==='unxv' ? 'UNXV' : quoteSymbol}</button>
            </div>
          </div>

          <div className={styles.orderSummary}>
            <div className={styles.summaryRow}><span>Order Value</span><span>{notional.toFixed(2)} {quoteSymbol}</span></div>
            <div className={styles.summaryRow}><span>Margin Required</span><span>{requiredMargin.toFixed(2)} {quoteSymbol}</span></div>
            <div className={styles.summaryRow}><span>Trading Fee</span><span>{feeType==='unxv' ? `${feeUnxv.toFixed(6)} UNXV` : `${feeInput.toFixed(6)} ${quoteSymbol}`}</span></div>
            <div className={styles.summaryRow}><span>Liquidation Price</span><span>{liqPrice}</span></div>
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

      {showDepositModal && (
        <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.6)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 9999 }} onClick={()=>setShowDepositModal(false)}>
          <div style={{ background: '#0a0c12', border: '1px solid #1a1d29', borderRadius: 8, padding: 16, minWidth: 320 }} onClick={(e)=>e.stopPropagation()}>
            <div style={{ color: '#e5e7eb', fontWeight: 600, marginBottom: 8 }}>Select Collateral Coin</div>
            <div style={{ display: 'grid', gap: 8, maxHeight: 260, overflowY: 'auto' }}>
              {coinOptions.length === 0 ? (
                <div style={{ color: '#9ca3af' }}>No {quoteSymbol} coins found.</div>
              ) : coinOptions.map((c) => (
                <button key={c.id} style={{ background: '#111827', color: '#e5e7eb', border: '1px solid #1f2937', borderRadius: 6, padding: 8, textAlign: 'left' }} onClick={() => { setShowDepositModal(false); provider?.depositCollateral?.(c.id); }}>
                  <div style={{ fontSize: 12 }}>{c.id.slice(0,10)}…{c.id.slice(-6)}</div>
                  <div style={{ fontSize: 11, color: '#9ca3af' }}>Balance: {Number(c.balance).toLocaleString()}</div>
                </button>
              ))}
            </div>
            <div style={{ marginTop: 12, display: 'flex', justifyContent: 'flex-end' }}>
              <button style={{ background: '#1f2937', color: '#e5e7eb', border: 'none', borderRadius: 6, padding: '6px 10px' }} onClick={()=>setShowDepositModal(false)}>Close</button>
            </div>
          </div>
        </div>
      )}

      {showWithdrawModal && (
        <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.6)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 9999 }} onClick={()=>setShowWithdrawModal(false)}>
          <div style={{ background: '#0a0c12', border: '1px solid #1a1d29', borderRadius: 8, padding: 16, minWidth: 320 }} onClick={(e)=>e.stopPropagation()}>
            <div style={{ color: '#e5e7eb', fontWeight: 600, marginBottom: 8 }}>Withdraw Collateral</div>
            <div style={{ display: 'grid', gap: 8 }}>
              <label style={{ color: '#9ca3af', fontSize: 12 }}>Amount ({quoteSymbol})</label>
              <input style={{ background: '#111827', color: '#e5e7eb', border: '1px solid #1f2937', borderRadius: 6, padding: 8 }} type="number" value={withdrawAmount} onChange={(e)=>setWithdrawAmount(e.target.value)} placeholder="0.00" />
            </div>
            <div style={{ marginTop: 12, display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
              <button style={{ background: '#1f2937', color: '#e5e7eb', border: 'none', borderRadius: 6, padding: '6px 10px' }} onClick={()=>setShowWithdrawModal(false)}>Cancel</button>
              <button style={{ background: '#ffffff', color: '#000000', border: 'none', borderRadius: 6, padding: '6px 10px' }} onClick={submitWithdraw}>Withdraw</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}


