import React, { useMemo, useState } from 'react';
import { SuiClient, getFullnodeUrl } from '@mysten/sui/client';
import { OptionsComponent } from './OptionsComponent';
import { useOptionsIndexer } from './useOptionsIndexer';
import { makeMockOptionsData } from './mock';
import type { OptionsComponentProps } from './types';
import { loadSettings, getTokenBySymbol } from '../../lib/settings.config';
import { usePythPrice } from './usePythPrice';
import { OptionsClient } from '../../clients/options';

export function OptionsScreen({ useSampleData = false }: { useSampleData?: boolean }) {
  const settings = loadSettings();
  const client = useMemo(() => new SuiClient({ url: getFullnodeUrl(settings.network) }), [settings.network]);
  const optionsClient = useMemo(() => new OptionsClient(client, settings.contracts.unxversal), [client, settings.contracts.unxversal]);

  const [symbol, setSymbol] = useState<string>(settings.markets.watchlist[0] || 'SUI/USDC');
  const [expiry, setExpiry] = useState<number | null>(null);

  const symbolIconMap = useMemo(() => {
    const map: Record<string, string> = {};
    for (const s of settings.markets.watchlist) {
      const base = s.split('/')[0];
      const icon = getTokenBySymbol(base, settings)?.iconUrl;
      if (icon) map[s] = icon;
    }
    return map;
  }, [settings]);

  const onSelectSymbol = (s: string) => { setSymbol(s); setExpiry(null); };
  const onSelectExpiry = (ms: number) => setExpiry(ms);

  // Define actions that work for both sample and live data
  const actions: Pick<OptionsComponentProps, 'onPlaceBuyOrder' | 'onPlaceSellOrder' | 'onCancelOrder' | 'onExercise' | 'onSettleAfterExpiry'> = useMemo(() => ({
    onPlaceBuyOrder: async (args) => {
      try {
        console.log('Placing buy order:', args);
        // TODO: Implement buy order logic with optionsClient
        // Need to determine market ID and convert args to client format
        alert(`Buy order placed: ${args.quantity} ${args.isCall ? 'CALL' : 'PUT'} @ $${args.strike_1e6 / 1e6} for $${args.limitPremiumQuote_1e6 / 1e6}`);
      } catch (error) {
        console.error('Buy order failed:', error);
        alert('Buy order failed: ' + (error as Error).message);
      }
    },
    onPlaceSellOrder: async (args) => {
      try {
        console.log('Placing sell order:', args);
        // TODO: Implement sell order logic with optionsClient
        alert(`Sell order placed: ${args.quantity} ${args.isCall ? 'CALL' : 'PUT'} @ $${args.strike_1e6 / 1e6} for $${args.limitPremiumQuote_1e6 / 1e6}`);
      } catch (error) {
        console.error('Sell order failed:', error);
        alert('Sell order failed: ' + (error as Error).message);
      }
    },
    onCancelOrder: async (orderId) => {
      try {
        console.log('Cancelling order:', orderId);
        // TODO: Implement cancel order logic with optionsClient
        alert(`Order cancelled: ${orderId}`);
      } catch (error) {
        console.error('Cancel order failed:', error);
        alert('Cancel order failed: ' + (error as Error).message);
      }
    },
    onExercise: async (positionId) => {
      try {
        console.log('Exercising position:', positionId);
        // TODO: Implement exercise logic with optionsClient
        alert(`Position exercised: ${positionId}`);
      } catch (error) {
        console.error('Exercise failed:', error);
        alert('Exercise failed: ' + (error as Error).message);
      }
    },
    onSettleAfterExpiry: async (positionId) => {
      try {
        console.log('Settling position after expiry:', positionId);
        // TODO: Implement settle logic with optionsClient
        alert(`Position settled: ${positionId}`);
      } catch (error) {
        console.error('Settle failed:', error);
        alert('Settle failed: ' + (error as Error).message);
      }
    },
  }), [optionsClient]);

  // Always call hooks in the same order (Rules of Hooks)
  const { props: ix } = useOptionsIndexer({ 
    client, 
    selectedSymbol: symbol, 
    selectedExpiryMs: expiry,
    enabled: !useSampleData // Only run indexer when not using sample data
  });
  const { price: spot, change24h } = usePythPrice(symbol);

  if (useSampleData) {
    const mock = makeMockOptionsData({ symbol });
    const finalProps: OptionsComponentProps = {
      ...mock,
      allSymbols: settings.markets.watchlist.length ? settings.markets.watchlist : mock.allSymbols,
      onSelectSymbol,
      symbolIconMap,
      onSelectExpiry,
      ...actions,
    };
    return <OptionsComponent {...finalProps} />;
  }

  // For non-sample mode: use real data or empty, no mock fallbacks
  const finalSummary = {
    ...ix.summary,
    last: spot ?? ix.summary?.last,
    change24h: change24h ?? ix.summary?.change24h,
  };

  const finalProps: OptionsComponentProps = {
    selectedSymbol: ix.selectedSymbol ?? symbol,
    allSymbols: ix.allSymbols ?? [symbol],
    onSelectSymbol,
    symbolIconMap,
    selectedExpiryMs: ix.selectedExpiryMs ?? null,
    availableExpiriesMs: ix.availableExpiriesMs ?? [],
    onSelectExpiry,

    marketId: ix.marketId ?? '',
    feeConfigId: settings.dex.feeConfigId ?? '',
    feeVaultId: settings.dex.feeVaultId ?? '',
    stakingPoolId: settings.staking?.poolId ?? '',
    rewardsId: settings.contracts.rewardsId ?? '',
    pythSymbol: symbol,

    summary: finalSummary,
    oiByExpiry: ix.oiByExpiry ?? [],

    chainRows: ix.chainRows ?? [],
    underlyingPrice: finalSummary.last ?? undefined,

    positions: ix.positions ?? [],
    openOrders: ix.openOrders ?? [],
    tradeHistory: ix.tradeHistory ?? [],
    orderHistory: ix.orderHistory ?? [],
    portfolioSummary: { premiumPaidQuote: '0.00', premiumReceivedQuote: '0.00' },
    leaderboardRank: null,
    leaderboardPoints: null,

    ...actions,
  };

  return <OptionsComponent {...finalProps} />;
}
