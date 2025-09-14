import { useEffect, useMemo, useRef, useState } from 'react';
import { subscribeSymbols, getLatestPrice } from '../../lib/switchboard';

export type UsePythPriceResult = {
  price: number | null;
  change24h: number | null; // percent
};

function mapPairToPythSymbol(appPair: string): string | null {
  // Map BASE/QUOTE to Pyth symbol. If QUOTE is USDC/USD/WUSDC, prefer BASE/USD.
  const [base, quote] = appPair.split('/');
  if (!base || !quote) return null;
  const q = quote.toUpperCase();
  if (q === 'USDC' || q === 'USD' || q === 'WUSDC') return `${base.toUpperCase()}/USD`;
  return `${base.toUpperCase()}/${q}`;
}

export function usePythPrice(appPair: string): UsePythPriceResult {
  const pythSymbol = useMemo(() => mapPairToPythSymbol(appPair), [appPair]);
  const [price, setPrice] = useState<number | null>(null);
  const [change24h, setChange24h] = useState<number | null>(null);
  const historyRef = useRef<Array<{ ts: number; price: number }>>([]);

  useEffect(() => {
    let mounted = true;
    historyRef.current = [];
    setPrice(null); setChange24h(null);

    (async () => {
      if (!pythSymbol) return;
      try { await subscribeSymbols([pythSymbol]); } catch {}
      const tick = () => {
        const p = getLatestPrice(pythSymbol);
        const now = Date.now();
        if (p !== null && p !== undefined) {
          if (!mounted) return;
          setPrice(p);
          // push and prune 24h window
          historyRef.current.push({ ts: now, price: p });
          const cutoff = now - 24 * 3600 * 1000;
          while (historyRef.current.length > 0 && historyRef.current[0].ts < cutoff) {
            historyRef.current.shift();
          }
          const first = historyRef.current[0];
          if (first) {
            const ch = first.price === 0 ? 0 : ((p - first.price) / first.price) * 100;
            setChange24h(ch);
          }
        }
      };
      const id = setInterval(tick, 500);
      tick();
      return () => { clearInterval(id); };
    })();

    return () => { mounted = false; };
  }, [pythSymbol]);

  return { price, change24h };
}
