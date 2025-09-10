import { useEffect, useMemo, useState } from 'react';
import styles from './TradePanel.module.css';
import { useCurrentAccount, useSignAndExecuteTransaction, useSuiClient, ConnectButton } from '@mysten/dapp-kit';
import { DexClient } from '../../protocols/dex/dex';
import { getContracts } from '../../lib/env';
import { loadSettings } from '../../lib/settings.config';
import { Transaction } from '@mysten/sui/transactions';
import Slider from 'rc-slider';
import 'rc-slider/assets/index.css';

export function TradePanel({ pool, mid }: { pool: string; mid: number }) {
  const acct = useCurrentAccount();
  const client = useSuiClient();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const { pkgUnxversal } = getContracts();
  const dex = useMemo(() => new DexClient(pkgUnxversal), [pkgUnxversal]);
  const [side, setSide] = useState<'buy' | 'sell'>('buy');
  const [mode, setMode] = useState<'market' | 'limit' | 'margin'>('market');
  const [price, setPrice] = useState<number>(mid || 0);
  const [qty, setQty] = useState<number>(0);
  const [submitting, setSubmitting] = useState(false);
  const [walletTab, setWalletTab] = useState<'assets' | 'staking'>('assets');
  const [baseBal, setBaseBal] = useState<number>(0);
  const [quoteBal, setQuoteBal] = useState<number>(0);
  const [activeStakeUnxv, setActiveStakeUnxv] = useState<number>(0);
  const [takerBps, setTakerBps] = useState<number>(70); // fallback 0.70 bps
  const [unxvDiscBps, setUnxvDiscBps] = useState<number>(3000); // fallback 30%
  const [feeType, setFeeType] = useState<'unxv' | 'input'>('unxv');
  const [leverage, setLeverage] = useState<number>(2);

  const s = loadSettings();
  const baseType = s.dex.baseType;
  const quoteType = s.dex.quoteType;
  const balanceManagerId = s.dex.balanceManagerId;
  const feeConfigId = s.dex.feeConfigId;
  const feeVaultId = s.dex.feeVaultId;
  const stakingPoolId = s.staking?.poolId ?? '';

  const disabled = !acct?.address || !balanceManagerId || !feeConfigId || !feeVaultId || submitting;

  const [baseSym, quoteSym] = ((): [string, string] => {
    const src = pool.includes('-') ? pool : pool.replace(/_/g, '-');
    const parts = src.split('-');
    return [(parts[0] || 'BASE').toUpperCase(), (parts[1] || 'QUOTE').toUpperCase()];
  })();

  // Load coin metadata & balances
  useEffect(() => {
    let mounted = true;
    const load = async () => {
      if (!acct?.address) return;
      try {
        const [bm, qm, bb, qb] = await Promise.all([
          client.getCoinMetadata({ coinType: baseType }).catch(() => ({ decimals: 9 } as any)),
          client.getCoinMetadata({ coinType: quoteType }).catch(() => ({ decimals: 9 } as any)),
          client.getBalance({ owner: acct.address, coinType: baseType }).catch(() => ({ totalBalance: '0' } as any)),
          client.getBalance({ owner: acct.address, coinType: quoteType }).catch(() => ({ totalBalance: '0' } as any)),
        ]);
        if (!mounted) return;
        const bdec = Number((bm as any)?.decimals ?? 9);
        const qdec = Number((qm as any)?.decimals ?? 9);
        const bbal = Number((bb as any).totalBalance ?? '0') / 10 ** bdec;
        const qbal = Number((qb as any).totalBalance ?? '0') / 10 ** qdec;
        setBaseBal(bbal);
        setQuoteBal(qbal);
      } catch {}
    };
    void load();
    const id = setInterval(load, 5000);
    return () => { mounted = false; clearInterval(id); };
  }, [acct?.address, baseType, quoteType, client]);

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
    if (qty <= 0) return;
    setSubmitting(true);
    try {
      let tx: Transaction;
      const common = {
        baseType, quoteType, poolId: pool, balanceManagerId, feeConfigId, feeVaultId,
      } as const;
      const isBid = side === 'buy';
      if (mode === 'market') {
        tx = dex.placeMarketOrder({ ...common, clientOrderId: BigInt(Date.now()), selfMatchingOption: 0, quantity: BigInt(Math.floor(qty)), isBid, payWithDeep: false });
      } else if (mode === 'limit') {
        const p = Math.max(1, Math.floor(price));
        tx = dex.placeLimitOrder({ ...common, clientOrderId: BigInt(Date.now()), orderType: 0, selfMatchingOption: 0, price: BigInt(p), quantity: BigInt(Math.floor(qty)), isBid, payWithDeep: false, expireTimestamp: BigInt(Math.floor(Date.now()/1000)+120) });
      } else {
        // Margin trading - TODO: Implement margin order logic
        // This would involve: 1) Depositing collateral 2) Borrowing assets 3) Placing order
        // For now, fallback to market order behavior
        tx = dex.placeMarketOrder({ ...common, clientOrderId: BigInt(Date.now()), selfMatchingOption: 0, quantity: BigInt(Math.floor(qty)), isBid, payWithDeep: false });
      }
      await signAndExecute({ transaction: tx });
    } finally {
      setSubmitting(false);
    }
  }

  // Derived estimates
  const effPrice = mode === 'limit' ? (price || mid || 0) : (mid || price || 0);
  const notionalQuote = (qty || 0) * (effPrice || 0);
  const feeInput = notionalQuote * (takerBps / 10000);
  const feeUnxvDisc = notionalQuote * ((takerBps * (1 - unxvDiscBps / 10000)) / 10000);
  const inputFeeSym = side === 'buy' ? quoteSym : baseSym;
  
  // Automatic collateral selection based on margin trading logic
  const autoCollateralType = mode === 'margin' ? (side === 'buy' ? 'base' : 'quote') : 'base';
  const borrowFee = mode === 'margin' ? (qty || 0) * 0.001 : 0;
  const borrowAPR = 12.5; // Example APR - should come from protocol

  const applyPercent = (p: number) => {
    if (side === 'buy') {
      const spend = quoteBal * p;
      const pr = effPrice || 0;
      setQty(pr > 0 ? spend / pr : 0);
    } else {
      setQty(baseBal * p);
    }
  };

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
            <div className={styles.balanceRow}><span>{baseSym}:</span><span>{baseBal.toFixed(4)}</span></div>
            <div className={styles.balanceRow}><span>{quoteSym}:</span><span>{quoteBal.toFixed(4)}</span></div>
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
          <div className={styles.modeToggle}>
            <button className={mode==='limit'?styles.active:''} onClick={()=>setMode('limit')}>Limit</button>
            <button className={mode==='market'?styles.active:''} onClick={()=>setMode('market')}>Market</button>
            <button className={mode==='margin'?styles.active:''} onClick={()=>setMode('margin')}>Margin</button>
          </div>
          
          <div className={styles.tabs}>
            <button className={side==='buy'?styles.active:''} onClick={()=>setSide('buy')}>
              {mode === 'margin' ? 'Buy / Long' : 'Buy'}
            </button>
            <button className={side==='sell'?styles.active:''} onClick={()=>setSide('sell')}>
              {mode === 'margin' ? 'Sell / Short' : 'Sell'}
            </button>
          </div>
        </div>

        <div className={styles.contentArea}>
          {mode==='limit' && (
            <>
              <div className={styles.availableToTrade}>
                <div className={styles.availableLabel}>Available to Trade</div>
                <div className={styles.availableAmount}>
                  {(side === 'buy' ? quoteBal : baseBal).toFixed(4)} {side === 'buy' ? quoteSym : baseSym}
                </div>
              </div>
              
              <div className={styles.field}>
                <div className={styles.inputGroup}>
                  <input 
                    type="number" 
                    value={price || ''} 
                    onChange={(e)=>setPrice(Number(e.target.value))} 
                    placeholder={`Price (${quoteSym})`}
                    className={styles.inputWithLabel}
                  />
                  <span className={styles.midIndicator}>Mid</span>
                </div>
              </div>
            </>
          )}

          <div className={styles.field}>
            <div className={styles.inputGroup}>
              <input 
                type="number" 
                value={qty || ''} 
                onChange={(e)=>setQty(Number(e.target.value))} 
                placeholder={mode==='market' ? 'Amount (Input)' : mode==='margin' ? 'Position Size' : 'Size'} 
                className={styles.inputWithLabel}
              />
              <div className={styles.tokenSelector}>
                <span>{baseSym}</span>
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
                      const maxAmount = side === 'buy' ? quoteBal / (effPrice || 1) : baseBal;
                      return maxAmount > 0 ? Math.round((qty / maxAmount) * 100) : 0;
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
                      marginTop: -6
                    }}
                    trackStyle={{
                      backgroundColor: '#00d4aa',
                      height: 4
                    }}
                    railStyle={{
                      backgroundColor: '#1e2230',
                      height: 4
                    }}
                    dotStyle={{
                      backgroundColor: '#3a4553',
                      borderColor: '#1e2230',
                      width: 8,
                      height: 8,
                      marginTop: -2
                    }}
                    activeDotStyle={{
                      backgroundColor: '#00d4aa',
                      borderColor: '#00d4aa'
                    }}
                  />
                </div>
                <div className={styles.percentageDisplay}>
                  {(() => {
                    const maxAmount = side === 'buy' ? quoteBal / (effPrice || 1) : baseBal;
                    return maxAmount > 0 ? Math.round((qty / maxAmount) * 100) : 0;
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
                      placeholder="2.0"
                    />
                    <span>×</span>
                  </div>
                </div>
                <div className={styles.sliderContainer}>
                  <div className={styles.sliderWrapper}>
                    <Slider
                      min={0}
                      max={10}
                      step={0.1}
                      value={leverage}
                      onChange={(value: number | number[]) => {
                        setLeverage(value as number);
                      }}
                      dots
                      marks={{
                        0: '',
                        2.5: '',
                        5: '',
                        7.5: '',
                        10: ''
                      }}
                      handleStyle={{
                        backgroundColor: '#00d4aa',
                        borderColor: '#00d4aa',
                        width: 16,
                        height: 16,
                        marginTop: -6
                      }}
                      trackStyle={{
                        backgroundColor: '#00d4aa',
                        height: 4
                      }}
                      railStyle={{
                        backgroundColor: '#1e2230',
                        height: 4
                      }}
                      dotStyle={{
                        backgroundColor: '#3a4553',
                        borderColor: '#1e2230',
                        width: 8,
                        height: 8,
                        marginTop: -2
                      }}
                      activeDotStyle={{
                        backgroundColor: '#00d4aa',
                        borderColor: '#00d4aa'
                      }}
                    />
                  </div>
                </div>
              </div>

              <div className={styles.collateralInfo}>
                <div className={styles.marginRow}>
                  <span>Collateral ({autoCollateralType === 'base' ? baseSym : quoteSym})</span>
                  <span>{leverage > 0 ? ((qty || 0) / leverage).toFixed(4) : '0.0000'} {autoCollateralType === 'base' ? baseSym : quoteSym}</span>
                </div>
                <div className={styles.marginRow}>
                  <span>Borrowing</span>
                  <span>{(qty || 0).toFixed(4)} {side === 'buy' ? baseSym : quoteSym}</span>
                </div>
              </div>

              <div className={styles.marginInfo}>
                <div className={styles.marginRow}>
                  <span>Liquidation Price</span>
                  <span>
                    {(() => {
                      const entryPrice = effPrice || 0;
                      const liqPrice = side === 'buy' 
                        ? entryPrice * (1 - 0.75/leverage)
                        : entryPrice * (1 + 0.75/leverage);
                      return liqPrice.toFixed(4);
                    })()} {quoteSym}
                  </span>
                </div>
              </div>
            </>
          )}

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
              
              {mode === 'margin' && (
                <>
                  <div className={styles.feeRow}>
                    <span>Borrow Fee</span>
                    <span>
                      {feeType === 'unxv' 
                        ? (borrowFee * (side === 'buy' ? (effPrice || 1) : 1)).toFixed(6) + ' UNXV'
                        : borrowFee.toFixed(6) + ' ' + (side === 'buy' ? baseSym : quoteSym)
                      }
                    </span>
                  </div>
                  <div className={styles.feeRow}>
                    <span>Borrow APR</span>
                    <span>{borrowAPR}%</span>
                  </div>
                  <div className={styles.feeRow}>
                    <span className={styles.totalFeeLabel}>Total Fee</span>
                    <span className={styles.totalFeeAmount}>
                      {feeType === 'unxv' 
                        ? ((feeUnxvDisc || 0) + (borrowFee * (side === 'buy' ? (effPrice || 1) : 1))).toFixed(6) + ' UNXV'
                        : ((feeInput || 0) + (borrowFee * (side === 'buy' ? (effPrice || 1) : 1))).toFixed(6) + ' ' + inputFeeSym
                      }
                    </span>
                  </div>
                </>
              )}
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
              disabled={disabled} 
              className={`${styles.submit} ${side==='buy'?styles.buyButton:styles.sellButton}`} 
              onClick={() => void submit()}
              title={!qty || qty <= 0 ? 'Enter a quantity to continue' : ''}
            >
              {submitting 
                ? 'Submitting...' 
                : !qty || qty <= 0 
                  ? `Enter ${mode === 'margin' ? 'Position' : 'Amount'} to ${side === 'buy' ? 'Buy' : 'Sell'}` 
                  : `${side === 'buy' ? 'Buy' : 'Sell'} ${qty.toLocaleString()}`
              }
            </button>
          )}

          <div className={styles.deepbookBranding}>
            <span className={styles.poweredByText}>Powered by</span>
            <img src="/deepbooklogo.svg" alt="DeepBook" className={styles.deepbookLogo} />
          </div>
        </div>
      </div>
    </div>
  );
}
