/**
 * Utilities to generate Options series for deploy config.
 * Produces arrays of { expiryMs, strike1e6, isCall, symbol } for a chosen cadence
 * (daily/weekly/biweekly/monthly) across a number of years, a strike range, and a strike step.
 */

export type Series = {
  expiryMs: number;
  strike1e6: number;
  isCall: boolean;
  symbol: string;
};

export type Cadence = 'daily' | 'weekly' | 'biweekly' | 'monthly';

export type GenerateSeriesParams = {
  symbol: string;
  cadence: Cadence;
  years: number; // number of years forward from start (e.g., 3)
  strikeMin: number; // human units (e.g., 1.25)
  strikeMax: number; // human units
  strikeStep: number; // human units between strikes (e.g., 0.25)
  startAtMs?: number; // default: Date.now()
  // Expiry time of day (UTC). Defaults to 00:00 UTC.
  expiryHourUtc?: number;
  expiryMinuteUtc?: number;
  // Weekly anchor day (0=Sun..6=Sat). Defaults to Friday (5).
  weeklyOn?: number;
  // Monthly rule: numeric day-of-month (1..31, clamped to last day) or 'eom' (end of month). Defaults to 'eom'.
  monthlyDay?: number | 'eom';
  // Optional hard cap to avoid exploding combinations when generating large grids
  maxSeries?: number;
};

/** Generate a grid of strikes in 1e6 scale from human-unit inputs. */
export function generateStrikeGrid1e6(min: number, max: number, step: number): number[] {
  if (!(step > 0)) throw new Error('strikeStep must be > 0');
  if (!(max >= min)) throw new Error('strikeMax must be >= strikeMin');
  const out: number[] = [];
  const scale = 1_000_000;
  // Use integer math in 1e6 space to avoid FP drift
  const min6 = Math.round(min * scale);
  const max6 = Math.round(max * scale);
  const step6 = Math.round(step * scale);
  for (let s = min6; s <= max6; s += step6) out.push(s);
  return out;
}

/** Generate expiries (epoch ms, UTC) by cadence from a start time up to `years` forward. */
export function generateExpiriesMs(params: {
  cadence: Cadence;
  years: number;
  startAtMs?: number;
  expiryHourUtc?: number;
  expiryMinuteUtc?: number;
  weeklyOn?: number;
  monthlyDay?: number | 'eom';
}): number[] {
  const {
    cadence,
    years,
    startAtMs = Date.now(),
    expiryHourUtc = 0,
    expiryMinuteUtc = 0,
    weeklyOn = 5,
    monthlyDay = 'eom',
  } = params;
  if (!(years > 0)) throw new Error('years must be > 0');

  const start = new Date(startAtMs);
  const end = new Date(startAtMs);
  end.setUTCFullYear(end.getUTCFullYear() + years);

  const expiries: number[] = [];

  const setTime = (d: Date) => {
    d.setUTCHours(expiryHourUtc, expiryMinuteUtc, 0, 0);
  };

  const nextDaily = (from: Date) => {
    const d = new Date(from.getTime());
    d.setUTCDate(d.getUTCDate() + 1);
    setTime(d);
    return d;
  };

  const nextWeeklyLike = (from: Date, everyDays: number, anchorDow: number) => {
    const d = new Date(from.getTime());
    const dow = d.getUTCDay();
    let delta = (anchorDow - dow + 7) % 7;
    if (delta === 0) delta = 7; // always strictly in the future
    d.setUTCDate(d.getUTCDate() + delta);
    setTime(d);
    // For biweekly, we will step by 14 days during iteration; here we just find the first anchor
    return d;
  };

  const nextMonthly = (from: Date, day: number | 'eom') => {
    const d = new Date(from.getTime());
    // Move to next month
    d.setUTCMonth(d.getUTCMonth() + 1, 1); // set to the 1st of next month
    if (day === 'eom') {
      // set date to last day of month
      d.setUTCMonth(d.getUTCMonth() + 1, 0); // day 0 of following month => last day of target month
    } else {
      const target = Math.max(1, Math.min(day, daysInMonthUtc(d.getUTCFullYear(), d.getUTCMonth())));
      d.setUTCDate(target);
    }
    setTime(d);
    return d;
  };

  const firstAfter = () => {
    // Choose first expiry strictly after start
    if (cadence === 'daily') {
      return nextDaily(start);
    }
    if (cadence === 'weekly') {
      return nextWeeklyLike(start, 7, weeklyOn);
    }
    if (cadence === 'biweekly') {
      return nextWeeklyLike(start, 14, weeklyOn);
    }
    if (cadence === 'monthly') {
      // Build candidate for current month at configured rule; if not strictly after start, advance a month
      const c = new Date(start.getTime());
      // Candidate in current month
      const cur = new Date(Date.UTC(c.getUTCFullYear(), c.getUTCMonth(), 1, 0, 0, 0, 0));
      if (monthlyDay === 'eom') {
        cur.setUTCMonth(cur.getUTCMonth() + 1, 0);
      } else {
        const target = Math.max(1, Math.min(monthlyDay, daysInMonthUtc(cur.getUTCFullYear(), cur.getUTCMonth())));
        cur.setUTCDate(target);
      }
      setTime(cur);
      if (cur.getTime() > start.getTime()) return cur;
      return nextMonthly(start, monthlyDay);
    }
    throw new Error('Unsupported cadence');
  };

  let cur = firstAfter();
  while (cur <= end) {
    expiries.push(cur.getTime());
    if (cadence === 'daily') {
      cur = nextDaily(cur);
    } else if (cadence === 'weekly') {
      const n = new Date(cur.getTime());
      n.setUTCDate(n.getUTCDate() + 7);
      setTime(n);
      cur = n;
    } else if (cadence === 'biweekly') {
      const n = new Date(cur.getTime());
      n.setUTCDate(n.getUTCDate() + 14);
      setTime(n);
      cur = n;
    } else if (cadence === 'monthly') {
      cur = nextMonthly(cur, monthlyDay);
    }
  }

  return expiries;
}

