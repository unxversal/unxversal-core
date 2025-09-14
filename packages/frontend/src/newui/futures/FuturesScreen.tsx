import { useMemo, useState } from 'react';
import { SuiClient, getFullnodeUrl } from '@mysten/sui/client';
import { DerivativesScreen } from '../../components/derivatives/DerivativesScreen';
import { GasFuturesTradePanel } from '../../components/gas-futures/GasFuturesTradePanel';
import { createMockDerivativesProvider, createMockTradePanelProvider, createMockExpiryContracts } from '../../components/derivatives/providers/mock';
import type { DerivativesDataProvider, TradePanelDataProvider, ExpiryContract } from '../../components/derivatives/types';
import { useFuturesIndexer } from './useFuturesIndexer';
import { loadSettings, getTokenBySymbol } from '../../lib/settings.config';

export function FuturesScreen({ useSampleData = false }: { useSampleData?: boolean }) {
  const settings = loadSettings();
  const client = useMemo(() => new SuiClient({ url: getFullnodeUrl(settings.network) }), [settings.network]);

  const [symbol, setSymbol] = useState<string>(settings.markets.watchlist[0] || 'SUI/USDC');
  const [selectedExpiry, setSelectedExpiry] = useState<string>('');
  const baseSymbol = symbol.split('/')[0] || 'SUI';
  const quoteSymbol = symbol.split('/')[1] || 'USDC';

  const { props: ix } = useFuturesIndexer({ client, selectedSymbol: symbol, selectedExpiryMs: null, enabled: !useSampleData });

  const symbolIconMap = useMemo(() => {
    const map: Record<string, string> = {};
    for (const s of settings.markets.watchlist) {
      const base = s.split('/')[0];
      const icon = getTokenBySymbol(base, settings)?.iconUrl;
      if (icon) map[s] = icon;
    }
    return map;
  }, [settings]);

  if (useSampleData) {
    const dataProvider = createMockDerivativesProvider('futures') as DerivativesDataProvider;
    const panelProvider = createMockTradePanelProvider() as TradePanelDataProvider;
    const availableExpiries = createMockExpiryContracts('futures');
    if (!selectedExpiry && availableExpiries.length > 0) setSelectedExpiry(availableExpiries[0].id);
    return (
      <DerivativesScreen
        marketLabel={`${baseSymbol} Futures`}
        symbol={baseSymbol}
        quoteSymbol={quoteSymbol}
        dataProvider={dataProvider}
        panelProvider={panelProvider}
        availableExpiries={availableExpiries}
        onExpiryChange={(id) => setSelectedExpiry(id)}
        allSymbols={settings.markets.watchlist}
        selectedSymbol={symbol}
        onSelectSymbol={setSymbol}
        symbolIconMap={symbolIconMap}
        TradePanelComponent={(p) => <GasFuturesTradePanel mid={p.mid} provider={p.provider} baseSymbol={p.baseSymbol} quoteSymbol={p.quoteSymbol} />}
      />
    );
  }

  const provider: DerivativesDataProvider = {
    async getSummary() {
      const s = ix.summary || {};
      return {
        last: s.last,
        vol24h: s.vol24h,
        high24h: undefined,
        low24h: undefined,
        change24h: s.change24h,
        openInterest: s.openInterest,
        expiryDate: s.expiryMs || undefined,
        timeToExpiry: s.expiryMs ? Math.max(0, (s.expiryMs as number) - Date.now()) : undefined,
      };
    },
    async getOrderbook() {
      const ob = ix.orderBook || { bids: [], asks: [] };
      return { bids: ob.bids.map(l => [l.price, l.qty] as [number, number]), asks: ob.asks.map(l => [l.price, l.qty] as [number, number]) };
    },
    async getRecentTrades() {
      return (ix.recentTrades || []).map(t => ({ price: t.priceQuote, qty: t.baseQty, ts: Math.floor(t.tsMs/1000), side: 'buy' })) as any;
    },
    async getPositions() {
      return (ix.positions || []).map((p) => ({
        side: p.longQty > 0 ? 'Long' : 'Short',
        size: String((p.longQty || p.shortQty)),
        entryPrice: (p.longQty > 0 ? p.avgLong1e6 : p.avgShort1e6) ? ((p.longQty > 0 ? p.avgLong1e6 : p.avgShort1e6)/1e6).toFixed(4) : '-',
        markPrice: p.markPrice1e6 != null ? (p.markPrice1e6/1e6).toFixed(4) : '-',
        pnl: (p.pnlQuote ?? 0).toFixed(2),
        margin: '-', leverage: '-',
      }));
    },
    async getOpenOrders() {
      return (ix.openOrders || []).map((o) => ({
        type: 'Limit', side: o.isBid ? 'Long' : 'Short', size: o.qtyRemaining, price: o.priceQuote, total: '-', leverage: '-', status: o.status ?? 'Open'
      } as any));
    },
    async getTwap() {
      return ix.summary?.twap5m ? [{ period: '5m', twap: ix.summary.twap5m.toFixed(5), volume: '-' }] : [];
    },
  };

  const panelProvider: TradePanelDataProvider = { async getBalances() { return { base: 0, quote: 0 }; }, async getAccountMetrics() { return { accountValue: 0, marginRatio: 0 }; }, async getFeeInfo() { return { takerBps: 0, unxvDiscountBps: 0 }; }, async getActiveStake() { return 0; } };

  const expiries: ExpiryContract[] = (ix.availableExpiriesMs || []).map((ms) => ({ id: String(ms), label: new Date(ms).toLocaleDateString('en-US', { month: 'short', day: 'numeric' }), expiryDate: ms, isActive: selectedExpiry === String(ms) }));
  if (!selectedExpiry && expiries.length > 0) setSelectedExpiry(expiries[0].id);

  return (
    <DerivativesScreen
      marketLabel={`${baseSymbol} Futures`}
      symbol={baseSymbol}
      quoteSymbol={quoteSymbol}
      dataProvider={provider}
      panelProvider={panelProvider}
      availableExpiries={expiries}
      onExpiryChange={(id) => setSelectedExpiry(id)}
      allSymbols={settings.markets.watchlist}
      selectedSymbol={symbol}
      onSelectSymbol={setSymbol}
      symbolIconMap={symbolIconMap}
      TradePanelComponent={(p) => <GasFuturesTradePanel mid={p.mid} provider={p.provider} baseSymbol={p.baseSymbol} quoteSymbol={p.quoteSymbol} />}
    />
  );
}


