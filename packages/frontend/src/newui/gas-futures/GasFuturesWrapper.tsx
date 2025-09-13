import { useMemo, useState } from 'react';
import { ConnectButton, useCurrentAccount } from '@mysten/dapp-kit';
import { loadSettings } from '../../lib/settings.config';
import { GasFuturesComponent } from './GasFuturesComponent';
import type { GasFuturesComponentProps } from './types';
import { gasFuturesSampleData } from './gasFuturesSampleData';
import { useGasFuturesData } from './useGasFuturesData';

export function GasFuturesWrapper({ useSampleData }: { useSampleData: boolean }) {
  const account = useCurrentAccount();
  const settings = loadSettings();
  const [activeExpiryId, setActiveExpiryId] = useState<string | undefined>(undefined);
  const live = useGasFuturesData();

  const baseProps: GasFuturesComponentProps = useMemo(() => {
    if (useSampleData) {
      const exp = gasFuturesSampleData.expiries || [];
      const active = activeExpiryId || exp.find(e => e.isActive)?.id || exp[0]?.id;
      return {
        ...gasFuturesSampleData,
        address: account?.address,
        network: settings.network,
        expiries: exp.map(e => ({ ...e, isActive: e.id === active })),
      };
    }
    const expiries = live.markets.map(m => ({ id: String(m.expiryMs), label: new Date(m.expiryMs).toLocaleDateString(), expiryDate: m.expiryMs, isActive: String(m.expiryMs) === activeExpiryId })).sort((a, b) => a.expiryDate - b.expiryDate);
    return {
      address: account?.address,
      network: settings.network,
      protocolStatus: { options: true, futures: true, perps: true, lending: true, staking: true, dex: true },
      marketLabel: 'MIST Gas Futures',
      symbol: 'MIST',
      quoteSymbol: 'USDC',
      expiries,
      summary: {
        last: live.lastPrice,
        openInterest: live.oi ? (live.oi.longQty + live.oi.shortQty) : undefined,
        // timeToExpiry/expiryDate can be derived if an active expiry is selected
      },
      ohlc: { candles: live.candles },
      orderbook: live.orderbook,
      recentTrades: live.trades,
      positions: [],
      openOrders: [],
      twap: [],
    };
  }, [useSampleData, account?.address, settings.network, activeExpiryId, live.markets, live.candles, live.orderbook, live.trades, live.lastPrice, live.oi]);

  return (
    <GasFuturesComponent
      {...baseProps}
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
          <div style={{ marginTop: 12, color: '#e5e7eb', fontSize: 12 }}>Mid: {mid.toFixed(0)} {quoteSymbol}</div>
          <div style={{ color: '#9ca3af', fontSize: 12 }}>Asset: {baseSymbol}</div>
        </div>
      )}
    />
  );
}

export default GasFuturesWrapper;