export function generateOptionSeries(params: GenerateSeriesParams): Series[] {
  const {
    symbol,
    cadence,
    years,
    strikeMin,
    strikeMax,
    strikeStep,
    startAtMs,
    expiryHourUtc,
    expiryMinuteUtc,
    weeklyOn,
    monthlyDay,
    maxSeries,
  } = params;

  const expiries = generateExpiriesMs({
    cadence,
    years,
    startAtMs,
    expiryHourUtc,
    expiryMinuteUtc,
    weeklyOn,
    monthlyDay,
  });
  const strikes = generateStrikeGrid1e6(strikeMin, strikeMax, strikeStep);

  const out: Series[] = [];
  for (const e of expiries) {
    for (const s of strikes) {
      out.push({ expiryMs: e, strike1e6: s, isCall: true, symbol });
      out.push({ expiryMs: e, strike1e6: s, isCall: false, symbol });
      if (maxSeries && out.length >= maxSeries) return out.slice(0, maxSeries);
    }
  }
  return out;
}

function daysInMonthUtc(year: number, monthIndex0: number): number {
  return new Date(Date.UTC(year, monthIndex0 + 1, 0)).getUTCDate();
}

// ------------------------------
// 1) Hardcoded spots (1e6 scale)
// ------------------------------
export async function getSpot1e6(symbol: string): Promise<number> {
  const spots: Record<string, number> = {
    'SUI/USDC':   Math.round(3.47 * 1e6),
    'DEEP/USDC':  Math.round(0.136 * 1e6),
    'ETH/USDC':   Math.round(4301.09 * 1e6),
    'BTC/USDC':   Math.round(111_611 * 1e6),
    'SOL/USDC':   Math.round(214.85 * 1e6),
    'GLMR/USDC':  Math.round(0.07027 * 1e6),
    'MATIC/USDC': Math.round(0.2709 * 1e6),
    'APT/USDC':   Math.round(4.42 * 1e6),
    'CELO/USDC':  Math.round(0.31115 * 1e6),
    'IKA/USDC':   Math.round(0.03574 * 1e6),
    'NS/USDC':    Math.round(0.1249 * 1e6),
    'SEND/USDC':  Math.round(0.5343 * 1e6),
    'WAL/USDC':   Math.round(0.4229 * 1e6),
    'USDT/USDC':  Math.round(0.99992 * 1e6),
    'WBNB/USDC':  Math.round(875.10 * 1e6),
  };
  if (!(symbol in spots)) throw new Error(`No hardcoded spot for symbol: ${symbol}`);
  return spots[symbol];
}

