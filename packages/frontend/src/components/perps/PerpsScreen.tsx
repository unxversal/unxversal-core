import { useMemo } from 'react';
import { DerivativesScreen } from '../derivatives/DerivativesScreen';
import { GasFuturesTradePanel } from '../gas-futures/GasFuturesTradePanel';
import { createMockDerivativesProvider, createMockTradePanelProvider } from '../derivatives/providers/mock';

export function PerpsScreen({ started, surgeReady, network, protocolStatus }: { 
  started?: boolean; 
  surgeReady?: boolean; 
  network?: string;
  protocolStatus?: {
    options: boolean;
    futures: boolean;
    perps: boolean;
    lending: boolean;
    staking: boolean;
    dex: boolean;
  }
}) {
  const dataProvider = useMemo(() => createMockDerivativesProvider('perps'), []);
  const panelProvider = useMemo(() => createMockTradePanelProvider(), []);
  return (
    <DerivativesScreen
      started={started}
      surgeReady={surgeReady}
      network={network}
      marketLabel={'MIST Perps'}
      symbol={'MIST'}
      quoteSymbol={'USDC'}
      dataProvider={dataProvider}
      panelProvider={panelProvider}
      protocolStatus={protocolStatus}
      TradePanelComponent={(props) => (
        <GasFuturesTradePanel mid={props.mid} provider={props.provider} baseSymbol={props.baseSymbol} quoteSymbol={props.quoteSymbol} />
      )}
    />
  );
}


