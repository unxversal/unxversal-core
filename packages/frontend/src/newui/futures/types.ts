export type UTCTimestamp = number;

// ===== Summary & market meta =====
export interface FuturesSummary {
  last?: number; // last trade or mark price (quote units)
  change24h?: number; // % change over 24h
  vol24h?: number; // 24h quote notional
  openInterest?: number; // total OI (contracts)
  expiryMs?: number | null; // selected contract expiry
  timeToExpiryMs?: number | null;
  twap5m?: number; // 5-minute TWAP if available
}

export interface OrderbookLevel {
  price: number;
  qty: number; // base contracts at that price
}

export interface OrderbookSnapshot {
  bids: OrderbookLevel[]; // sorted desc by price
  asks: OrderbookLevel[]; // sorted asc by price
}

export interface TradeFillRow {
  maker: string;
  taker: string;
  priceQuote: number; // quote price per base contract (or per unit consistent with contract_size)
  baseQty: number;
  tsMs: number;
}

export interface UserOrderRow {
  orderId: string;
  marketId: string;
  isBid: boolean; // true=buy/long, false=sell/short
  priceQuote: number;
  qtyRemaining: number;
  expireTs: number;
  status?: 'pending' | 'open' | 'filled' | 'cancelled' | 'expired';
}

export interface OrderHistoryRow {
  kind: 'placed' | 'canceled' | 'expired' | 'filled';
  orderId: string;
  marketId: string;
  tsMs: number;
  delta?: any;
}

export interface PositionHealth {
  equityQuote?: number; // approximate equity in quote
  imRequiredQuote?: number; // initial margin requirement
  mmRequiredQuote?: number; // maintenance margin requirement
  healthRatio?: number; // equity / IM (or MM) as fraction
  leverage?: number; // notional / equity
}

export interface FuturesPositionRow {
  marketId: string;
  symbol: string; // e.g., "SUI/USDC"
  expiryMs: number | null; // perpetual-like series would be null or 0
  contractSize: number; // quote units per 1 contract when price scaled 1e6 (from Move)
  longQty: number;
  shortQty: number;
  avgLong1e6: number;
  avgShort1e6: number;
  markPrice1e6?: number;
  pnlQuote?: number; // realized approx or mark-to-market delta
  health?: PositionHealth;
}

export interface WalletStakingSummary {
  staked?: string;
  aprPct?: number;
}

export interface FuturesActions {
  onOpenLong: (args: { marketId: string; qty: number; limitPrice1e6?: number; payWithUnxv?: boolean }) => Promise<void> | void;
  onOpenShort: (args: { marketId: string; qty: number; limitPrice1e6?: number; payWithUnxv?: boolean }) => Promise<void> | void;
  onCloseLong: (args: { marketId: string; qty: number; limitPrice1e6?: number; payWithUnxv?: boolean }) => Promise<void> | void;
  onCloseShort: (args: { marketId: string; qty: number; limitPrice1e6?: number; payWithUnxv?: boolean }) => Promise<void> | void;
  onCancelOrder: (orderId: string) => Promise<void> | void;
  onDepositCollateral?: (args: { marketId: string; collatCoinId: string }) => Promise<void> | void;
  onWithdrawCollateral?: (args: { marketId: string; amount: number }) => Promise<void> | void;
}

export interface FuturesComponentProps extends FuturesActions {
  // selection/meta
  selectedSymbol: string; // e.g., "SUI/USDC"
  allSymbols: string[];
  onSelectSymbol: (sym: string) => void;
  symbolIconMap?: Record<string, string>;

  selectedExpiryMs: number | null;
  availableExpiriesMs: number[]; // per selectedSymbol
  onSelectExpiry: (ms: number) => void;

  // IDs (to be passed to client actions)
  marketId: string; // selected market
  feeConfigId?: string;
  feeVaultId?: string;
  stakingPoolId?: string;
  rewardsId?: string;
  oracleRegistryId?: string;
  aggregatorId?: string;

  // ticker/stats for selected market
  summary: FuturesSummary;
  orderBook: OrderbookSnapshot;
  recentTrades: TradeFillRow[];

  // risk & params
  initialMarginBps?: number;
  maintenanceMarginBps?: number;
  maxLeverage?: number; // computed off IM bps

  // user-scoped (global, across markets)
  positions: FuturesPositionRow[];
  openOrders: UserOrderRow[];
  tradeHistory: TradeFillRow[];
  orderHistory: OrderHistoryRow[];
  leaderboardRank?: number | null;
  leaderboardPoints?: number | null;
  walletStakingSummary?: WalletStakingSummary | null;
}


