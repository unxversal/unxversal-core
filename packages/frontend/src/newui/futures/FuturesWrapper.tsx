import { useMemo, useState } from 'react';
import { ConnectButton, useCurrentAccount } from '@mysten/dapp-kit';
import { loadSettings } from '../../lib/settings.config';
import { FuturesComponent } from './FuturesComponent';
import type { FuturesComponentProps } from './types';
import { futuresSampleData } from './futuresSampleData';
import { useFuturesData } from './useFuturesData';

export function FuturesWrapper({ useSampleData }: { useSampleData: boolean }) {
  const account = useCurrentAccount();
  const settings = loadSettings();
  const [activeExpiryId, setActiveExpiryId] = useState<string | undefined>(undefined);
  const [selectedMarketId, setSelectedMarketId] = useState<string | undefined>(undefined);
  const live = useFuturesData();

  const baseProps: FuturesComponentProps = useMemo(() => {
    if (useSampleData) {
      const exp = futuresSampleData.expiries || [];
      const active = activeExpiryId || exp.find(e => e.isActive)?.id || exp[0]?.id;
      return {
        ...futuresSampleData,
        address: account?.address,
        network: settings.network,
        selectedMarketId: selectedMarketId || futuresSampleData.selectedMarketId,
        expiries: exp.map(e => ({ ...e, isActive: e.id === active })),
      };
    }
    // Live mode: map indexed data to component props
    const uniqueBases = Array.from(new Set(live.markets.map(m => m.symbol.split('/')[0])));
    const markets = uniqueBases.map((base) => ({
      marketId: base,
      symbol: `${base}/USDC`,
      label: base === 'MIST' ? 'MIST Gas Futures' : base,
    }));
    const activeBase = selectedMarketId || markets[0]?.marketId;
    const expiriesRaw = live.markets.filter(m => m.symbol.startsWith(`${activeBase}/`));
    const expiries = expiriesRaw
      .map(m => ({ id: String(m.expiryMs), label: new Date(m.expiryMs).toLocaleDateString(), expiryDate: m.expiryMs, isActive: String(m.expiryMs) === activeExpiryId }))
      .sort((a, b) => a.expiryDate - b.expiryDate);
    const symbolStr = markets.find(m => m.marketId === activeBase)?.symbol || 'SUI/USDC';
    const candles = live.candlesBySymbol[symbolStr] || [];
    // Pick earliest (front) expiry market for book/summary as proxy for now
    const frontMarketId = expiriesRaw.sort((a, b) => a.expiryMs - b.expiryMs)[0]?.id;
    const book = frontMarketId ? live.orderbookByMarket[frontMarketId] : { bids: [], asks: [] };
    const last = frontMarketId ? live.lastPriceByMarket[frontMarketId] : undefined;
    const oi = frontMarketId ? live.oiByMarket[frontMarketId] : undefined;
    return {
      address: account?.address,
      network: settings.network,
      protocolStatus: { options: true, futures: true, perps: true, lending: true, staking: true, dex: true },
      symbol: activeBase || 'SUI',
      quoteSymbol: 'USDC',
      markets,
      selectedMarketId: activeBase,
      expiries,
      summary: {
        last,
        openInterest: oi ? (oi.longQty + oi.shortQty) : undefined,
      },
      ohlc: { candles },
      orderbook: book || { bids: [], asks: [] },
      recentTrades: [],
      positions: [],
      openOrders: [],
      twap: [],
    };
  }, [useSampleData, account?.address, settings.network, activeExpiryId, selectedMarketId, live.markets, live.candlesBySymbol, live.orderbookByMarket, live.lastPriceByMarket, live.oiByMarket]);

  return (
    <FuturesComponent
      {...baseProps}
      markets={baseProps.markets}
      selectedMarketId={selectedMarketId || baseProps.selectedMarketId}
      onSelectMarket={(id) => setSelectedMarketId(id)}
      onExpiryChange={(id) => setActiveExpiryId(id)}
      TradePanelComponent={({ baseSymbol, quoteSymbol, mid }) => (
        <div style={{ padding: 12 }}>
          {!account?.address ? (
            <div style={{ display: 'flex', justifyContent: 'center' }}><ConnectButton /></div>
          ) : null}
          <div style={{ color: '#9ca3af', fontSize: 12, marginBottom: 8 }}>Trade Panel (stub)</div>
          <div style={{ display: 'grid', gap: 8 }}>
            <button style={{ background: '#10b98122', border: '1px solid #10b98155', color: '#10b981', padding: '8px 12px', borderRadius: 6 }}>Buy Long</button>
            <button style={{ background: '#ef444422', border: '1px solid #ef444455', color: '#ef4444', padding: '8px 12px', borderRadius: 6 }}>Sell Short</button>
          </div>
          <div style={{ marginTop: 12, color: '#e5e7eb', fontSize: 12 }}>Mid: {mid.toFixed(6)} {quoteSymbol}</div>
          <div style={{ color: '#9ca3af', fontSize: 12 }}>Pair: {baseSymbol}/{quoteSymbol}</div>
        </div>
      )}
    />
  );
}

export default FuturesWrapper;


