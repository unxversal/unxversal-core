import type { GasFuturesComponentProps } from './types';

export const gasFuturesSampleData: GasFuturesComponentProps = {
  marketLabel: 'MIST Gas Futures',
  symbol: 'MIST',
  quoteSymbol: 'USDC',
  protocolStatus: { options: true, futures: true, perps: true, lending: true, staking: true, dex: true },
  expiries: [
    { id: 'front', label: 'Front', expiryDate: Date.now() + 3 * 24 * 3600 * 1000, isActive: true },
    { id: 'next', label: 'Next', expiryDate: Date.now() + 30 * 24 * 3600 * 1000 },
  ],
  summary: {
    last: 3000, // MIST per unit (example)
    vol24h: 2_150_000,
    high24h: 3400,
    low24h: 2800,
    change24h: 5.2,
    openInterest: 1_550_000,
    expiryDate: Date.now() + 3 * 24 * 3600 * 1000,
    timeToExpiry: 3 * 24 * 3600 * 1000,
  },
  ohlc: {
    candles: Array.from({ length: 200 }).map((_, i) => {
      const t = Math.floor(Date.now() / 1000) - (200 - i) * 60;
      const base = 3000 + Math.sin(i / 14) * 60 + (Math.random() - 0.5) * 30;
      const open = base;
      const close = base + (Math.random() - 0.5) * 80;
      const high = Math.max(open, close) + Math.random() * 40;
      const low = Math.min(open, close) - Math.random() * 40;
      return { time: t, open, high, low, close, volume: Math.round(20_000 + Math.random() * 10_000) };
    }),
  },
  orderbook: {
    bids: Array.from({ length: 15 }).map((_, i) => [3000 - i * 5, Math.round(5_000 + Math.random() * 2_000)]) as [number, number][],
    asks: Array.from({ length: 15 }).map((_, i) => [3005 + i * 5, Math.round(5_000 + Math.random() * 2_000)]) as [number, number][],
  },
  recentTrades: Array.from({ length: 20 }).map((_, i) => ({
    price: 3000 + (Math.random() - 0.5) * 50,
    qty: Math.round(10_000 + Math.random() * 8_000),
    ts: Date.now() - i * 60_000,
    side: Math.random() > 0.5 ? 'buy' : 'sell',
  })),
  positions: [
    { id: 'p1', side: 'Long', size: '150,000', entryPrice: '2950', markPrice: '3000', pnl: '+7,500', margin: '10,000', leverage: '8x' },
  ],
  openOrders: [
    { id: 'o1', type: 'Limit', side: 'Long', size: '50,000', price: '2980', total: '149,000', leverage: '5x', status: 'Open' },
  ],
  twap: [
    { period: '1h', twap: '2998', volume: '285,000' },
    { period: '4h', twap: '3011', volume: '1,125,000' },
  ],
};


