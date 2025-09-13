import type { LendingComponentProps } from './types';
import { MARKETS } from '../../lib/markets';
import { getTokenBySymbol, loadSettings } from '../../lib/settings.config';

function buildMarketsSample(): LendingComponentProps['markets'] {
  const settings = loadSettings();
  const pairs = MARKETS.usdc;
  const out: NonNullable<LendingComponentProps['markets']> = [];
  let idx = 0;
  for (const pair of pairs) {
    const [baseSym] = pair.split('/') as [string, string];
    const base = getTokenBySymbol(baseSym, settings);
    const collName = base?.name ?? baseSym;
    const collDec = base?.decimals ?? 9;
    // Deterministic pseudo values
    const baseSupplyApy = (
      baseSym === 'SUI' ? 2.8 :
      baseSym === 'DEEP' ? 5.2 :
      baseSym === 'UNXV' ? 6.1 :
      baseSym.includes('BTC') ? 1.9 :
      baseSym.includes('ETH') ? 2.3 :
      baseSym.startsWith('W') ? 2.1 :
      baseSym.includes('USD') ? 3.8 :
      2.5 + ((idx % 7) * 0.3)
    );
    const borrowApy = baseSupplyApy + 1.2 + ((idx % 5) * 0.25);
    const baseSupplyDebt = (
      baseSym === 'SUI' ? 45_000_000 + (idx % 9) * 2_500_000 :
      baseSym.includes('BTC') ? 12_000_000 + (idx % 7) * 1_000_000 :
      baseSym.includes('ETH') ? 9_000_000 + (idx % 5) * 800_000 :
      baseSym === 'DEEP' ? 12_000_000 + (idx % 6) * 1_300_000 :
      baseSym === 'UNXV' ? 25_000_000 + (idx % 8) * 2_000_000 :
      6_000_000 + (idx % 10) * 500_000
    );
    const util = 0.30 + ((idx % 8) * 0.05); // 30% .. 65%
    const totalBorrowDebt = Math.floor(baseSupplyDebt * Math.min(0.85, util));
    const totalLiquidityDebt = baseSupplyDebt - totalBorrowDebt;
    const maxLtv = (
      baseSym.includes('USD') ? 85 :
      baseSym === 'SUI' ? 75 :
      (baseSym.includes('BTC') || baseSym.includes('ETH')) ? 70 :
      65 + (idx % 6)
    );
    const liquidationThreshold = Math.min(95, maxLtv + 5 + (idx % 3));
    const reserveFactor = 10 + (idx % 11); // 10..20
    const userSuppliedDebt = idx % 3 === 0 ? 1_000 + (idx % 7) * 2_500 : undefined;
    const userBorrowedDebt = idx % 5 === 0 ? 500 + (idx % 5) * 1_000 : undefined;
    const userCollateral = idx % 4 === 0 ? 50 + (idx % 7) * 40 : undefined;
    const userHealthFactor = userBorrowedDebt ? (1.2 + (idx % 6) * 0.15) : undefined;

    out.push({
      id: `mkt-${baseSym.toLowerCase()}-usdc`,
      symbolPair: pair,
      collateral: { symbol: baseSym, name: collName, decimals: collDec, typeTag: base?.typeTag ?? '' },
      debt: { symbol: 'USDC', name: 'USD Coin', decimals: 6, typeTag: '' },
      supplyApy: Number(baseSupplyApy.toFixed(2)),
      borrowApy: Number(borrowApy.toFixed(2)),
      totalSupplyDebt: baseSupplyDebt,
      totalBorrowDebt,
      utilizationRate: Number(((totalBorrowDebt / baseSupplyDebt) * 100).toFixed(1)),
      totalLiquidityDebt,
      maxLtv,
      liquidationThreshold,
      reserveFactor,
      userSuppliedDebt,
      userBorrowedDebt,
      userCollateral,
      userHealthFactor,
    });
    idx += 1;
  }
  return out;
}

export const lendingSampleData: LendingComponentProps = {
  address: '0xuser',
  network: 'testnet',
  protocolStatus: { options: true, futures: true, perps: true, lending: true, staking: true, dex: true },
  tvlUsd: 2_400_000_000,
  activeUsers: 12_300,
  markets: buildMarketsSample(),
  viewMode: 'markets',
  selectedMarketId: undefined,
  isDrawerOpen: false,
  drawerMode: 'supplyDebt',
  inputAmount: 0,
  userBalance: 1000,
  submitting: false,
  onChangeViewMode: () => {},
  onSelectMarket: () => {},
  onOpenDrawer: () => {},
  onCloseDrawer: () => {},
  onChangeDrawerMode: () => {},
  onChangeInputAmount: () => {},
  onSupplyDebt: async () => {},
  onDepositCollateral: async () => {},
  onBorrowDebt: async () => {},
  renderConnect: null,
};


