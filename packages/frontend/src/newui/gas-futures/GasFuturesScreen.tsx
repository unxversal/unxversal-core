import { useMemo, useState } from 'react';
import { SuiClient, getFullnodeUrl } from '@mysten/sui/client';
import { DerivativesScreen } from '../../components/derivatives/DerivativesScreen';
import { FuturesTradePanel } from '../futures/FuturesTradePanel';
import type { DerivativesDataProvider, TradePanelDataProvider, ExpiryContract } from '../../components/derivatives/types';
import { createMockDerivativesProvider, createMockExpiryContracts, createMockTradePanelProvider } from '../../components/derivatives/providers/mock';
import { loadSettings, getTokenBySymbol } from '../../lib/settings.config';
import { useCurrentAccount, useSuiClient, useSignAndExecuteTransaction } from '@mysten/dapp-kit';
import { Transaction } from '@mysten/sui/transactions';
import { toast } from 'sonner';
import { GasFuturesClient } from '../../clients/gasFutures';
import { useGasFuturesIndexer } from './useGasFuturesIndexer';

export function GasFuturesScreen({ useSampleData = false }: { useSampleData?: boolean }) {
  const settings = loadSettings();
  const client = useMemo(() => new SuiClient({ url: getFullnodeUrl(settings.network) }), [settings.network]);
  const acct = useCurrentAccount();
  const sui = useSuiClient();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();

  const [symbol, setSymbol] = useState<string>('MIST/USDC');
  const [selectedExpiry, setSelectedExpiry] = useState<string>('');
  const baseSymbol = 'MIST';
  const quoteSymbol = 'USDC';

  const { props: ix } = useGasFuturesIndexer({ client, selectedSymbol: symbol, selectedExpiryMs: null, enabled: !useSampleData });

  const symbolIconMap = useMemo(() => ({ ['MIST/USDC']: getTokenBySymbol('SUI', settings)?.iconUrl || '' }), [settings]);

  if (useSampleData) {
    const dataProvider = createMockDerivativesProvider('gas-futures') as DerivativesDataProvider;
    const panelProvider = createMockTradePanelProvider() as TradePanelDataProvider;
    const availableExpiries = createMockExpiryContracts('gas-futures');
    if (!selectedExpiry && availableExpiries.length > 0) setSelectedExpiry(availableExpiries[0].id);
    return (
      <DerivativesScreen
        marketLabel={`${baseSymbol} Gas Futures`}
        symbol={baseSymbol}
        quoteSymbol={quoteSymbol}
        dataProvider={dataProvider}
        panelProvider={panelProvider}
        availableExpiries={availableExpiries}
        onExpiryChange={(id) => setSelectedExpiry(id)}
        allSymbols={['MIST/USDC']}
        selectedSymbol={symbol}
        onSelectSymbol={setSymbol}
        symbolIconMap={symbolIconMap as any}
        TradePanelComponent={(p) => <FuturesTradePanel mid={p.mid} provider={p.provider} baseSymbol={p.baseSymbol} quoteSymbol={p.quoteSymbol} />}
      />
    );
  }

  const provider: DerivativesDataProvider = {
    async getSummary() {
      const s = ix.summary || {};
      return {
        last: s.last,
        vol24h: s.vol24h,
        change24h: s.change24h,
        openInterest: s.openInterest,
        expiryDate: s.expiryMs || undefined,
        timeToExpiry: s.expiryMs ? Math.max(0, (s.expiryMs as number) - Date.now()) : undefined,
      };
    },
    async getOhlc(tf) {
      const r = (ix as any).getOhlc?.(tf);
      return r || { candles: [] };
    },
    async getOrderbook() {
      const ob = ix.orderBook || { bids: [], asks: [] };
      return { bids: ob.bids.map(l => [l.price, l.qty] as [number, number]), asks: ob.asks.map(l => [l.price, l.qty] as [number, number]) };
    },
    async getRecentTrades() {
      return (ix.recentTrades || []).map(t => ({ price: t.priceQuote, qty: t.baseQty, ts: Math.floor(t.tsMs/1000), side: 'buy' })) as any;
    },
    async getPositions() { return []; },
    async getOpenOrders() {
      return (ix.openOrders || []).map((o) => ({
        id: o.orderId,
        orderId: o.orderId,
        type: 'Limit', side: o.isBid ? 'Long' : 'Short', size: o.qtyRemaining, price: o.priceQuote, total: '-', leverage: '-', status: o.status ?? 'Open'
      } as any));
    },
    async getTwap() { return ix.summary?.twap5m ? [{ period: '5m', twap: ix.summary.twap5m.toFixed(5), volume: '-' }] : []; },
  };

  const panelProvider: TradePanelDataProvider = {
    async getBalances() {
      if (!acct?.address) return { base: 0, quote: 0 };
      try {
        const baseInfo = getTokenBySymbol('SUI', settings);
        const quoteInfo = getTokenBySymbol(quoteSymbol, settings);
        const [bb, qb] = await Promise.all([
          baseInfo?.typeTag ? sui.getBalance({ owner: acct.address, coinType: baseInfo.typeTag }) : Promise.resolve({ totalBalance: '0' } as any),
          quoteInfo?.typeTag ? sui.getBalance({ owner: acct.address, coinType: quoteInfo.typeTag }) : Promise.resolve({ totalBalance: '0' } as any),
        ]);
        const bMeta = baseInfo?.typeTag ? await sui.getCoinMetadata({ coinType: baseInfo.typeTag }).catch(()=>({decimals:9} as any)) : ({decimals:9} as any);
        const qMeta = quoteInfo?.typeTag ? await sui.getCoinMetadata({ coinType: quoteInfo.typeTag }).catch(()=>({decimals:6} as any)) : ({decimals:6} as any);
        const bdec = Number((bMeta as any).decimals ?? 9);
        const qdec = Number((qMeta as any).decimals ?? 6);
        return { base: Number((bb as any).totalBalance ?? '0') / 10 ** bdec, quote: Number((qb as any).totalBalance ?? '0') / 10 ** qdec };
      } catch { return { base: 0, quote: 0 }; }
    },
    async getFeeInfo() {
      try {
        const feeConfigId = settings.dex.feeConfigId;
        if (!feeConfigId) return { takerBps: 70, unxvDiscountBps: 3000 };
        const o = await sui.getObject({ id: feeConfigId, options: { showContent: true } });
        const f = (o as any)?.data?.content?.fields;
        const taker = Number(f?.dex_taker_fee_bps ?? 70);
        const disc = Number(f?.unxv_discount_bps ?? 3000);
        return { takerBps: taker, unxvDiscountBps: disc };
      } catch { return { takerBps: 70, unxvDiscountBps: 3000 }; }
    },
    async submitOrder(o) {
      if (!acct?.address) { toast.error('Connect wallet'); throw new Error('Connect wallet'); }
      const pkg = settings.contracts.pkgUnxversal || settings.contracts.pkgDeepbook;
      if (!pkg) { toast.error('Configure packages'); throw new Error('Missing package'); }
      const gc = new GasFuturesClient(pkg, settings.contracts.pkgUnxversal || pkg);
      const qty = BigInt(Math.max(0, Math.floor(o.size)));
      const marketId = ix.marketId || '';
      if (!marketId) throw new Error('Missing market');
      const price1e6 = BigInt(Math.max(1, Math.floor((o.price || ix.summary?.last || 0) * 1_000_000)));
      const expireTs = BigInt(Math.floor(Date.now()/1000) + 15 * 60);
      const id = `gas-order-${Date.now()}`;
      try { toast.loading('Submitting order…', { id, position: 'top-center' }); const tx = o.side === 'long' ? gc.placeLimitBid({ marketId, price1e6, qty, expireTs }) : gc.placeLimitAsk({ marketId, price1e6, qty, expireTs }); await signAndExecute({ transaction: tx as unknown as Transaction }); toast.success('Order submitted', { id, position: 'top-center' }); } catch (e: any) { toast.error(e?.message ?? 'Order failed', { id, position: 'top-center' }); throw e; }
    },
    async cancelOrder(orderId) {
      if (!acct?.address) { toast.error('Connect wallet'); throw new Error('Connect wallet'); }
      const pkg = settings.contracts.pkgUnxversal || settings.contracts.pkgDeepbook; if (!pkg) throw new Error('Configure packages');
      const gc = new GasFuturesClient(pkg, settings.contracts.pkgUnxversal || pkg);
      const marketId = ix.marketId || '';
      if (!marketId) throw new Error('Missing market');
      const id = `gas-cancel-${orderId}`;
      try { toast.loading('Canceling order…', { id, position: 'top-center' }); const tx = gc.cancelOrder({ marketId, orderId: BigInt(orderId as any) }); await signAndExecute({ transaction: tx as unknown as Transaction }); toast.success('Order canceled', { id, position: 'top-center' }); } catch (e: any) { toast.error(e?.message ?? 'Cancel failed', { id, position: 'top-center' }); throw e; }
    },
    async depositCollateral(coinId) {
      if (!acct?.address) { toast.error('Connect wallet'); throw new Error('Connect wallet'); }
      const pkg = settings.contracts.pkgUnxversal || settings.contracts.pkgDeepbook; if (!pkg) throw new Error('Configure packages');
      const gc = new GasFuturesClient(pkg, settings.contracts.pkgUnxversal || pkg);
      const marketId = ix.marketId || '';
      if (!marketId) throw new Error('Missing market');
      if (!coinId) { toast.error('Select a coin'); throw new Error('Missing coinId'); }
      const id = 'gas-deposit';
      try { toast.loading('Depositing collateral…', { id, position: 'top-center' }); const tx = gc.depositCollateral({ marketId, collatCoinId: coinId }); await signAndExecute({ transaction: tx as unknown as Transaction }); toast.success('Deposited', { id, position: 'top-center' }); } catch (e: any) { toast.error(e?.message ?? 'Deposit failed', { id, position: 'top-center' }); throw e; }
    },
    async withdrawCollateral(amountUi) {
      if (!acct?.address) { toast.error('Connect wallet'); throw new Error('Connect wallet'); }
      const pkg = settings.contracts.pkgUnxversal || settings.contracts.pkgDeepbook; if (!pkg) throw new Error('Configure packages');
      const gc = new GasFuturesClient(pkg, settings.contracts.pkgUnxversal || pkg);
      const marketId = ix.marketId || '';
      if (!marketId) throw new Error('Missing market');
      const id = 'gas-withdraw';
      try { toast.loading('Withdrawing collateral…', { id, position: 'top-center' }); const tx = gc.withdrawCollateral({ marketId, amount: BigInt(Math.max(0, Math.floor(amountUi))) }); await signAndExecute({ transaction: tx as unknown as Transaction }); toast.success('Withdrawn', { id, position: 'top-center' }); } catch (e: any) { toast.error(e?.message ?? 'Withdraw failed', { id, position: 'top-center' }); throw e; }
    },
    async claimPnlCredit() {
      if (!acct?.address) { toast.error('Connect wallet'); throw new Error('Connect wallet'); }
      const pkg = settings.contracts.pkgUnxversal || settings.contracts.pkgDeepbook; if (!pkg) throw new Error('Configure packages');
      const gc = new GasFuturesClient(pkg, settings.contracts.pkgUnxversal || pkg);
      const marketId = ix.marketId || '';
      const feeVaultId = settings.dex.feeVaultId || '';
      if (!marketId || !feeVaultId) throw new Error('Missing IDs');
      const id = 'gas-claimpnl';
      try { toast.loading('Claiming PnL credit…', { id, position: 'top-center' }); const tx = gc.claimPnlCredit({ marketId, feeVaultId }); await signAndExecute({ transaction: tx as unknown as Transaction }); toast.success('PnL credit claimed', { id, position: 'top-center' }); } catch (e: any) { toast.error(e?.message ?? 'Claim failed', { id, position: 'top-center' }); throw e; }
    },
  };

  const expiries: ExpiryContract[] = (ix.availableExpiriesMs || []).map((ms) => ({ id: String(ms), label: new Date(ms).toLocaleDateString('en-US', { month: 'short', day: 'numeric' }), expiryDate: ms, isActive: selectedExpiry === String(ms) }));
  if (!selectedExpiry && expiries.length > 0) setSelectedExpiry(expiries[0].id);

  return (
    <DerivativesScreen
      marketLabel={`${baseSymbol} Gas Futures`}
      symbol={baseSymbol}
      quoteSymbol={quoteSymbol}
      dataProvider={provider}
      panelProvider={panelProvider}
      availableExpiries={expiries}
      onExpiryChange={(id) => setSelectedExpiry(id)}
      allSymbols={['MIST/USDC']}
      selectedSymbol={symbol}
      onSelectSymbol={setSymbol}
      symbolIconMap={symbolIconMap as any}
      TradePanelComponent={(p) => <FuturesTradePanel mid={p.mid} provider={p.provider} baseSymbol={p.baseSymbol} quoteSymbol={p.quoteSymbol} />}
    />
  );
}


