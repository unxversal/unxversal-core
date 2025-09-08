import type { Candle, DerivativesDataProvider, FundingHistoryRow, OrderRow, PositionRow, RecentTradeRow, TwapRow, UTCTimestamp } from '../types';

function generateCandles(now: number, step: number, count: number): { candles: Candle[]; volumes: { time: UTCTimestamp; value: number }[] } {
  const candles: Candle[] = [];
  const volumes: { time: UTCTimestamp; value: number }[] = [];
  let base = 0.023;
  for (let i = count; i >= 0; i--) {
    const time = (now - i * step) as UTCTimestamp;
    const noise = (Math.sin(i/12) + Math.random()*0.3 - 0.15) * 0.002;
    const open = base;
    const close = base + noise;
    const high = Math.max(open, close) + Math.random()*0.001;
    const low = Math.min(open, close) - Math.random()*0.001;
    base = close;
    candles.push({ time, open, high, low, close });
    volumes.push({ time, value: Math.round(50000 + Math.random()*30000) });
  }
  return { candles, volumes };
}

export function createMockDerivativesProvider(): DerivativesDataProvider {
  return {
    async getSummary() {
      return {
        last: 0.0234,
        vol24h: 2150000,
        high24h: 0.0256,
        low24h: 0.0221,
        change24h: 4.70,
        openInterest: 15750000,
        fundingRate: 0.0125,
        nextFunding: Date.now() + 3599000,
      };
    },
    async getOhlc(tf) {
      const now = Math.floor(Date.now()/1000);
      const step = tf === '1m' ? 60 : tf === '5m' ? 300 : tf === '15m' ? 900 : tf === '1h' ? 3600 : tf === '1d' ? 86400 : 604800;
      const { candles, volumes } = generateCandles(now, step, 300);
      return { candles, volumes };
    },
    async getOrderbook() {
      const midPrice = 0.02345;
      const spread = 0.00005;
      const bids = Array.from({ length: 16 }, (_, i) => [
        midPrice - (spread / 2) - (i * 0.00002), 
        Math.round((Math.random() * 100000 + 5000) * (16 - i) / 16)
      ]) as [number, number][];
      const asks = Array.from({ length: 16 }, (_, i) => [
        midPrice + (spread / 2) + (i * 0.00002), 
        Math.round((Math.random() * 100000 + 5000) * (16 - i) / 16)
      ]) as [number, number][];
      return { bids, asks };
    },
    async getRecentTrades() {
      const now = Date.now() / 1000;
      const basePrice = 0.02345;
      return Array.from({ length: 30 }, (_, i) => ({
        price: basePrice + (Math.random() - 0.5) * 0.002,
        qty: Math.round((Math.random() * 150000 + 5000)),
        ts: now - (i * 30),
        side: Math.random() > 0.5 ? 'buy' as const : 'sell' as const,
      })) as RecentTradeRow[];
    },
    async getPositions() {
      return [
        { id: '1', side: 'Long', size: 150000, entryPrice: 0.0234, markPrice: 0.0245, pnl: 165, margin: 1250, leverage: 10 },
      ] as PositionRow[];
    },
    async getOpenOrders() {
      return [
        { id: '1', type: 'Limit', side: 'Long', size: 200000, price: 0.0230, total: 4600.00, leverage: 5, status: 'Open' },
        { id: '2', type: 'Stop', side: 'Short', size: 100000, price: 0.0250, total: 2500.00, leverage: 10, status: 'Pending' },
      ] as OrderRow[];
    },
    async getFundingHistory() {
      return [
        { timestamp: '2024-01-15 08:00:00', rate: '0.0125%', payment: '-1.25 USDC' },
        { timestamp: '2024-01-15 00:00:00', rate: '0.0087%', payment: '-0.87 USDC' },
        { timestamp: '2024-01-14 16:00:00', rate: '-0.0043%', payment: '+0.43 USDC' },
      ] as FundingHistoryRow[];
    },
    async getTwap() {
      return [
        { period: '1h', twap: '0.02341', volume: '125,000' },
        { period: '4h', twap: '0.02356', volume: '485,000' },
        { period: '24h', twap: '0.02389', volume: '2,150,000' },
      ] as TwapRow[];
    },
  };
}

export function createMockTradePanelProvider() {
  return {
    async getBalances() {
      return { base: 1500000, quote: 25000 };
    },
    async getAccountMetrics() {
      return { accountValue: 27500, marginRatio: 0.15 };
    },
    async getFeeInfo() {
      return { takerBps: 70, unxvDiscountBps: 3000 };
    },
    async getActiveStake() {
      return 0;
    },
    async submitOrder() {
      await new Promise(r => setTimeout(r, 500));
    },
  };
}


