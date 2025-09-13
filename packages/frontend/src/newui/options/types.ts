export interface TokenInfo {
  symbol: string;
  name: string;
  typeTag: string;
  decimals: number;
  iconUrl?: string;
  price: number;
  priceChange24h: number;
  volume24h: number;
}

export interface OptionSeries {
  key: string;
  expiry_ms: number;
  strike_1e6: number;
  is_call: boolean;
  symbol: string;
  cash_settled: boolean;
  cap_1e6: number;
  market_id: string;
}

export interface OptionChainEntry {
  series: OptionSeries;
  strike: number;
  call_bid?: number;
  call_ask?: number;
  call_last?: number;
  call_volume: number;
  call_open_interest: number;
  put_bid?: number;
  put_ask?: number;
  put_last?: number;
  put_volume: number;
  put_open_interest: number;
  strike_price_position: 'above' | 'at' | 'below'; // relative to current asset price
}

export interface OrderBookLevel {
  price: number;
  quantity: number;
  orders: number;
}

export interface OrderBook {
  bids: OrderBookLevel[];
  asks: OrderBookLevel[];
  spread?: number;
  mid_price?: number;
}

export interface Trade {
  id: string;
  timestamp: number;
  price: number;
  quantity: number;
  side: 'buy' | 'sell';
  series_key: string;
  maker: string;
  taker: string;
}

export interface OpenOrder {
  id: string;
  series_key: string;
  order_id: string;
  side: 'buy' | 'sell';
  price: number;
  original_quantity: number;
  remaining_quantity: number;
  filled_quantity: number;
  timestamp: number;
  expiry: number;
  status: 'open' | 'partially_filled';
}

export interface Position {
  series_key: string;
  series: OptionSeries;
  side: 'long' | 'short';
  quantity: number;
  average_price: number;
  mark_price: number;
  unrealized_pnl: number;
  timestamp: number;
}

export interface TradeHistoryEntry {
  id: string;
  timestamp: number;
  series_key: string;
  series: OptionSeries;
  side: 'buy' | 'sell';
  price: number;
  quantity: number;
  fee: number;
  total: number;
}

export interface OrderHistoryEntry {
  id: string;
  series_key: string;
  order_id: string;
  side: 'buy' | 'sell';
  price: number;
  original_quantity: number;
  filled_quantity: number;
  status: 'filled' | 'cancelled' | 'expired';
  timestamp: number;
  fill_timestamp?: number;
}

export interface WalletBalance {
  token_type: string;
  symbol: string;
  balance: number;
  usd_value: number;
}

export interface StakingInfo {
  staked_amount: number;
  pending_rewards: number;
  apy: number;
  unlock_time?: number;
}

export interface LeaderboardEntry {
  rank: number;
  address: string;
  points: number;
  volume: number;
  pnl: number;
}

export interface MarketStats {
  total_volume_24h: number;
  total_open_interest: number;
  expiry_open_interest: Record<number, number>; // expiry_ms -> OI
  active_series_count: number;
  unique_traders_24h: number;
}

export interface OptionsData {
  // Asset selection
  selected_asset: TokenInfo;
  available_assets: TokenInfo[];
  
  // Time selection
  selected_expiry?: number; // expiry_ms
  available_expiries: number[];
  
  // Market data
  market_stats: MarketStats;
  options_chain: OptionChainEntry[];
  order_book?: OrderBook; // for selected series
  recent_trades: Trade[];
  
  // User data
  positions: Position[];
  open_orders: OpenOrder[];
  trade_history: TradeHistoryEntry[];
  order_history: OrderHistoryEntry[];
  wallet_balances: WalletBalance[];
  staking_info: StakingInfo;
  
  // Leaderboard
  leaderboard: LeaderboardEntry[];
  user_rank?: number;
  user_points?: number;
  
  // UI state
  loading: boolean;
  error?: string;
}

export interface OptionsComponentProps {
  data: OptionsData;
  onAssetChange: (asset: TokenInfo) => void;
  onExpiryChange: (expiry: number) => void;
  onSeriesSelect: (series: OptionSeries) => void;
  onPlaceOrder: (order: PlaceOrderParams) => Promise<void>;
  onCancelOrder: (orderId: string) => Promise<void>;
  onExercise: (position: Position, amount: number) => Promise<void>;
  isConnected: boolean;
  userAddress?: string;
}

export interface PlaceOrderParams {
  series_key: string;
  side: 'buy' | 'sell';
  order_type: 'limit' | 'market';
  price?: number; // required for limit orders
  quantity: number;
  collateral_coin_id?: string; // for sell orders
}

// Event types for indexer
export interface SeriesCreatedEvent {
  market_id: string;
  key: string;
  expiry_ms: number;
  strike_1e6: number;
  is_call: boolean;
  symbol_bytes: number[];
  tick_size: number;
  lot_size: number;
  min_size: number;
  timestamp: number;
  tx_digest: string;
}

export interface OrderPlacedEvent {
  key: string;
  order_id: string;
  maker: string;
  price: number;
  quantity: number;
  is_bid: boolean;
  expire_ts: number;
  timestamp: number;
  tx_digest: string;
}

export interface OrderFilledEvent {
  key: string;
  maker_order_id: string;
  maker: string;
  taker: string;
  price: number;
  base_qty: number;
  premium_quote: number;
  maker_remaining_qty: number;
  timestamp_ms: number;
  tx_digest: string;
}

export interface MatchedEvent {
  key: string;
  taker: string;
  total_units: number;
  total_premium_quote: number;
  timestamp: number;
  tx_digest: string;
}

export interface ExercisedEvent {
  key: string;
  exerciser: string;
  amount: number;
  spot_1e6: number;
  timestamp: number;
  tx_digest: string;
}

export interface OptionPositionUpdatedEvent {
  key: string;
  owner: string;
  position_id: string;
  increase: boolean;
  delta_units: number;
  new_amount: number;
  timestamp_ms: number;
  tx_digest: string;
}

export interface SeriesSettledEvent {
  key: string;
  price_1e6: number;
  timestamp_ms: number;
  tx_digest: string;
}
