import React, { useMemo } from 'react';
import { SuiClient } from '@mysten/sui/client';
import { FuturesComponent } from './FuturesComponent';
import type { FuturesComponentProps } from './types';
import { useFuturesIndexer } from './useFuturesIndexer';
import { loadSettings, getTokenBySymbol } from '../../lib/settings.config';
import { FuturesClient as ProtoFuturesClient } from '../../protocols/futures/client';

export function FuturesWrapper({ client, symbol, expiryMs, address }: { client: SuiClient; symbol: string; expiryMs: number | null; address?: string | null }) {
  const { props, loading } = useFuturesIndexer({ client, selectedSymbol: symbol, selectedExpiryMs: expiryMs, address, enabled: true });
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
    onOpenLong: async ({ marketId, qty }) => {
      const fc = new ProtoFuturesClient(settings.contracts.pkgUnxversal);
      const tx = fc.openLong({
        marketId,
        oracleRegistryId: (props as any).oracleRegistryId || '',
        aggregatorId: (props as any).aggregatorId || '',
        feeConfigId: (props as any).feeConfigId || '',
        feeVaultId: (props as any).feeVaultId || '',
        stakingPoolId: (props as any).stakingPoolId || '',
        rewardsId: (props as any).rewardsId || '',
        qty: BigInt(qty),
      });
      // Hand off tx to caller's wallet flow (wrapper will be enhanced later)
      console.debug('Prepared openLong tx', tx);
    },
    onOpenShort: async ({ marketId, qty }) => {
      const fc = new ProtoFuturesClient(settings.contracts.pkgUnxversal);
      const tx = fc.openShort({
        marketId,
        oracleRegistryId: (props as any).oracleRegistryId || '',
        aggregatorId: (props as any).aggregatorId || '',
        feeConfigId: (props as any).feeConfigId || '',
        feeVaultId: (props as any).feeVaultId || '',
        stakingPoolId: (props as any).stakingPoolId || '',
        rewardsId: (props as any).rewardsId || '',
        qty: BigInt(qty),
      });
      console.debug('Prepared openShort tx', tx);
    },
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
      initialMarginBps={(props as any).initialMarginBps}
      maintenanceMarginBps={(props as any).maintenanceMarginBps}
      maxLeverage={(props as any).maxLeverage}
      {...actions}
    />
  );
}


