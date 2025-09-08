import { useMemo } from 'react';
import { DerivativesScreen } from '../derivatives/DerivativesScreen';
import { GasFuturesTradePanel } from '../gas-futures/GasFuturesTradePanel';
import { createMockDerivativesProvider, createMockTradePanelProvider } from '../derivatives/providers/mock';

export function FuturesScreen({ started, surgeReady, network }: { started?: boolean; surgeReady?: boolean; network?: string }) {
  const dataProvider = useMemo(() => createMockDerivativesProvider(), []);
  const panelProvider = useMemo(() => createMockTradePanelProvider(), []);
  return (
    <DerivativesScreen
      started={started}
      surgeReady={surgeReady}
      network={network}
      marketLabel={'MIST Futures'}
      symbol={'MIST'}
      quoteSymbol={'USDC'}
      dataProvider={dataProvider}
      panelProvider={panelProvider}
      TradePanelComponent={(props) => (
        <GasFuturesTradePanel mid={props.mid} provider={props.provider} baseSymbol={props.baseSymbol} quoteSymbol={props.quoteSymbol} />
      )}
    />
  );
}


