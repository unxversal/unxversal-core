import { useMemo, useState } from 'react';
import { DerivativesScreen } from '../derivatives/DerivativesScreen';
import { GasFuturesTradePanel } from '../gas-futures/GasFuturesTradePanel';
import { createMockDerivativesProvider, createMockTradePanelProvider, createMockExpiryContracts } from '../derivatives/providers/mock';

export function FuturesScreen({ started, surgeReady, network, protocolStatus }: { 
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
  const [selectedExpiry, setSelectedExpiry] = useState<string>('');
  const dataProvider = useMemo(() => createMockDerivativesProvider('futures'), []);
  const panelProvider = useMemo(() => createMockTradePanelProvider(), []);
  const availableExpiries = useMemo(() => createMockExpiryContracts('futures'), []);
  
  // Set initial expiry if not set
  if (!selectedExpiry && availableExpiries.length > 0) {
    setSelectedExpiry(availableExpiries[0].id);
  }
  const handleExpiryChange = (expiryId: string) => {
    setSelectedExpiry(expiryId);
    // Update the active expiry in the contracts
    availableExpiries.forEach(contract => {
      contract.isActive = contract.id === expiryId;
    });
  };

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
      availableExpiries={availableExpiries}
      onExpiryChange={handleExpiryChange}
      protocolStatus={protocolStatus}
      TradePanelComponent={(props) => (
        <GasFuturesTradePanel mid={props.mid} provider={props.provider} baseSymbol={props.baseSymbol} quoteSymbol={props.quoteSymbol} />
      )}
    />
  );
}


