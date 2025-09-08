export type UTCTimestamp = number;

export interface Candle {
  time: UTCTimestamp;
  open: number;
  high: number;
  low: number;
  close: number;
  volume?: number;
}

export interface OptionsSummary {
  last?: number;
  vol24h?: number;
  high24h?: number;
  low24h?: number;
  change24h?: number;
  openInterest?: number;
  iv30?: number;
  nextExpiry?: number;
}

export interface OptionsChainRow {
  strike: number;
  callBid: number;
  callAsk: number;
  putBid: number;
  putAsk: number;
  callIv?: number;
  putIv?: number;
  openInterest?: number;
  volume?: number;
  changePercent?: number;
  changeAmount?: number;
  chanceOfProfit?: number;
  breakeven?: number;
  priceChange24h?: number;
}

export interface OptionsDataProvider {
  getSummary?: () => Promise<OptionsSummary>;
  getOhlc?: (timeframe: '1m' | '5m' | '15m' | '1h' | '1d' | '7d') => Promise<{ candles: Candle[]; volumes?: { time: UTCTimestamp; value: number }[] }>;
  getChain?: (expiryId: string) => Promise<OptionsChainRow[]>;
}


