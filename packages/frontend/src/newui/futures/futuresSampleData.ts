import type { FuturesComponentProps } from './types';

export const futuresSampleData: FuturesComponentProps = {
  marketLabel: 'Futures',
  symbol: 'SUI',
  quoteSymbol: 'USDC',
  protocolStatus: { options: true, futures: true, perps: true, lending: true, staking: true, dex: true },
  markets: [
    { marketId: 'sui', symbol: 'SUI/USDC', label: 'SUI' },
    { marketId: 'mist', symbol: 'MIST/USDC', label: 'MIST Gas Futures' },
    { marketId: 'btc', symbol: 'BTC/USDC', label: 'BTC' },
  ],
  selectedMarketId: 'sui',
  expiries: [
    { id: 'sep', label: 'Sep 26', expiryDate: Date.now() + 3 * 24 * 3600 * 1000, isActive: true },
    { id: 'oct', label: 'Oct 31', expiryDate: Date.now() + 40 * 24 * 3600 * 1000 },
    { id: 'dec', label: 'Dec 27', expiryDate: Date.now() + 110 * 24 * 3600 * 1000 },
  ],
  summary: {
    last: 1.2345,
    vol24h: 1_250_000,
    high24h: 1.289,
    low24h: 1.201,
    change24h: 2.45,
    openInterest: 4_250_000,
    expiryDate: Date.now() + 3 * 24 * 3600 * 1000,
    timeToExpiry: 3 * 24 * 3600 * 1000,
  },
  ohlc: {
    candles: Array.from({ length: 200 }).map((_, i) => {
      const t = Math.floor(Date.now() / 1000) - (200 - i) * 60;
      const base = 1.2 + Math.sin(i / 14) * 0.02 + (Math.random() - 0.5) * 0.01;
      const open = base;
      const close = base + (Math.random() - 0.5) * 0.02;
      const high = Math.max(open, close) + Math.random() * 0.01;
      const low = Math.min(open, close) - Math.random() * 0.01;
      return { time: t, open, high, low, close, volume: Math.round(20_000 + Math.random() * 10_000) };
    }),
  },
  orderbook: {
    bids: Array.from({ length: 15 }).map((_, i) => [1.2340 - i * 0.0005, Math.round(5_000 + Math.random() * 2_000)]) as [number, number][],
    asks: Array.from({ length: 15 }).map((_, i) => [1.2350 + i * 0.0005, Math.round(5_000 + Math.random() * 2_000)]) as [number, number][],
  },
  recentTrades: Array.from({ length: 20 }).map((_, i) => ({
    price: 1.234 + (Math.random() - 0.5) * 0.01,
    qty: Math.round(10_000 + Math.random() * 8_000),
    ts: Date.now() - i * 60_000,
    side: Math.random() > 0.5 ? 'buy' : 'sell',
  })),
  positions: [
    { id: 'p1', side: 'Long', size: '150,000', entryPrice: '1.2250', markPrice: '1.2345', pnl: '+1,325.00', margin: '10,000.00', leverage: '8x' },
    { id: 'p2', side: 'Short', size: '75,000', entryPrice: '1.2420', markPrice: '1.2345', pnl: '+562.50', margin: '6,500.00', leverage: '6x' },
  ],
  openOrders: [
    { id: 'o1', type: 'Limit', side: 'Long', size: '50,000', price: '1.2300', total: '61,500.00', leverage: '5x', status: 'Open' },
    { id: 'o2', type: 'Stop', side: 'Short', size: '40,000', price: '1.2450', total: '49,800.00', leverage: '7x', status: 'Pending' },
  ],
  twap: [
    { period: '1h', twap: '1.2339', volume: '285,000' },
    { period: '4h', twap: '1.2341', volume: '1,125,000' },
    { period: '24h', twap: '1.2355', volume: '6,450,000' },
  ],
};


