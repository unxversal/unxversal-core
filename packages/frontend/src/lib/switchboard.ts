// Pyth price feeds using Hermes REST API (browser-compatible)
// Users configure symbols client-side; we poll for updates or use server-sent events

import { SWITCHBOARD_CONFIG } from './switchboard.config';

export type SurgeUpdate = { data: { symbol: string; price: number; source_ts_ms?: number } };

// Shared cache of latest prices
let currentPrice: Record<string, { price: number; ts: number }> = {};
let eventSource: EventSource | null = null;
let pollingInterval: NodeJS.Timeout | null = null;

// Pyth price feed IDs mapping (from Pyth documentation)
const FEED_IDS: Record<string, string> = {
  'BTC/USD': '0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43',
  'ETH/USD': '0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace',
  'SOL/USD': '0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d',
  'SUI/USD': '0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744'
};

// Note: Pyth doesn't require API keys, but keeping these for future extensibility
// function getStoredApiKey(): string | null {
//   if (SWITCHBOARD_CONFIG.apiKey && SWITCHBOARD_CONFIG.apiKey.trim().length > 0) return SWITCHBOARD_CONFIG.apiKey;
//   return localStorage.getItem('SURGE_API_KEY');
// }

// function setStoredApiKey(apiKey: string): void {
//   localStorage.setItem('SURGE_API_KEY', apiKey);
// }

function getStoredSymbols(): string[] {
  const raw = localStorage.getItem('SURGE_SYMBOLS') ?? SWITCHBOARD_CONFIG.symbols.join(',');
  if (!raw || !raw.trim()) return ['SUI/USD'];
  return raw.split(',').map((s) => s.trim()).filter(Boolean);
}

function setStoredSymbols(symbols: string[]): void {
  localStorage.setItem('SURGE_SYMBOLS', symbols.join(','));
}

export function configureSurge({ symbols }: { symbols: string[] }): void {
  // Note: Pyth doesn't require API keys
  setStoredSymbols(symbols);
}

// Fetch latest prices via REST API
async function fetchLatestPrices(symbols: string[]): Promise<void> {
  const feedIds = symbols
    .map(symbol => FEED_IDS[symbol])
    .filter(Boolean);
  
  if (feedIds.length === 0) return;
  
  try {
    const params = new URLSearchParams();
    feedIds.forEach(id => params.append('ids[]', id));
    
    const response = await fetch(`https://hermes.pyth.network/v2/updates/price/latest?${params}`);
    const data = await response.json();
    
    if (data.parsed) {
      data.parsed.forEach((priceData: any) => {
        // Find symbol for this feed ID
        const symbol = Object.keys(FEED_IDS).find(key => FEED_IDS[key] === priceData.id);
        if (symbol) {
          const price = parseFloat(priceData.price.price) / Math.pow(10, Math.abs(priceData.price.expo));
          applyUpdate({
            data: {
              symbol,
              price,
              source_ts_ms: priceData.price.publish_time * 1000
            }
          });
        }
      });
    }
  } catch (error) {
    console.error('Failed to fetch prices:', error);
  }
}

// Start streaming via Server-Sent Events
async function startStreaming(symbols: string[]): Promise<void> {
  if (eventSource) {
    eventSource.close();
  }

  const feedIds = symbols
    .map(symbol => FEED_IDS[symbol])
    .filter(Boolean);
  
  if (feedIds.length === 0) return;

  const params = new URLSearchParams();
  feedIds.forEach(id => params.append('ids[]', id));
  
  try {
    eventSource = new EventSource(`https://hermes.pyth.network/v2/updates/price/stream?${params}`);
    
    eventSource.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data);
        if (data.parsed) {
          data.parsed.forEach((priceData: any) => {
            const symbol = Object.keys(FEED_IDS).find(key => FEED_IDS[key] === priceData.id);
            if (symbol) {
              const price = parseFloat(priceData.price.price) / Math.pow(10, Math.abs(priceData.price.expo));
              applyUpdate({
                data: {
                  symbol,
                  price,
                  source_ts_ms: priceData.price.publish_time * 1000
                }
              });
            }
          });
        }
      } catch (error) {
        console.error('Failed to parse price update:', error);
      }
    };

    eventSource.onerror = (error) => {
      console.error('EventSource error:', error);
      // Fallback to polling on stream error
      startPolling(symbols);
    };
  } catch (error) {
    console.error('Failed to start streaming:', error);
    // Fallback to polling
    startPolling(symbols);
  }
}

// Fallback polling method
function startPolling(symbols: string[]): void {
  if (pollingInterval) {
    clearInterval(pollingInterval);
  }
  
  // Poll every 5 seconds
  pollingInterval = setInterval(() => {
    fetchLatestPrices(symbols);
  }, 5000);
  
  // Fetch immediately
  fetchLatestPrices(symbols);
}

export async function initSurgeFromSettings(autoStart: boolean = false): Promise<void> {
  if (!autoStart) return;
  
  const symbols = getStoredSymbols();
  if (symbols.length === 0) return;
  
  // Try streaming first, fall back to polling
  await startStreaming(symbols);
}

export async function subscribeSymbols(symbols: string[]): Promise<void> {
  setStoredSymbols(symbols);
  await startStreaming(symbols);
}

export async function startPriceFeeds(): Promise<void> {
  const symbols = getStoredSymbols();
  if (symbols.length === 0) return;
  
  // Try streaming first, fall back to polling
  await startStreaming(symbols);
}

export function getLatestPrice(symbol: string): number | null {
  const r = currentPrice[symbol];
  return r ? r.price : null;
}

export function getLatestTs(symbol: string): number | null {
  const r = currentPrice[symbol];
  return r ? r.ts : null;
}

export function applyUpdate(u: SurgeUpdate): void {
  currentPrice[u.data.symbol] = { price: u.data.price, ts: u.data.source_ts_ms ?? Date.now() };
}

export function cleanup(): void {
  if (eventSource) {
    eventSource.close();
    eventSource = null;
  }
  if (pollingInterval) {
    clearInterval(pollingInterval);
    pollingInterval = null;
  }
}