// --------------------------------------------------
// 2) Policy (bands & steps) -> GenerateSeriesParams
//    NOTE: strikeMin/Max/Step are in human USD units
// --------------------------------------------------

export type Policy = {
  bandLow: number;     // fraction of spot (e.g., 0.5 => 50% of spot)
  bandHigh: number;    // fraction of spot
  stepAbs?: number;    // absolute USD step (e.g., 25 => $25)
  stepPct?: number;    // % of spot (e.g., 0.02 => 2%)
  cadence?: Cadence;   // default weekly unless overridden
  years?: number;      // default 2 unless overridden
};

const DEFAULTS = {
  cadence: 'weekly' as Cadence,
  years: 2,
  expiryHourUtc: 0,
  expiryMinuteUtc: 0,
  weeklyOn: 5 as 0|1|2|3|4|5|6, // Friday
  monthlyDay: 'eom' as number | 'eom',
};



// fallback for any symbol not explicitly listed above
const FALLBACK: Policy = { bandLow: 0.5, bandHigh: 2.0, stepPct: 0.02, cadence: 'weekly', years: 2 };

// ------------------------------
// 3) Builder for all feed symbols
// ------------------------------
export async function buildAllOptionSeriesForFeeds(
  symbols: string[],
  policies: Record<string, Policy>,
  opts?: { startAtMs?: number; maxSeries?: number }
): Promise<Record<string, Series[]>> {
  const out: Record<string, Series[]> = {};
  for (const symbol of symbols) {
    const spot1e6 = await getSpot1e6(symbol);
    const spot = spot1e6 / 1_000_000; // convert to human units for your API

    const policy = policies[symbol] ?? FALLBACK;

    const strikeMin = Math.max(0.000001, spot * policy.bandLow);
    const strikeMax = spot * policy.bandHigh;

    // choose step
    const strikeStep =
      policy.stepAbs !== undefined
        ? policy.stepAbs
        : Math.max(0.005, (policy.stepPct ?? 0.02) * spot); // floor at half-cent for cheap tokens

    // assemble params USING YOUR TYPE NAMES
    const params = {
      symbol,
      cadence: (policy.cadence ?? DEFAULTS.cadence),
      years: (policy.years ?? DEFAULTS.years),
      strikeMin,
      strikeMax,
      strikeStep,
      startAtMs: opts?.startAtMs,
      expiryHourUtc: DEFAULTS.expiryHourUtc,
      expiryMinuteUtc: DEFAULTS.expiryMinuteUtc,
      weeklyOn: DEFAULTS.weeklyOn,
      monthlyDay: DEFAULTS.monthlyDay,
      maxSeries: opts?.maxSeries,
    } as const;

    out[symbol] = generateOptionSeries(params);
  }
  return out;
}

// ------------------------------
// Example usage
// ------------------------------
// import { deployConfig } from './config';
// const symbols = (deployConfig.oracleFeeds ?? []).map(f => f.symbol);
// const seriesBySymbol = await buildAllOptionSeriesForFeeds(symbols);
// // Then map into deployConfig.options as needed:
//
/*
deployConfig.options = symbols.map((symbol) => ({
  base: '<base typetag for ' + symbol + '>',
  quote: '<quote typetag for ' + symbol + '>',
  tickSize: Math.round(0.001 * 1e6), // if your on-chain tick is 0.001 USD, stored at 1e6
  lotSize: 1,
  minSize: 1,
  series: seriesBySymbol[symbol],
}));
*/
