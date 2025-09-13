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

export type TradeSide = 'buy' | 'sell';

export interface RecentTradeRow {
  price: number;
  qty: number;
  ts: number; // seconds or ms supported by consumer
  side: TradeSide;
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
  type: string; // Limit/Market/Stop/...
  side: 'Long' | 'Short';
  size: number | string;
  price: number | string;
  total: number | string;
  leverage: number | string;
  status: string; // Open/Pending/Filled/...
}

export interface TwapRow {
  period: string; // e.g. "1h"
  twap: string; // price as string for display
  volume: string; // qty as string for display
}

export interface ExpiryContract {
  id: string;
  label: string;
  expiryDate: number;
  isActive?: boolean;
}

export interface MarketMeta {
  marketId: string;
  symbol: string; // e.g. "SUI/USDC"
  label?: string; // optional display label (e.g. "SUI")
}

export interface ProtocolStatus {
  options: boolean;
  futures: boolean;
  perps: boolean;
  lending: boolean;
  staking: boolean;
  dex: boolean;
}

export interface FuturesComponentProps {
  address?: string;
  network?: string;
  protocolStatus?: ProtocolStatus;

  marketLabel?: string; // optional; if markets provided, UI uses dropdown instead
  symbol: string; // base symbol, e.g. "SUI"
  quoteSymbol?: string; // e.g. "USDC"

  markets?: MarketMeta[];
  selectedMarketId?: string;
  onSelectMarket?: (marketId: string) => void;

  expiries?: ExpiryContract[];
  onExpiryChange?: (expiryId: string) => void;

  summary?: MarketSummary;
  ohlc?: { candles: Candle[]; volumes?: { time: UTCTimestamp; value: number }[] };
  orderbook?: OrderbookSnapshot;
  recentTrades?: RecentTradeRow[];
  positions?: PositionRow[];
  openOrders?: OrderRow[];
  twap?: TwapRow[];

  // Optional trade panel component for actions; pure UI wrapper
  TradePanelComponent?: (props: { baseSymbol: string; quoteSymbol: string; mid: number }) => React.ReactElement;
}


