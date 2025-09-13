export type ViewMode = 'markets' | 'portfolio';

export type LendingDrawerMode = 'supplyDebt' | 'depositCollat' | 'borrowDebt';

export interface TokenMeta {
  symbol: string;
  name: string;
  decimals: number;
  typeTag: string;
  iconUrl?: string;
}

export interface LendingMarketSummary {
  id: string;
  symbolPair: string; // e.g. "SUI/USDC"
  collateral: TokenMeta; // volatile asset
  debt: TokenMeta; // stablecoin (e.g. USDC/USDU)

  // Pool metrics (debt side notionals)
  supplyApy: number; // %
  borrowApy: number; // %
  totalSupplyDebt: number; // debt units notionally USD
  totalBorrowDebt: number; // debt units notionally USD
  utilizationRate: number; // %
  totalLiquidityDebt: number; // debt units

  // Risk params (bps expressed as % in UI)
  maxLtv: number; // %
  liquidationThreshold: number; // %
  reserveFactor: number; // %

  // Optional user fields for portfolio view
  userSuppliedDebt?: number;
  userBorrowedDebt?: number;
  userCollateral?: number; // units of collateral token
  userHealthFactor?: number; // computed using LT vs owed
}

export interface ProtocolStatus {
  options: boolean;
  futures: boolean;
  perps: boolean;
  lending: boolean;
  staking: boolean;
  dex: boolean;
}

export interface LendingComponentProps {
  // Identity and header
  address?: string;
  network?: string;
  protocolStatus?: ProtocolStatus;
  tvlUsd?: number;
  activeUsers?: number;

  // Data
  markets: LendingMarketSummary[];

  // UI state
  viewMode: ViewMode;
  selectedMarketId?: string;
  isDrawerOpen: boolean;
  drawerMode: LendingDrawerMode;
  inputAmount: number; // numeric for simplicity of calc/display
  userBalance: number; // balance for the currently active asset context
  submitting: boolean;

  // Handlers
  onChangeViewMode: (mode: ViewMode) => void;
  onSelectMarket: (marketId: string) => void;
  onOpenDrawer: () => void;
  onCloseDrawer: () => void;
  onChangeDrawerMode: (mode: LendingDrawerMode) => void;
  onChangeInputAmount: (value: number) => void;

  // Actions
  onSupplyDebt: (args: { marketId: string; amount: number }) => Promise<void>;
  onDepositCollateral: (args: { marketId: string; amount: number }) => Promise<void>;
  onBorrowDebt: (args: { marketId: string; amount: number }) => Promise<void>;

  // Optional custom connect UI
  renderConnect?: React.ReactNode;
}


