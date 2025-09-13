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
  expiryDate?: number;
  timeToExpiry?: number;
}

export interface OrderbookSnapshot {
  bids: [number, number][];
  asks: [number, number][];
}

export interface RecentTradeRow {
  price: number;
  qty: number;
  ts: number;
  side: 'buy' | 'sell';
}

export interface PositionRow {
  id?: string;
  side: 'Long' | 'Short';
  size: number | string;
  entryPrice: number | string;
  markPrice: number | string;
  pnl: number | string;
  margin: number | string;
  leverage: number | string;
}

export interface OrderRow {
  id?: string;
  type: string;
  side: 'Long' | 'Short';
  size: number | string;
  price: number | string;
  total: number | string;
  leverage: number | string;
  status: string;
}

export interface TwapRow {
  period: string;
  twap: string;
  volume: string;
}

export interface ExpiryContract {
  id: string;
  label: string;
  expiryDate: number;
  isActive?: boolean;
}

export interface ProtocolStatus {
  options: boolean;
  futures: boolean;
  perps: boolean;
  lending: boolean;
  staking: boolean;
  dex: boolean;
}

export interface GasFuturesComponentProps {
  address?: string;
  network?: string;
  protocolStatus?: ProtocolStatus;

  marketLabel: string; // e.g. "MIST Gas Futures"
  symbol: string; // "MIST"
  quoteSymbol?: string; // usually "USDC"

  expiries?: ExpiryContract[];
  onExpiryChange?: (expiryId: string) => void;

  summary?: MarketSummary;
  ohlc?: { candles: Candle[]; volumes?: { time: UTCTimestamp; value: number }[] };
  orderbook?: OrderbookSnapshot;
  recentTrades?: RecentTradeRow[];
  positions?: PositionRow[];
  openOrders?: OrderRow[];
  twap?: TwapRow[];

  TradePanelComponent?: (props: { baseSymbol: string; quoteSymbol: string; mid: number }) => React.ReactElement;
}


