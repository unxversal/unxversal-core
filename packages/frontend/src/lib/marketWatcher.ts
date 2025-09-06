import { buildDeepbookPublicIndexer } from './indexer';
import { loadSettings } from './settings.config';

// Lightweight watcher that periodically warms candles/trades and orderbooks
export class MarketWatcher {
  private interval: any = null;
  private pools: string[] = [];
  private baseUrl: string;

  constructor(baseUrl: string, pools: string[]) {
    this.baseUrl = baseUrl;
    this.pools = pools;
  }

  start(periodMs = 4000): void {
    if (this.interval) return;
    const db = buildDeepbookPublicIndexer(this.baseUrl);
    const run = async () => {
      const batch = [...this.pools];
      await Promise.all(batch.map(async (p) => {
        try {
          await Promise.all([
            db.trades(p, { limit: 50 }).catch(() => undefined),
            db.orderbook(p, { level: 1, depth: 16 }).catch(() => undefined),
          ]);
        } catch {}
      }));
    };
    void run();
    this.interval = setInterval(run, Math.max(1000, periodMs));
  }

  stop(): void {
    if (this.interval) { clearInterval(this.interval); this.interval = null; }
  }
}

export function startDefaultMarketWatcher(): MarketWatcher | null {
  const s = loadSettings();
  if (!s.markets.autostartOnConnect || s.markets.watchlist.length === 0) return null;
  const watcher = new MarketWatcher(s.dex.deepbookIndexerUrl, s.markets.watchlist);
  watcher.start(5000);
  return watcher;
}


