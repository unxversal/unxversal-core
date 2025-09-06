import { useMemo, useState } from 'react';
import styles from './TradePanel.module.css';
import { useCurrentAccount, useSignAndExecuteTransaction } from '@mysten/dapp-kit';
import { DexClient } from '../../protocols/dex/dex';
import { getContracts } from '../../lib/env';
import { loadSettings } from '../../lib/settings.config';
import { Transaction } from '@mysten/sui/transactions';

export function TradePanel({ pool, mid }: { pool: string; mid: number }) {
  const acct = useCurrentAccount();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const { pkgUnxversal } = getContracts();
  const dex = useMemo(() => new DexClient(pkgUnxversal), [pkgUnxversal]);
  const [side, setSide] = useState<'buy' | 'sell'>('buy');
  const [mode, setMode] = useState<'market' | 'limit'>('market');
  const [price, setPrice] = useState<number>(mid || 0);
  const [qty, setQty] = useState<number>(0);
  const [submitting, setSubmitting] = useState(false);

  const s = loadSettings();
  const baseType = s.dex.baseType;
  const quoteType = s.dex.quoteType;
  const balanceManagerId = s.dex.balanceManagerId;
  const tradeProofId = s.dex.tradeProofId;
  const feeConfigId = s.dex.feeConfigId;
  const feeVaultId = s.dex.feeVaultId;

  const disabled = !acct?.address || !balanceManagerId || !tradeProofId || !feeConfigId || !feeVaultId || submitting;

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

  return (
    <div className={styles.root}>
      <div className={styles.tabs}>
        <button className={side==='buy'?styles.active:''} onClick={()=>setSide('buy')}>Buy</button>
        <button className={side==='sell'?styles.active:''} onClick={()=>setSide('sell')}>Sell</button>
      </div>
      <div className={styles.mode}>
        <button className={mode==='market'?styles.active:''} onClick={()=>setMode('market')}>Market</button>
        <button className={mode==='limit'?styles.active:''} onClick={()=>setMode('limit')}>Limit</button>
      </div>
      {mode==='limit' && (
        <label className={styles.field}>Price
          <input type="number" value={price} onChange={(e)=>setPrice(Number(e.target.value))} placeholder={mid?String(mid):'0'} />
        </label>
      )}
      <label className={styles.field}>Quantity
        <input type="number" value={qty} onChange={(e)=>setQty(Number(e.target.value))} />
      </label>
      <button disabled={disabled} className={styles.submit} onClick={() => void submit()}>{submitting? 'Submitting...' : `${side==='buy'?'Buy':'Sell'}`}</button>
      {!acct?.address && <div className={styles.note}>Connect wallet to trade.</div>}
    </div>
  );
}
