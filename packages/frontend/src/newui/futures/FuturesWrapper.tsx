import React, { useMemo } from 'react';
import { SuiClient } from '@mysten/sui/client';
import { FuturesComponent } from './FuturesComponent';
import type { FuturesComponentProps } from './types';
import { useFuturesIndexer } from './useFuturesIndexer';
import { loadSettings, getAllTokenSymbols, getTokenBySymbol } from '../../lib/settings.config';

export function FuturesWrapper({ client, symbol, expiryMs }: { client: SuiClient; symbol: string; expiryMs: number | null }) {
  const { props, loading } = useFuturesIndexer({ client, selectedSymbol: symbol, selectedExpiryMs: expiryMs, enabled: true });
  const settings = loadSettings();
  const allSymbols = settings.markets.watchlist;
  const symbolIconMap = useMemo(() => {
    const map: Record<string, string> = {};
    for (const sym of allSymbols) {
      const [base] = sym.split('/');
      const tk = getTokenBySymbol(base);
      if (tk?.iconUrl) map[sym] = tk.iconUrl;
    }
    return map;
  }, [allSymbols]);

  const actions: Pick<FuturesComponentProps,
    'onOpenLong' | 'onOpenShort' | 'onCloseLong' | 'onCloseShort' | 'onCancelOrder' | 'onDepositCollateral' | 'onWithdrawCollateral'> = {
    onOpenLong: async () => {},
    onOpenShort: async () => {},
    onCloseLong: async () => {},
    onCloseShort: async () => {},
    onCancelOrder: async () => {},
    onDepositCollateral: async () => {},
    onWithdrawCollateral: async () => {},
  };

  return (
    <FuturesComponent
      {...(props as any)}
      selectedSymbol={symbol}
      allSymbols={allSymbols}
      onSelectSymbol={() => {}}
      symbolIconMap={symbolIconMap}
      selectedExpiryMs={expiryMs}
      onSelectExpiry={() => {}}
      summary={props.summary || {}}
      orderBook={props.orderBook || { bids: [], asks: [] }}
      recentTrades={props.recentTrades || []}
      positions={props.positions || []}
      openOrders={props.openOrders || []}
      tradeHistory={props.tradeHistory || []}
      orderHistory={props.orderHistory || []}
      {...actions}
    />
  );
}


