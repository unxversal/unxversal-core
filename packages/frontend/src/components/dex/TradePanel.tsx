import { useEffect, useMemo, useState } from 'react';
import styles from './TradePanel.module.css';
import { useCurrentAccount, useSignAndExecuteTransaction, useSuiClient } from '@mysten/dapp-kit';
import { DexClient } from '../../protocols/dex/dex';
import { getContracts } from '../../lib/env';
import { loadSettings } from '../../lib/settings.config';
import { Transaction } from '@mysten/sui/transactions';

export function TradePanel({ pool, mid }: { pool: string; mid: number }) {
  const acct = useCurrentAccount();
  const client = useSuiClient();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const { pkgUnxversal } = getContracts();
  const dex = useMemo(() => new DexClient(pkgUnxversal), [pkgUnxversal]);
  const [side, setSide] = useState<'buy' | 'sell'>('buy');
  const [mode, setMode] = useState<'market' | 'limit'>('market');
  const [price, setPrice] = useState<number>(mid || 0);
  const [qty, setQty] = useState<number>(0);
  const [submitting, setSubmitting] = useState(false);
  const [walletTab, setWalletTab] = useState<'assets' | 'staking'>('assets');
  const [baseBal, setBaseBal] = useState<number>(0);
  const [quoteBal, setQuoteBal] = useState<number>(0);
  const [activeStakeUnxv, setActiveStakeUnxv] = useState<number>(0);
  const [takerBps, setTakerBps] = useState<number>(70); // fallback 0.70 bps
  const [unxvDiscBps, setUnxvDiscBps] = useState<number>(3000); // fallback 30%

  const s = loadSettings();
  const baseType = s.dex.baseType;
  const quoteType = s.dex.quoteType;
  const balanceManagerId = s.dex.balanceManagerId;
  const tradeProofId = s.dex.tradeProofId;
  const feeConfigId = s.dex.feeConfigId;
  const feeVaultId = s.dex.feeVaultId;
  const stakingPoolId = s.staking?.poolId ?? '';

  const disabled = !acct?.address || !balanceManagerId || !tradeProofId || !feeConfigId || !feeVaultId || submitting;

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
        baseType, quoteType, poolId: pool, balanceManagerId, tradeProofId, feeConfigId, feeVaultId,
      } as const;
      const isBid = side === 'buy';
      if (mode === 'market') {
        tx = dex.placeMarketOrder({ ...common, clientOrderId: BigInt(Date.now()), selfMatchingOption: 0, quantity: BigInt(Math.floor(qty)), isBid, payWithDeep: false });
      } else {
        const p = Math.max(1, Math.floor(price));
        tx = dex.placeLimitOrder({ ...common, clientOrderId: BigInt(Date.now()), orderType: 0, selfMatchingOption: 0, price: BigInt(p), quantity: BigInt(Math.floor(qty)), isBid, payWithDeep: false, expireTimestamp: BigInt(Math.floor(Date.now()/1000)+120) });
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
        <div className={styles.orderTitle}>{mode === 'limit' ? 'Limit Order' : 'Market Order'}</div>
        <div className={styles.modeToggle}>
          <button className={mode==='limit'?styles.active:''} onClick={()=>setMode('limit')}>Limit</button>
          <button className={mode==='market'?styles.active:''} onClick={()=>setMode('market')}>Market</button>
        </div>
        
        <div className={styles.tabs}>
          <button className={side==='buy'?styles.active:''} onClick={()=>setSide('buy')}>Buy</button>
          <button className={side==='sell'?styles.active:''} onClick={()=>setSide('sell')}>Sell</button>
        </div>

        {mode==='limit' && (
          <div className={styles.field}>
            <label>Price</label>
            <div className={styles.inputGroup}>
              <input type="number" value={price || ''} onChange={(e)=>setPrice(Number(e.target.value))} placeholder={mid?String(mid):'0'} />
              <span className={styles.currency}>{quoteSym}</span>
            </div>
          </div>
        )}

        <div className={styles.field}>
          <label>{mode==='market' ? 'Amount (Input)' : 'Amount'}</label>
          <div className={styles.inputGroup}>
            <input type="number" value={qty || ''} onChange={(e)=>setQty(Number(e.target.value))} placeholder="0.00" />
            <span className={styles.currency}>{baseSym}</span>
          </div>
          <div className={styles.percentButtons}>
            <button onClick={() => applyPercent(0.25)}>25%</button>
            <button onClick={() => applyPercent(0.50)}>50%</button>
            <button onClick={() => applyPercent(0.75)}>75%</button>
            <button onClick={() => applyPercent(1)}>100%</button>
          </div>
        </div>

        <div className={styles.field}>
          <label>{mode==='market' ? 'Estimated Output' : 'Order Value'}</label>
          <div className={styles.valueDisplay}>
            <span>{(notionalQuote || 0).toFixed(4)}</span>
            <span className={styles.valueCurrency}>{quoteSym}</span>
          </div>
        </div>

        <div className={styles.feeSection}>
          <div className={styles.feeRow}><span>Fee (UNXV, discounted)</span><span>{feeUnxvDisc ? feeUnxvDisc.toFixed(6) : '-'} {quoteSym}</span></div>
          <div className={styles.feeRow}><span>Fee (Input)</span><span>{feeInput ? feeInput.toFixed(6) : '-'} {inputFeeSym}</span></div>
        </div>

        {!acct?.address ? (
          <button className={styles.connectWallet}>Connect Wallet</button>
        ) : (
          <button disabled={disabled} className={`${styles.submit} ${side==='buy'?styles.buyButton:styles.sellButton}`} onClick={() => void submit()}>
            {submitting ? 'Submitting...' : `${side==='buy'?'Buy':'Sell'}`}
          </button>
        )}
      </div>
    </div>
  );
}
