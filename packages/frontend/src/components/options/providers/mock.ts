import type { Candle, OptionsChainRow, OptionsDataProvider, OptionsSummary, UTCTimestamp } from '../types';

function generateCandles(now: number, step: number, count: number): { candles: Candle[]; volumes: { time: UTCTimestamp; value: number }[] } {
  const candles: Candle[] = [];
  const volumes: { time: UTCTimestamp; value: number }[] = [];
  let base = 1.0;
  for (let i = count; i >= 0; i--) {
    const time = (now - i * step) as UTCTimestamp;
    const noise = (Math.sin(i/10) + Math.random()*0.3 - 0.15) * 0.05;
    const open = base;
    const close = Math.max(0.2, base + noise);
    const high = Math.max(open, close) + Math.random()*0.03;
    const low = Math.max(0.2, Math.min(open, close) - Math.random()*0.03);
    base = close;
    candles.push({ time, open, high, low, close });
    volumes.push({ time, value: Math.round(500 + Math.random()*300) });
  }
  return { candles, volumes };
}

export function createMockOptionsProvider(): OptionsDataProvider {
  return {
    async getSummary(): Promise<OptionsSummary> {
      return {
        last: 0.97,
        vol24h: 120000,
        high24h: 1.12,
        low24h: 0.86,
        change24h: 1.85,
        openInterest: 580000,
        iv30: 0.58,
        nextExpiry: Date.now() + 5 * 24 * 60 * 60 * 1000,
      };
    },
    async getOhlc(tf) {
      const now = Math.floor(Date.now()/1000);
      const step = tf === '1m' ? 60 : tf === '5m' ? 300 : tf === '15m' ? 900 : tf === '1h' ? 3600 : tf === '1d' ? 86400 : 604800;
      const { candles, volumes } = generateCandles(now, step, 300);
      return { candles, volumes };
    },
    async getChain(expiryId) {
      // Use the actual spot price from getSummary to center the option chain
      const summary = await this.getSummary();
      const spotPrice = summary.last;
      
      // Generate strikes centered around spot price with proper rounding
      const strikeInterval = 0.05;
      const nearestStrike = Math.round(spotPrice / strikeInterval) * strikeInterval;
      
      const rand = (min: number, max: number) => Math.random() * (max - min) + min;
      const rows: OptionsChainRow[] = Array.from({ length: 25 }, (_, i) => {
        const k = nearestStrike + (i - 12) * strikeInterval;
        const spread = rand(0.005, 0.02);
        const center = Math.max(0.01, 0.18 - Math.abs(k - spotPrice) * 0.4);
        return {
          strike: Number(k.toFixed(2)),
          callBid: Number((center - spread).toFixed(3)),
          callAsk: Number((center + spread).toFixed(3)),
          putBid: Number((center - spread).toFixed(3)),
          putAsk: Number((center + spread).toFixed(3)),
          callIv: Number((0.52 + Math.random() * 0.12).toFixed(3)),
          putIv: Number((0.55 + Math.random() * 0.12).toFixed(3)),
          openInterest: Math.round(50 + Math.random() * 500),
          volume: Math.round(5 + Math.random() * 150),
        };
      });
      return rows;
    }
  }
}


