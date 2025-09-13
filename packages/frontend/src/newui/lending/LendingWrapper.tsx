import { useMemo, useState } from 'react';
import { ConnectButton, useCurrentAccount } from '@mysten/dapp-kit';
import { LendingComponent } from './LendingComponent';
import { lendingSampleData } from './lendingSampleData';
import type { LendingComponentProps, LendingDrawerMode, ViewMode } from './types';
import { getTokenBySymbol, loadSettings } from '../../lib/settings.config';
import { useLendingData } from './useLendingData';

export function LendingWrapper({ useSampleData }: { useSampleData: boolean }) {
  const account = useCurrentAccount();
  const [viewMode, setViewMode] = useState<ViewMode>('markets');
  const [selectedMarketId, setSelectedMarketId] = useState<string | undefined>(undefined);
  const [isDrawerOpen, setIsDrawerOpen] = useState(false);
  const [drawerMode, setDrawerMode] = useState<LendingDrawerMode>('supplyDebt');
  const [inputAmount, setInputAmount] = useState<number>(0);
  const [userBalance, setUserBalance] = useState<number>(1000);
  const [submitting, setSubmitting] = useState(false);
  const { markets: indexedMarkets, tvlUsd, activeUsers } = useLendingData(account?.address);

  function applyIconsFromSettings(markets: LendingComponentProps['markets']): LendingComponentProps['markets'] {
    const settings = loadSettings();
    return (markets || []).map((m) => {
      const collCfg = getTokenBySymbol(m.collateral.symbol, settings);
      const debtCfg = getTokenBySymbol(m.debt.symbol, settings);
      return {
        ...m,
        collateral: {
          ...m.collateral,
          name: collCfg?.name ?? m.collateral.name,
          decimals: collCfg?.decimals ?? m.collateral.decimals,
          typeTag: collCfg?.typeTag ?? m.collateral.typeTag,
          iconUrl: collCfg?.iconUrl ?? m.collateral.iconUrl,
        },
        debt: {
          ...m.debt,
          name: debtCfg?.name ?? m.debt.name,
          decimals: debtCfg?.decimals ?? m.debt.decimals,
          typeTag: debtCfg?.typeTag ?? m.debt.typeTag,
          iconUrl: debtCfg?.iconUrl ?? m.debt.iconUrl,
        },
      };
    });
  }

  const base: LendingComponentProps = useMemo(() => {
    if (useSampleData) {
      const withIcons = { ...lendingSampleData, markets: applyIconsFromSettings(lendingSampleData.markets) } as LendingComponentProps;
      return { ...withIcons, renderConnect: <ConnectButton /> };
    }
    // Minimal empty wiring when not using sample data
    return {
      address: account?.address,
      network: 'testnet',
      protocolStatus: { options: true, futures: true, perps: true, lending: true, staking: true, dex: true },
      tvlUsd,
      activeUsers,
      markets: applyIconsFromSettings(indexedMarkets),
      viewMode,
      selectedMarketId,
      isDrawerOpen,
      drawerMode,
      inputAmount,
      userBalance,
      submitting,
      onChangeViewMode: setViewMode,
      onSelectMarket: (id) => setSelectedMarketId(id),
      onOpenDrawer: () => setIsDrawerOpen(true),
      onCloseDrawer: () => setIsDrawerOpen(false),
      onChangeDrawerMode: setDrawerMode,
      onChangeInputAmount: setInputAmount,
      onSupplyDebt: async () => {},
      onDepositCollateral: async () => {},
      onBorrowDebt: async () => {},
      renderConnect: <ConnectButton />,
    };
  }, [useSampleData, account?.address, viewMode, selectedMarketId, isDrawerOpen, drawerMode, inputAmount, userBalance, submitting, indexedMarkets]);

  async function fakeWait() { return new Promise((r) => setTimeout(r, 500)); }

  return (
    <LendingComponent
      {...base}
      address={account?.address}
      viewMode={viewMode}
      selectedMarketId={selectedMarketId}
      isDrawerOpen={isDrawerOpen}
      drawerMode={drawerMode}
      inputAmount={inputAmount}
      userBalance={userBalance}
      submitting={submitting}
      onChangeViewMode={setViewMode}
      onSelectMarket={(id) => { setSelectedMarketId(id); }}
      onOpenDrawer={() => setIsDrawerOpen(true)}
      onCloseDrawer={() => setIsDrawerOpen(false)}
      onChangeDrawerMode={setDrawerMode}
      onChangeInputAmount={setInputAmount}
      onSupplyDebt={async () => { setSubmitting(true); try { await fakeWait(); } finally { setSubmitting(false); } }}
      onDepositCollateral={async () => { setSubmitting(true); try { await fakeWait(); } finally { setSubmitting(false); } }}
      onBorrowDebt={async () => { setSubmitting(true); try { await fakeWait(); } finally { setSubmitting(false); } }}
    />
  );
}

export default LendingWrapper;


