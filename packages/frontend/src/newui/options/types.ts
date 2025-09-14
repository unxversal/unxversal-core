export type UTCTimestamp = number;

export type Timeframe = '1m' | '5m' | '15m' | '1h' | '1d' | '7d';

export interface Candle {
  time: UTCTimestamp;
  open: number;
  high: number;
  low: number;
  close: number;
  volume?: number;
}

export interface OhlcSeries {
  candles: Candle[];
  volumes?: { time: UTCTimestamp; value: number }[];
}

export interface OptionsSummary {
  last?: number; // underlying last price
  vol24h?: number; // 24h options premium volume (quote)
  high24h?: number;
  low24h?: number;
  change24h?: number; // underlying 24h % change
  openInterest?: number; // total OI (contracts)
  iv30?: number; // 30d implied vol (0..1)
  nextExpiry?: number; // ms epoch
}

export interface OpenInterestByExpiry {
  expiryMs: number;
  oiUnits: number;
}

export interface OptionChainRow {
  strike: number; // quote units per base (e.g., 1.25)
  callBid: number | null;
  callAsk: number | null;
  putBid: number | null;
  putAsk: number | null;
  callIv?: number;
  putIv?: number;
  openInterest?: number; // per strike / series OI
  volume?: number; // recent 24h trades count or quote notional
  changePercent?: number; // per strike premium change (%)
  changeAmount?: number; // per strike premium change in quote
  breakeven?: number; // UI metric
  priceChange24h?: number; // sign for badge coloring
  seriesKeyCall?: string; // optional series key ids
  seriesKeyPut?: string;
}

export interface TradeFill {
  maker: string;
  taker: string;
  priceQuote: number;
  baseQty: number;
  tsMs: number;
}

export interface PositionRow {
  positionId: string;
  seriesKey: string;
  amountUnits: number;
  expiryMs: number;
  isCall: boolean;
  strike1e6: number;
  entryPriceQuote?: number;
  markPriceQuote?: number;
  pnlQuote?: number;
}

export interface UserOrderRow {
  orderId: string;
  seriesKey: string;
  isBid: boolean;
  priceQuote: number;
  qtyRemaining: number;
  expiryMs: number;
  status?: 'pending' | 'open' | 'filled' | 'cancelled' | 'expired';
}

export interface OrderHistoryRow {
  kind: 'placed' | 'canceled' | 'expired' | 'filled';
  orderId: string;
  seriesKey: string;
  tsMs: number;
  delta?: any;
}

export interface PortfolioSummary {
  premiumPaidQuote?: string;
  premiumReceivedQuote?: string;
}

export interface WalletStakingSummary {
  staked: string; // formatted
  aprPct: number;
}

export interface OptionsActions {
  onPlaceSellOrder: (params: any) => Promise<void> | void;
  onPlaceBuyOrder: (params: any) => Promise<void> | void;
  onCancelOrder: (params: any) => Promise<void> | void;
  onExercise: (params: any) => Promise<void> | void;
  onSettleAfterExpiry: (params: any) => Promise<void> | void;
}

export interface OptionsComponentProps extends OptionsActions {
  // selection/meta
  selectedSymbol: string;
  allSymbols: string[];
  onSelectSymbol: (sym: string) => void;
  symbolIconMap?: Record<string, string>;
  selectedExpiryMs: number | null;
  availableExpiriesMs: number[];
  onSelectExpiry: (ms: number) => void;

  marketId: string;
  feeConfigId: string;
  feeVaultId: string;
  stakingPoolId: string;
  rewardsId: string;
  pythSymbol: string;

  // ticker/stats
  summary: OptionsSummary;
  oiByExpiry: OpenInterestByExpiry[];

  // chain data for selected expiry
  chainRows: OptionChainRow[];
  underlyingPrice?: number; // for price indicator convenience

  // user-scoped
  positions: PositionRow[];
  openOrders: UserOrderRow[];
  tradeHistory: TradeFill[];
  orderHistory: OrderHistoryRow[];
  portfolioSummary?: PortfolioSummary | null;
  leaderboardRank?: number | null;
  leaderboardPoints?: number | null;
  walletStakingSummary?: WalletStakingSummary | null;
}


