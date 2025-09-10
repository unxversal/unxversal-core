import { useEffect, useMemo, useState } from 'react';
import styles from './SwapScreen.module.css';
import { useCurrentAccount, useSignAndExecuteTransaction, useSuiClient, ConnectButton } from '@mysten/dapp-kit';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';
import { DexClient } from '../../protocols/dex/dex';
import { getContracts } from '../../lib/env';
import { loadSettings, getAllTokenSymbols, getTokenBySymbol, getTokenTypeTag, type TokenInfo } from '../../lib/settings.config';
import { Transaction } from '@mysten/sui/transactions';

type Props = {
  network: 'testnet' | 'mainnet';
};

export function SwapScreen({ network }: Props) {
  const acct = useCurrentAccount();
  const client = useSuiClient();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const { pkgUnxversal } = getContracts();
  const s = loadSettings();
  const dex = useMemo(() => new DexClient(pkgUnxversal), [pkgUnxversal]);
  const indexer = useMemo(() => buildDeepbookPublicIndexer(s.dex.deepbookIndexerUrl), [s.dex.deepbookIndexerUrl]);

  const [fromSymbol, setFromSymbol] = useState<string>('DEEP');
  const [toSymbol, setToSymbol] = useState<string>('SUI');
  const [amountIn, setAmountIn] = useState<number>(0);
  const [quoteOut, setQuoteOut] = useState<number>(0);
  const [midPrice, setMidPrice] = useState<number>(0);
  const [slippageBps, setSlippageBps] = useState<number>(30); // 0.3%
  const [submitting, setSubmitting] = useState<boolean>(false);
  const [poolId, setPoolId] = useState<string | null>(null);
  const [fromBalance, setFromBalance] = useState<number>(0);
  const [toBalance, setToBalance] = useState<number>(0);
  const [fromDecimals, setFromDecimals] = useState<number>(9);
  const [toDecimals, setToDecimals] = useState<number>(9);

  const allSymbols = useMemo(() => getAllTokenSymbols(s), [s]);
  const fromToken: TokenInfo | undefined = getTokenBySymbol(fromSymbol, s);
  const toToken: TokenInfo | undefined = getTokenBySymbol(toSymbol, s);

  // Fetch mid price using indexer ticker
  useEffect(() => {
    let mounted = true;
    const pair = `${fromSymbol}/${toSymbol}`.toUpperCase();
    async function load() {
      try {
        const t = await indexer.ticker();
        const key = pair.replace(/[\/_-]/g, '_');
        const row = (t as any)[key];
        const last = row?.last_price;
        if (mounted) setMidPrice(Number(last) || 0);
      } catch {
        if (mounted) setMidPrice(0);
      }
    }
    void load();
    const id = setInterval(load, 3000);
    return () => { mounted = false; clearInterval(id); };
  }, [indexer, fromSymbol, toSymbol]);

  // Resolve DeepBook pool id for selected pair
  useEffect(() => {
    let mounted = true;
    async function resolvePool() {
      try {
        const pools = await indexer.getPools();
        const target = `${fromSymbol}_${toSymbol}`.toUpperCase();
        const alt = `${toSymbol}_${fromSymbol}`.toUpperCase();
        const p = pools.find((x: any) => x.pool_name?.toUpperCase() === target || x.pool_name?.toUpperCase() === alt);
        if (mounted) setPoolId(p?.pool_id ?? null);
      } catch {
        if (mounted) setPoolId(null);
      }
    }
    void resolvePool();
  }, [indexer, fromSymbol, toSymbol]);

  // Load balances and decimals for both tokens
  useEffect(() => {
    let mounted = true;
    async function load() {
      try {
        const f = getTokenBySymbol(fromSymbol, s);
        const t = getTokenBySymbol(toSymbol, s);
        const fType = f ? getTokenTypeTag(f) : '';
        const tType = t ? getTokenTypeTag(t) : '';
        const [fm, tm, fb, tb] = await Promise.all([
          fType ? client.getCoinMetadata({ coinType: fType }).catch(() => ({ decimals: 9 } as any)) : ({ decimals: 9 } as any),
          tType ? client.getCoinMetadata({ coinType: tType }).catch(() => ({ decimals: 9 } as any)) : ({ decimals: 9 } as any),
          acct?.address && fType ? client.getBalance({ owner: acct.address, coinType: fType }).catch(() => ({ totalBalance: '0' } as any)) : ({ totalBalance: '0' } as any),
          acct?.address && tType ? client.getBalance({ owner: acct.address, coinType: tType }).catch(() => ({ totalBalance: '0' } as any)) : ({ totalBalance: '0' } as any),
        ]);
        if (!mounted) return;
        const fd = Number((fm as any)?.decimals ?? 9);
        const td = Number((tm as any)?.decimals ?? 9);
        setFromDecimals(fd);
        setToDecimals(td);
        setFromBalance(Number((fb as any).totalBalance ?? '0') / 10 ** fd);
        setToBalance(Number((tb as any).totalBalance ?? '0') / 10 ** td);
      } catch {
        if (!mounted) return;
        setFromBalance(0);
        setToBalance(0);
      }
    }
    void load();
  }, [client, acct?.address, fromSymbol, toSymbol, s]);

  // Update output quote when input or price changes
  useEffect(() => {
    if (!amountIn || amountIn <= 0 || !midPrice) { setQuoteOut(0); return; }
    setQuoteOut(amountIn * midPrice);
  }, [amountIn, midPrice]);

  const canSubmit = Boolean(
    acct?.address && fromToken && toToken && amountIn > 0 && poolId && s.dex.balanceManagerId && s.dex.tradeProofId && s.dex.feeConfigId && s.dex.feeVaultId
  );

  async function submitSwap(): Promise<void> {
    if (!canSubmit || !fromToken || !toToken) return;
    setSubmitting(true);
    try {
      // We implement swap as a DEX market order on pair FROM/TO.
      // Determine orientation of DeepBook pool and whether we are bidding or asking.
      const poolName = `${fromSymbol}/${toSymbol}`;
      const baseSym = poolName.split('/')[0];
      const [baseType, quoteType] = baseSym === fromSymbol
        ? [getTokenTypeTag(fromToken), getTokenTypeTag(toToken)]
        : [getTokenTypeTag(toToken), getTokenTypeTag(fromToken)];

      const isBid = baseSym !== fromSymbol; // if base != from, we are buying base with quote

      // Quantity is in base units for DeepBook; approximate from amountIn and price
      const quantity = isBid ? Math.floor((amountIn / (midPrice || 1)) ) : Math.floor(amountIn);

      const tx: Transaction = dex.placeMarketOrder({
        baseType,
        quoteType,
        poolId: poolId!,
        balanceManagerId: s.dex.balanceManagerId,
        tradeProofId: s.dex.tradeProofId,
        feeConfigId: s.dex.feeConfigId,
        feeVaultId: s.dex.feeVaultId,
        clientOrderId: BigInt(Date.now()),
        selfMatchingOption: 0,
        quantity: BigInt(quantity > 0 ? quantity : 1),
        isBid,
        payWithDeep: false,
      });
      await signAndExecute({ transaction: tx });
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className={styles.root}>
      <div className={styles.container}>
        <div className={styles.topBar}>
          <div className={styles.toggle}>
            <span>Aggregator Mode</span>
          </div>
          <button className={styles.slippage} onClick={() => setSlippageBps(b => (b === 30 ? 50 : 30))}>
            <span>{(slippageBps / 100).toFixed(1)}% slippage</span>
          </button>
        </div>

        {/* From card */}
        <div className={styles.card}>
          <div className={styles.cardHeader}>
            <span>Selling</span>
            <span className={styles.balance}>0 {fromSymbol}</span>
          </div>
          <div className={styles.row}>
            <input
              className={styles.amountInput}
              value={amountIn || ''}
              onChange={(e) => setAmountIn(Number(e.target.value))}
              type="number"
              placeholder="0"
            />
            <div className={styles.tokenSelect}>
              <button className={styles.tokenButton}>
                {fromToken?.iconUrl ? <img src={fromToken.iconUrl} alt={fromSymbol} /> : null}
                <span>{fromSymbol}</span>
              </button>
              <select value={fromSymbol} onChange={(e) => setFromSymbol(e.target.value)}>
                {allSymbols.map((s) => (
                  <option value={s} key={s}>{s}</option>
                ))}
              </select>
            </div>
          </div>
        </div>

        <div className={styles.switcherWrap}>
          <button
            className={styles.switcher}
            onClick={() => { setFromSymbol(toSymbol); setToSymbol(fromSymbol); }}
            title="Swap direction"
          >
            ⇅
          </button>
        </div>

        {/* To card */}
        <div className={styles.card}>
          <div className={styles.cardHeader}>
            <span>Buying</span>
            <span className={styles.balance}>0 {toSymbol}</span>
          </div>
          <div className={styles.row}>
            <input
              className={styles.amountInput}
              value={quoteOut || ''}
              readOnly
              placeholder="0"
            />
            <div className={styles.tokenSelect}>
              <button className={styles.tokenButton}>
                {toToken?.iconUrl ? <img src={toToken.iconUrl} alt={toSymbol} /> : null}
                <span>{toSymbol}</span>
              </button>
              <select value={toSymbol} onChange={(e) => setToSymbol(e.target.value)}>
                {allSymbols.filter(s => s !== fromSymbol).map((s) => (
                  <option value={s} key={s}>{s}</option>
                ))}
              </select>
            </div>
          </div>
        </div>

        {!acct?.address ? (
          <ConnectButton />
        ) : (
          <button className={styles.submit} onClick={() => void submitSwap()} disabled={!canSubmit || submitting}>
            {submitting ? 'Submitting...' : 'Swap'}
          </button>
        )}

        <div className={styles.routeRow}>
          <span>{fromSymbol} → {toSymbol}</span>
          <span>1 {fromSymbol} ≈ {midPrice ? (1 * midPrice).toFixed(6) : '-'} {toSymbol}</span>
        </div>
        <div className={styles.hint}>Total swaps: 1</div>
      </div>
    </div>
  );
}

export default SwapScreen;


