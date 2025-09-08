export type UTCTimestamp = number;

export interface Candle {
  time: UTCTimestamp;
  open: number;
  high: number;
  low: number;
  close: number;
  volume?: number;
}

export interface MarketSummary {
  last?: number;
  vol24h?: number;
  high24h?: number;
  low24h?: number;
  change24h?: number;
  openInterest?: number;
  fundingRate?: number;
  nextFunding?: number; // ms timestamp
  expiryDate?: number; // ms timestamp for futures contracts
  timeToExpiry?: number; // ms remaining until expiry
}

export interface OrderbookSnapshot {
  bids: [number, number][];
  asks: [number, number][];
}

export type TradeSide = 'buy' | 'sell';

export interface RecentTradeRow {
  price: number;
  qty: number;
  ts: number; // seconds
  side: TradeSide;
}

export interface PositionRow {
  id?: string;
  side: 'Long' | 'Short';
  size: number | string;
  entryPrice: number | string;
  markPrice: number | string;
  pnl: number | string; // allow "+165.00" style for mocks
  margin: number | string;
  leverage: number | string;
}

export interface OrderRow {
  id?: string;
  type: string; // Limit/Market/Stop/...
  side: 'Long' | 'Short';
  size: number | string;
  price: number | string;
  total: number | string;
  leverage: number | string;
  status: string; // Open/Pending/Filled/...
}

export interface FundingHistoryRow {
  timestamp: string;
  rate: string; // e.g. "0.0125%"
  payment: string; // e.g. "+0.43 USDC"
}

export interface TwapRow {
  period: string; // e.g. "1h"
  twap: string; // e.g. price string
  volume: string; // e.g. qty string
}

export interface DerivativesDataProvider {
  getSummary?: () => Promise<MarketSummary>;
  getOhlc?: (timeframe: '1m' | '5m' | '15m' | '1h' | '1d' | '7d') => Promise<{ candles: Candle[]; volumes?: { time: UTCTimestamp; value: number }[] }>;
  getOrderbook?: () => Promise<OrderbookSnapshot>;
  getRecentTrades?: () => Promise<RecentTradeRow[]>;
  getPositions?: () => Promise<PositionRow[]>;
  getOpenOrders?: () => Promise<OrderRow[]>;
  getFundingHistory?: () => Promise<FundingHistoryRow[]>;
  getTwap?: () => Promise<TwapRow[]>;
}

export interface TradePanelDataProvider {
  getBalances?: () => Promise<{ base: number; quote: number }>;
  getAccountMetrics?: () => Promise<{ accountValue: number; marginRatio: number }>;
  getFeeInfo?: () => Promise<{ takerBps: number; unxvDiscountBps: number }>;
  getActiveStake?: (address: string) => Promise<number>;
  submitOrder?: (o: { side: 'long' | 'short'; mode: 'market' | 'limit'; size: number; price?: number; leverage: number }) => Promise<void>;
}

export interface TradePanelProps {
  baseSymbol: string;
  quoteSymbol: string;
  mid: number;
  provider?: TradePanelDataProvider;
}

export interface ExpiryContract {
  id: string;
  label: string; // e.g. "Jan 25", "Mar 25"
  expiryDate: number; // ms timestamp
  isActive?: boolean; // currently selected
}

export interface DerivativesScreenProps {
  started?: boolean;
  surgeReady?: boolean;
  network?: string;
  marketLabel: string; // e.g. "MIST Futures", "MIST Perps"
  symbol: string; // e.g. "MIST"
  quoteSymbol?: string; // e.g. "USDC"
  dataProvider?: DerivativesDataProvider;
  panelProvider?: TradePanelDataProvider;
  TradePanelComponent?: (props: TradePanelProps) => React.ReactElement;
  availableExpiries?: ExpiryContract[]; // for futures contracts
  onExpiryChange?: (expiryId: string) => void;
  protocolStatus?: {
    options: boolean;
    futures: boolean;
    perps: boolean;
    lending: boolean;
    staking: boolean;
    dex: boolean;
  };
}


