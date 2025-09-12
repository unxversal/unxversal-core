import { useEffect, useState } from 'react';
import styles from './TradePanel.module.css';
import { useCurrentAccount, useSignAndExecuteTransaction, useSuiClient, ConnectButton } from '@mysten/dapp-kit';
// DeepBook TS SDK
import { DeepBookClient } from '@mysten/deepbook-v3';
import { getContracts } from '../../lib/env';
import { loadSettings, updateSettings } from '../../lib/settings.config';
import { createAndShareBalanceManagerTx, depositToBalanceManagerTx, withdrawFromBalanceManagerTx } from '../../protocols/dex';
import { Transaction } from '@mysten/sui/transactions';
import { DexClient } from '../../clients';
import Slider from 'rc-slider';
import 'rc-slider/assets/index.css';

export function TradePanel({ pool, mid }: { pool: string; mid: number }) {
  const acct = useCurrentAccount();
  const client = useSuiClient();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const { pkgUnxversal, pkgDeepbook } = getContracts();
  const [side, setSide] = useState<'buy' | 'sell'>('buy');
  const [mode, setMode] = useState<'market' | 'limit' | 'margin' | 'flash'>('market');
  const [price, setPrice] = useState<number>(mid || 0);
  const [qty, setQty] = useState<number>(0);
  const [submitting, setSubmitting] = useState(false);
  const [walletTab, setWalletTab] = useState<'assets' | 'staking'>('assets');
  const [baseBal, setBaseBal] = useState<number>(0);
  const [quoteBal, setQuoteBal] = useState<number>(0);
  const [activeStakeUnxv, setActiveStakeUnxv] = useState<number>(0);
  // Using makerBps for UI estimates; takerBps omitted
  const [makerBps, setMakerBps] = useState<number>(70);
  const [unxvDiscBps, setUnxvDiscBps] = useState<number>(3000); // fallback 30%
  const [feeType, setFeeType] = useState<'unxv' | 'input'>('unxv');
  const [leverage, setLeverage] = useState<number>(2);
  const [bmId, setBmId] = useState<string>(loadSettings().dex.balanceManagerId || '');
  const [baseCoins, setBaseCoins] = useState<Array<{ id: string; balance: bigint }>>([]);
  const [quoteCoins, setQuoteCoins] = useState<Array<{ id: string; balance: bigint }>>([]);
  const [unxvCoins, setUnxvCoins] = useState<Array<{ id: string; balance: bigint }>>([]);
  const [selFeeCoinId, setSelFeeCoinId] = useState<string>('');
  const [selUnxvCoinId, setSelUnxvCoinId] = useState<string>('');
  const [flashSrc, setFlashSrc] = useState<'deepbook' | 'lending'>('deepbook');
  const s = loadSettings();
  
  // Flash loan four-step process state
  const [flashBorrowAsset, setFlashBorrowAsset] = useState<string>('');
  const [flashBorrowAmount, setFlashBorrowAmount] = useState<number>(0);
  const [flashBuyAmount, setFlashBuyAmount] = useState<number>(0);
  const [flashBuyPrice, setFlashBuyPrice] = useState<number>(0);
  const [flashSellAmount, setFlashSellAmount] = useState<number>(0);
  const [flashSellPrice, setFlashSellPrice] = useState<number>(0);

  const baseType = s.dex.baseType;
  const quoteType = s.dex.quoteType;
  const balanceManagerId = bmId || s.dex.balanceManagerId;
  const feeConfigId = s.dex.feeConfigId;
  const feeVaultId = s.dex.feeVaultId;
  const stakingPoolId = s.staking?.poolId ?? '';

  const buttonDisabled = submitting || !acct?.address || (!feeConfigId || !feeVaultId) || (mode !== 'flash' && !balanceManagerId) || (mode === 'flash' && !selFeeCoinId);

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

  // Load coin objects for fee selection
  useEffect(() => {
    let live = true;
    (async () => {
      if (!acct?.address) return;
      try {
        const [bc, qc] = await Promise.all([
          client.getCoins({ owner: acct.address, coinType: baseType, limit: 200 }).catch(() => ({ data: [] as any[] })),
          client.getCoins({ owner: acct.address, coinType: quoteType, limit: 200 }).catch(() => ({ data: [] as any[] })),
        ]);
        if (!live) return;
        const b = (bc.data ?? []).map((c: any) => ({ id: c.coinObjectId, balance: BigInt(c.balance ?? '0') }));
        const q = (qc.data ?? []).map((c: any) => ({ id: c.coinObjectId, balance: BigInt(c.balance ?? '0') }));
        setBaseCoins(b.sort((a,b)=> Number(b.balance - a.balance)));
        setQuoteCoins(q.sort((a,b)=> Number(b.balance - a.balance)));
        if (!selFeeCoinId) setSelFeeCoinId((side==='buy'?q:b)[0]?.id ?? '');
      } catch {}
      try {
        const unxvType = `${pkgUnxversal}::unxv::UNXV`;
        const uc = await client.getCoins({ owner: acct.address, coinType: unxvType, limit: 200 }).catch(() => ({ data: [] as any[] }));
        if (!live) return;
        const u = (uc.data ?? []).map((c: any) => ({ id: c.coinObjectId, balance: BigInt(c.balance ?? '0') }));
        setUnxvCoins(u.sort((a,b)=> Number(b.balance - a.balance)));
        if (!selUnxvCoinId && u.length) setSelUnxvCoinId(u[0].id);
      } catch {}
    })();
    return () => { live = false; };
  }, [acct?.address, client, baseType, quoteType, side, pkgUnxversal, selFeeCoinId, selUnxvCoinId]);

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
        const mbps = Number(f?.dex_maker_fee_bps ?? bps) || bps;
        const disc = Number(f?.unxv_discount_bps ?? 3000);
        if (!mounted) return;
        // Use maker bps for UI fee estimate baseline
        setMakerBps(mbps);
        setUnxvDiscBps(disc);
      } catch {}
    };
    void load();
  }, [feeConfigId, client]);

  // protocol fee estimation handled by DeepBook; UI estimates remain below

  async function onCreateBM(): Promise<void> {
    if (!pkgDeepbook) return;
    setSubmitting(true);
    try {
      const tx = await createAndShareBalanceManagerTx(pkgDeepbook);
      const res = await signAndExecute({ transaction: tx });
      const changes = (res as any)?.objectChanges as Array<any> | undefined;
      const created = changes?.find(c => c.type === 'created' && typeof c.objectType === 'string' && c.objectType.includes('balance_manager::BalanceManager'));
      const id = created?.objectId as string | undefined;
      if (id) {
        setBmId(id);
        updateSettings(cur => ({ ...cur, dex: { ...cur.dex, balanceManagerId: id } }));
      }
    } finally { setSubmitting(false); }
  }

  async function onDepositToBM(which: 'base' | 'quote'): Promise<void> {
    if (!pkgDeepbook || !balanceManagerId) return;
    const list = which === 'base' ? baseCoins : quoteCoins;
    const coinType = which === 'base' ? baseType : quoteType;
    const id = list[0]?.id;
    if (!id) return;
    setSubmitting(true);
    try {
      const tx = await depositToBalanceManagerTx(
        pkgDeepbook,
        pkgUnxversal,
        balanceManagerId,
        id,
        coinType,
        feeConfigId,
        feeVaultId,
        stakingPoolId,
        feeType === 'unxv' ? selUnxvCoinId || undefined : undefined,
      );
      await signAndExecute({ transaction: tx });
    } finally { setSubmitting(false); }
  }

  async function onWithdrawFromBM(which: 'base' | 'quote', amountUi: number): Promise<void> {
    if (!pkgDeepbook || !balanceManagerId) return;
    const coinType = which === 'base' ? baseType : quoteType;
    const amt = BigInt(Math.floor(Math.max(0, amountUi)));
    setSubmitting(true);
    try {
      const tx = await withdrawFromBalanceManagerTx(pkgDeepbook, balanceManagerId, amt, coinType);
      await signAndExecute({ transaction: tx });
    } finally { setSubmitting(false); }
  }

  async function submit(): Promise<void> {
    if (qty <= 0) return;
    setSubmitting(true);
    try {
      if (!acct?.address) throw new Error('Connect wallet');
      if (!balanceManagerId) throw new Error('Create a BalanceManager first');

      const network = loadSettings().network === 'mainnet' ? 'mainnet' as const : 'testnet' as const;
      const tx = new Transaction();
      const balanceManagerKey = 'MANAGER_1';
      const dbClient = new DeepBookClient({
        address: acct.address,
        env: network,
        client: client as any,
        balanceManagers: { [balanceManagerKey]: { address: balanceManagerId, tradeCap: undefined } } as any,
      });

      const isBid = side === 'buy';
      const clientOrderId = String(Date.now());
      const payWithDeep = false; // default to input-token fee; toggle later if needed

      if (mode === 'market') {
        tx.add((ttx: any) => (dbClient.deepBook.placeMarketOrder({
          poolKey: pool,
          balanceManagerKey,
          clientOrderId,
          quantity: Number(Math.floor(qty)),
          isBid,
          payWithDeep,
        }) as any)(ttx));
      } else if (mode === 'limit') {
        const p = Math.max(1, Math.floor(price));
        tx.add((ttx: any) => (dbClient.deepBook.placeLimitOrder({
          poolKey: pool,
          balanceManagerKey,
          clientOrderId,
          orderType: 0,
          selfMatchingOption: 0,
          price: Number(p),
          quantity: Number(Math.floor(qty)),
          isBid,
          payWithDeep,
          expiration: Math.floor(Date.now() / 1000) + 120,
        }) as any)(ttx));
      } else {
        tx.add((ttx: any) => (dbClient.deepBook.placeMarketOrder({
          poolKey: pool,
          balanceManagerKey,
          clientOrderId,
          quantity: Number(Math.floor(qty)),
          isBid,
          payWithDeep,
        }) as any)(ttx));
      }

      await signAndExecute({ transaction: tx });
    } finally {
      setSubmitting(false);
    }
  }


  async function onFlashLoanExecute(): Promise<void> {
    if (!flashBorrowAmount || flashBorrowAmount <= 0) return;
    if (flashSrc === 'deepbook') {
      await onFlashLoanDeepBookNew();
    } else {
      await onFlashLoanLendingNew();
    }
  }

  async function onFlashLoanDeepBookNew(): Promise<void> {
    if (!acct?.address) return;
    setSubmitting(true);
    try {
      const network = loadSettings().network === 'mainnet' ? 'mainnet' as const : 'testnet' as const;
      const tx = new Transaction();
      const dex = new DexClient({ env: network, client: client as any, address: acct.address, pkgUnxversal });
      const borrowPoolKey = flashBorrowAsset || (flashSrc === 'deepbook' ? 'DEEP_SUI' : pool);
      const borrowAmount = Math.max(1, Math.floor(flashBorrowAmount || 1));
      const feePaymentCoinType = side === 'buy' ? quoteType : baseType;
      dex.flashLoanDeepBook(tx as any, {
        feeConfigId,
        feeVaultId,
        stakingPoolId,
        feePaymentCoinId: selFeeCoinId,
        feePaymentCoinType,
        maybeUnxvCoinId: feeType === 'unxv' ? selUnxvCoinId || undefined : undefined,
        borrowPoolKey,
        borrowAmount,
        tradePoolKey: pool,
        tradeDirection: side === 'buy' ? 'quote->base' : 'base->quote',
        tradeAmount: Math.max(0.000001, flashBuyAmount || flashSellAmount || 0.000001),
        minOut: 0,
      });
      await signAndExecute({ transaction: tx });
    } finally { setSubmitting(false); }
  }

  async function onFlashLoanLendingNew(): Promise<void> {
    if (!acct?.address) return;
    const s = loadSettings();
    const pkg = s.contracts.pkgUnxversal;
    if (!pkg) return;
    setSubmitting(true);
    try {
      const network = s.network === 'mainnet' ? 'mainnet' as const : 'testnet' as const;
      const tx = new Transaction();
      const dex = new DexClient({ env: network, client: client as any, address: acct.address, pkgUnxversal: pkg });
      const marketId = flashBorrowAsset || ((s as any).lending?.marketId as string);
      const collatType = s.dex.baseType;
      const debtType = s.dex.quoteType;
      if (!marketId) throw new Error('Configure lending marketId in settings or enter asset type');
      dex.flashLoanLending(tx as any, {
        feeConfigId,
        feeVaultId,
        stakingPoolId,
        feePaymentCoinId: selFeeCoinId,
        feePaymentCoinType: side === 'buy' ? quoteType : baseType,
        maybeUnxvCoinId: feeType === 'unxv' ? selUnxvCoinId || undefined : undefined,
        marketId,
        collatType,
        debtType,
        amount: Math.max(1, Math.floor(flashBorrowAmount || 1)),
        tradePoolKey: pool,
        tradeDirection: side === 'buy' ? 'quote->base' : 'base->quote',
        tradeAmount: Math.max(0.000001, flashBuyAmount || flashSellAmount || 0.000001),
        minOut: 0,
      });
      await signAndExecute({ transaction: tx });
    } finally { setSubmitting(false); }
  }


  // Calculate repay amount for flash loan (borrow amount + fees)
  function calculateFlashRepayAmount(): number {
    const borrowAmt = flashBorrowAmount || 0;
    const flashFeeRate = 0.0009; // 0.09% flash loan fee (typical rate)
    return borrowAmt * (1 + flashFeeRate);
  }

  // Get symbol from asset string
  function getAssetSymbol(asset: string): string {
    if (asset === baseType) return baseSym;
    if (asset === quoteType) return quoteSym;
    return asset.split('::').pop()?.toUpperCase() || 'ASSET';
  }

  // Flash loan asset logic based on trading pair and side
  function getFlashBorrowAsset(): string {
    // If buying: borrow quote asset (USDC) to buy base asset (SUI)
    // If selling: borrow base asset (SUI) to sell for quote asset (USDC)
    return side === 'buy' ? quoteSym : baseSym;
  }

  function getFlashBuyAsset(): string {
    // Always buying the base asset
    return baseSym;
  }

  function getFlashSellAsset(): string {
    // Always selling for the quote asset
    return quoteSym;
  }

  function getFlashRepayAsset(): string {
    // Repay the same asset that was borrowed
    return getFlashBorrowAsset();
  }

  // Derived estimates
  const effPrice = mode === 'limit' ? (price || mid || 0) : (mid || price || 0);
  const notionalQuote = (qty || 0) * (effPrice || 0);
  const feeInput = notionalQuote * (makerBps / 10000);
  const feeUnxvDisc = notionalQuote * ((makerBps * (1 - unxvDiscBps / 10000)) / 10000);
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
        
        {/* BalanceManager Section */}
        <div className={styles.bmSection}>
          <div className={styles.bmHeader}>
            <span className={styles.bmTitle}>Balance Manager</span>
            {balanceManagerId ? (
              <span className={styles.bmStatus}>{balanceManagerId.slice(0,6)}…{balanceManagerId.slice(-4)}</span>
            ) : (
              <button className={styles.bmCreateBtn} disabled={submitting} onClick={() => void onCreateBM()}>Create</button>
            )}
          </div>
          {balanceManagerId && (
            <div className={styles.bmActions}>
              <button className={styles.miniButton} disabled={submitting} onClick={() => void onDepositToBM('base')}>Deposit {baseSym}</button>
              <button className={styles.miniButton} disabled={submitting} onClick={() => void onDepositToBM('quote')}>Deposit {quoteSym}</button>
              <button className={styles.miniButton} disabled={submitting} onClick={() => void onWithdrawFromBM('base', qty || 0)}>Withdraw {baseSym}</button>
              <button className={styles.miniButton} disabled={submitting} onClick={() => void onWithdrawFromBM('quote', qty || 0)}>Withdraw {quoteSym}</button>
            </div>
          )}
        </div>
        {walletTab==='assets' ? (
          <div className={styles.balances}>
            <div className={styles.balanceRow}><span>{baseSym}:</span><span className={styles.balanceAmount}>{baseBal.toFixed(4)}</span></div>
            <div className={styles.balanceRow}><span>{quoteSym}:</span><span className={styles.balanceAmount}>{quoteBal.toFixed(4)}</span></div>
          </div>
        ) : (
          <div className={styles.balances}>
            <div className={styles.balanceRow}><span>Active UNXV:</span><span className={styles.balanceAmount}>{activeStakeUnxv.toLocaleString(undefined,{maximumFractionDigits:2})}</span></div>
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
            <button className={mode==='flash'?styles.active:''} onClick={()=>setMode('flash')}>Flash</button>
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
                placeholder={mode==='market' ? 'Amount (Input)' : mode==='margin' ? 'Position Size' : mode==='flash' ? 'Trade Amount' : 'Size'} 
                className={styles.inputWithLabel}
              />
              <div className={styles.tokenSelector}>
                <span>{baseSym}</span>
                <svg className={styles.dropdownIcon} width="12" height="8" viewBox="0 0 12 8" fill="none">
                  <path d="M1 1L6 6L11 1" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
              </div>
            </div>
            {mode !== 'margin' && mode !== 'flash' && (
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

          {mode==='flash' && (
            <>
              <div className={styles.field}>
                <div className={styles.inputGroup}>
                  <div className={styles.tabs}>
                    <button className={flashSrc==='deepbook'?styles.active:''} onClick={()=>setFlashSrc('deepbook')}>DeepBook</button>
                    <button className={flashSrc==='lending'?styles.active:''} onClick={()=>setFlashSrc('lending')}>Lending</button>
                  </div>
                </div>
              </div>

              {/* Flash Loan Four-Step Process */}
              <div className={styles.flashLoanFlow}>
                {/* Step 1: Borrow */}
                <div className={styles.flashStep}>
                  <div className={styles.flashStepTopLeft}>
                    <span className={styles.flashStepNumber}>1</span>
                    <span className={styles.flashStepTitle}>Borrow</span>
                  </div>
                  <div className={styles.flashStepTopRight}>
                    <div className={styles.flashStepAssetLabel}>
                      {flashSrc === 'deepbook' ? 'Pool' : 'Asset'}
                    </div>
                    {flashSrc === 'deepbook' ? (
                      <div className={styles.flashStepAsset}>{getFlashBorrowAsset()}</div>
                    ) : (
                      <input
                        type="text"
                        value={flashBorrowAsset || getFlashBorrowAsset()}
                        onChange={(e) => setFlashBorrowAsset(e.target.value)}
                        placeholder="Asset Type"
                        className={styles.flashStepAssetInput}
                      />
                    )}
                  </div>
                  <div className={styles.flashStepBottomLeft}>
                    <div className={styles.flashStepAmountLabel}>Borrow Amount</div>
                    <input
                      type="number"
                      value={flashBorrowAmount || ''}
                      onChange={(e) => setFlashBorrowAmount(Number(e.target.value))}
                      placeholder="Amount"
                      className={styles.flashStepAmountInput}
                    />
                  </div>
                  <div className={styles.flashStepBottomRight}>
                    <div className={styles.flashStepPriceLabel}>Fee Rate</div>
                    <div className={styles.flashStepPriceDisplay}>0.09%</div>
                  </div>
                </div>

                {/* Step 2: Buy */}
                <div className={styles.flashStep}>
                  <div className={styles.flashStepTopLeft}>
                    <span className={styles.flashStepNumber}>2</span>
                    <span className={styles.flashStepTitle}>Buy</span>
                  </div>
                  <div className={styles.flashStepTopRight}>
                    <div className={styles.flashStepAssetLabel}>Asset</div>
                    <div className={styles.flashStepAsset}>{getFlashBuyAsset()}</div>
                  </div>
                  <div className={styles.flashStepBottomLeft}>
                    <div className={styles.flashStepAmountLabel}>Buy Amount</div>
                    <input
                      type="number"
                      value={flashBuyAmount || ''}
                      onChange={(e) => setFlashBuyAmount(Number(e.target.value))}
                      placeholder="Amount"
                      className={styles.flashStepAmountInput}
                    />
                  </div>
                  <div className={styles.flashStepBottomRight}>
                    <div className={styles.flashStepPriceLabel}>Buy Price</div>
                    <input
                      type="number"
                      value={flashBuyPrice || ''}
                      onChange={(e) => setFlashBuyPrice(Number(e.target.value))}
                      placeholder="Price"
                      className={styles.flashStepPriceInput}
                    />
                  </div>
                </div>

                {/* Step 3: Sell */}
                <div className={styles.flashStep}>
                  <div className={styles.flashStepTopLeft}>
                    <span className={styles.flashStepNumber}>3</span>
                    <span className={styles.flashStepTitle}>Sell</span>
                  </div>
                  <div className={styles.flashStepTopRight}>
                    <div className={styles.flashStepAssetLabel}>Sell For</div>
                    <div className={styles.flashStepAsset}>{getFlashSellAsset()}</div>
                  </div>
                  <div className={styles.flashStepBottomLeft}>
                    <div className={styles.flashStepAmountLabel}>Sell Amount</div>
                    <input
                      type="number"
                      value={flashSellAmount || flashBuyAmount}
                      onChange={(e) => setFlashSellAmount(Number(e.target.value))}
                      placeholder="Amount"
                      className={styles.flashStepAmountInput}
                    />
                  </div>
                  <div className={styles.flashStepBottomRight}>
                    <div className={styles.flashStepPriceLabel}>Sell Price</div>
                    <input
                      type="number"
                      value={flashSellPrice || ''}
                      onChange={(e) => setFlashSellPrice(Number(e.target.value))}
                      placeholder="Price"
                      className={styles.flashStepPriceInput}
                    />
                  </div>
                </div>

                {/* Step 4: Repay (Auto-calculated) */}
                <div className={styles.flashStep}>
                  <div className={styles.flashStepTopLeft}>
                    <span className={styles.flashStepNumber}>4</span>
                    <span className={styles.flashStepTitle}>Repay (Auto)</span>
                  </div>
                  <div className={styles.flashStepTopRight}>
                    <div className={styles.flashStepAssetLabel}>Asset</div>
                    <div className={styles.flashStepAsset}>{getFlashRepayAsset()}</div>
                  </div>
                  <div className={styles.flashStepBottomLeft}>
                    <div className={styles.flashStepAmountLabel}>Repay Amount</div>
                    <div className={styles.flashStepAmountDisplay}>{calculateFlashRepayAmount().toFixed(6)}</div>
                  </div>
                  <div className={styles.flashStepBottomRight}>
                    <div className={styles.flashStepPriceLabel}>Fee Amount</div>
                    <div className={styles.flashStepPriceDisplay}>{((flashBorrowAmount || 0) * 0.0009).toFixed(6)}</div>
                  </div>
                </div>

                {/* Flash Loan Summary */}
                <div className={styles.flashSummary}>
                  <div className={styles.flashSummaryTitle}>Expected Profit/Loss</div>
                  <div className={styles.flashSummaryContent}>
                    {flashBuyPrice > 0 && flashSellPrice > 0 && flashBuyAmount > 0 && flashSellAmount > 0 ? (
                      <>
                        <div className={styles.flashSummaryRow}>
                          <span>Buy Cost:</span>
                          <span>{(flashBuyAmount * flashBuyPrice).toFixed(6)} {getFlashBorrowAsset()}</span>
                        </div>
                        <div className={styles.flashSummaryRow}>
                          <span>Sell Revenue:</span>
                          <span>{(flashSellAmount * flashSellPrice).toFixed(6)} {getFlashBorrowAsset()}</span>
                        </div>
                        <div className={styles.flashSummaryRow}>
                          <span>Repay Amount:</span>
                          <span>-{calculateFlashRepayAmount().toFixed(6)} {getFlashBorrowAsset()}</span>
                        </div>
                        <div className={`${styles.flashSummaryRow} ${styles.flashProfitLoss}`}>
                          <span>Net Profit/Loss:</span>
                          <span className={
                            ((flashSellAmount * flashSellPrice) - (flashBuyAmount * flashBuyPrice) - calculateFlashRepayAmount()) >= 0 
                              ? styles.positive 
                              : styles.negative
                          }>
                            {((flashSellAmount * flashSellPrice) - (flashBuyAmount * flashBuyPrice) - calculateFlashRepayAmount()).toFixed(6)} {getFlashBorrowAsset()}
                          </span>
                        </div>
                      </>
                    ) : (
                      <div className={styles.flashSummaryPlaceholder}>
                        Enter buy and sell prices to see profit estimation
                      </div>
                    )}
                  </div>
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
            <div className={styles.feeRow}>
              <span>Fee coin</span>
              <select value={selFeeCoinId} onChange={(e)=>setSelFeeCoinId(e.target.value)}>
                {(side==='buy'?quoteCoins:baseCoins).map(c => (
                  <option key={c.id} value={c.id}>{c.id.slice(0,6)}…{c.id.slice(-4)} ({Number(c.balance).toLocaleString()})</option>
                ))}
              </select>
            </div>
            {feeType === 'unxv' && (
              <div className={styles.feeRow}>
                <span>UNXV coin (optional)</span>
                <select value={selUnxvCoinId} onChange={(e)=>setSelUnxvCoinId(e.target.value)}>
                  <option value="">None</option>
                  {unxvCoins.map(c => (
                    <option key={c.id} value={c.id}>{c.id.slice(0,6)}…{c.id.slice(-4)} ({Number(c.balance).toLocaleString()})</option>
                  ))}
                </select>
              </div>
            )}
            
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
              disabled={buttonDisabled} 
              className={`${styles.submit} ${side==='buy'?styles.buyButton:styles.sellButton}`} 
              onClick={() => mode === 'flash' ? void onFlashLoanExecute() : void submit()}
              title={mode === 'flash' 
                ? (!flashBorrowAmount || flashBorrowAmount <= 0 ? 'Enter borrow amount to continue' : '') 
                : (!qty || qty <= 0 ? 'Enter a quantity to continue' : '')
              }
            >
              {submitting 
                ? 'Submitting...' 
                : mode === 'flash'
                  ? (!flashBorrowAmount || flashBorrowAmount <= 0 
                    ? 'Enter Flash Loan Details'
                    : `Execute Flash Loan (${flashBorrowAmount.toLocaleString()} ${getAssetSymbol(flashBorrowAsset)})`)
                  : (!qty || qty <= 0 
                    ? `Enter ${mode === 'margin' ? 'Position' : 'Amount'} to ${side === 'buy' ? 'Buy' : 'Sell'}` 
                    : `${side === 'buy' ? 'Buy' : 'Sell'} ${qty.toLocaleString()}`)
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
