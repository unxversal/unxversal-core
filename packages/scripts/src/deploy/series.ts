// Utility to generate options series specs for deploy config
// Produces entries compatible with DeployConfig.options[*].series

import type { SuiTypeTag } from './config.js';

export type Interval = 'daily' | 'weekly' | 'biweekly' | 'monthly';

export type SeriesItem = {
  expiryMs: number;
  strike1e6: number;
  isCall: boolean;
  symbol: string;
};

export type GenerateSeriesParams = {
  symbol: string;
  years: number; // horizon in whole/partial years (e.g., 3 => ~3 years)
  interval: Interval;
  // Strike range (inclusive) in 1e6 price scale expected by Move (e.g., $100 => 100_000000)
  minStrike1e6: number;
  maxStrike1e6: number;
  stepStrike1e6: number;
  // Time controls (UTC). Defaults produce 00:00:00 UTC expiries on boundaries.
  startMs?: number; // default: Date.now()
  expiryHourUTC?: number; // 0..23, default 0
  // Scheduling alignment (optional)
  weeklyOn?: number; // 0..6 (Sun..Sat). Default: next occurrence of start's weekday
  monthlyOnDay?: number; // 1..31. Default: start's day-of-month; clamped to month length
  // Filters
  excludeWeekdays?: number[]; // e.g., [0, 6] to skip weekends for daily
  includeCalls?: boolean; // default true
  includePuts?: boolean; // default true
  maxSeries?: number; // optional safety cap
};

const DAY_MS = 86_400_000;
const YEAR_MS = 365.25 * DAY_MS; // approximate; good for horizon cutoff

export function generateOptionSeries(params: GenerateSeriesParams): SeriesItem[] {
  const {
    symbol,
    years,
    interval,
    minStrike1e6,
    maxStrike1e6,
    stepStrike1e6,
    startMs = Date.now(),
    expiryHourUTC = 0,
    weeklyOn,
    monthlyOnDay,
    excludeWeekdays = [],
    includeCalls = true,
    includePuts = true,
    maxSeries,
  } = params;

  if (!includeCalls && !includePuts) return [];
  if (years <= 0) return [];
  if (minStrike1e6 <= 0 || maxStrike1e6 <= 0 || stepStrike1e6 <= 0) return [];
  if (minStrike1e6 > maxStrike1e6) return [];

  // Build expiry schedule first
  const expiries = buildExpirySchedule({
    startMs,
    years,
    interval,
    expiryHourUTC,
    weeklyOn,
    monthlyOnDay,
    excludeWeekdays,
    maxSeries,
  });

  // Build strikes (inclusive range)
  const strikes: number[] = [];
  for (let s = minStrike1e6; s <= maxStrike1e6; s += stepStrike1e6) {
    strikes.push(s);
    // guard against accidental infinite loop on bad step
    if (strikes.length > 1_000_000) break;
  }
  if (strikes.length === 0) return [];

  // Cross product: each expiry × each strike × call/put
  const out: SeriesItem[] = [];
  for (const ex of expiries) {
    for (const s of strikes) {
      if (includeCalls) out.push({ expiryMs: ex, strike1e6: s, isCall: true, symbol });
      if (includePuts) out.push({ expiryMs: ex, strike1e6: s, isCall: false, symbol });
      if (maxSeries && out.length >= maxSeries) return out;
    }
  }
  return out;
}

function buildExpirySchedule(args: {
  startMs: number;
  years: number;
  interval: Interval;
  expiryHourUTC: number;
  weeklyOn?: number;
  monthlyOnDay?: number;
  excludeWeekdays: number[];
  maxSeries?: number;
}): number[] {
  const { startMs, years, interval, expiryHourUTC, weeklyOn, monthlyOnDay, excludeWeekdays, maxSeries } = args;
  const endMs = startMs + years * YEAR_MS;
  const expiries: number[] = [];

  // Normalize start to ms and create Date helper
  const start = new Date(startMs);

  switch (interval) {
    case 'daily': {
      // start from next day boundary (strictly after now)
      let d = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth(), start.getUTCDate(), expiryHourUTC, 0, 0, 0));
      if (d.getTime() <= startMs) d = new Date(d.getTime() + DAY_MS);
      while (d.getTime() <= endMs) {
        const dow = d.getUTCDay();
        if (!excludeWeekdays.includes(dow)) expiries.push(d.getTime());
        if (maxSeries && expiries.length >= maxSeries) break;
        d = new Date(d.getTime() + DAY_MS);
      }
      break;
    }
    case 'weekly':
    case 'biweekly': {
      const stepDays = interval === 'weekly' ? 7 : 14;
      const targetDow = clampDow(weeklyOn, start.getUTCDay());
      // Next target DOW strictly after start
      let d = nextDowAfter(start, targetDow, expiryHourUTC);
      while (d.getTime() <= endMs) {
        const dow = d.getUTCDay();
        if (!excludeWeekdays.includes(dow)) expiries.push(d.getTime());
        if (maxSeries && expiries.length >= maxSeries) break;
        d = new Date(d.getTime() + stepDays * DAY_MS);
      }
      break;
    }
    case 'monthly': {
      const day = clampMonthlyDay(monthlyOnDay, start.getUTCDate());
      let d = firstMonthlyAfter(start, day, expiryHourUTC);
      while (d.getTime() <= endMs) {
        const dow = d.getUTCDay();
        if (!excludeWeekdays.includes(dow)) expiries.push(d.getTime());
        if (maxSeries && expiries.length >= maxSeries) break;
        d = addMonthsUTC(d, 1, day, expiryHourUTC);
      }
      break;
    }
  }
  return expiries;
}

function clampDow(dowOpt: number | undefined, fallback: number): number {
  const v = typeof dowOpt === 'number' ? dowOpt : fallback;
  return ((v % 7) + 7) % 7; // normalize to 0..6
}

function clampMonthlyDay(dayOpt: number | undefined, fallback: number): number {
  const v = typeof dayOpt === 'number' ? dayOpt : fallback;
  return Math.min(31, Math.max(1, Math.floor(v)));
}

function nextDowAfter(start: Date, targetDow: number, hourUTC: number): Date {
  // Anchor at today's target hour
  const anchor = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth(), start.getUTCDate(), hourUTC, 0, 0, 0));
  const curDow = anchor.getUTCDay();
  let delta = (targetDow - curDow + 7) % 7;
  if (anchor.getTime() <= start.getTime()) delta = delta === 0 ? 7 : delta; // strictly after now
  else if (delta === 0) delta = 0; // already future today at same DOW
  const out = new Date(anchor.getTime() + delta * DAY_MS);
  if (out.getTime() <= start.getTime()) return new Date(out.getTime() + 7 * DAY_MS);
  return out;
}

function firstMonthlyAfter(start: Date, day: number, hourUTC: number): Date {
  // Candidate this month at specified day/hour
  const y = start.getUTCFullYear();
  const m = start.getUTCMonth();
  const dimThis = daysInMonthUTC(y, m);
  const dThis = Math.min(day, dimThis);
  let candidate = new Date(Date.UTC(y, m, dThis, hourUTC, 0, 0, 0));
  if (candidate.getTime() <= start.getTime()) {
    candidate = addMonthsUTC(candidate, 1, day, hourUTC);
  }
  return candidate;
}

function addMonthsUTC(base: Date, months: number, dayOfMonth: number, hourUTC: number): Date {
  const y = base.getUTCFullYear();
  const m = base.getUTCMonth();
  const targetM = m + months;
  const ny = y + Math.floor(targetM / 12);
  const nm = ((targetM % 12) + 12) % 12;
  const dim = daysInMonthUTC(ny, nm);
  const d = Math.min(dayOfMonth, dim);
  return new Date(Date.UTC(ny, nm, d, hourUTC, 0, 0, 0));
}

function daysInMonthUTC(year: number, monthZeroBased: number): number {
  // monthZeroBased: 0..11; trick: day 0 of next month is last day of current month
  return new Date(Date.UTC(year, monthZeroBased + 1, 0)).getUTCDate();
}

// Example usage (in deploy config):
// import { generateOptionSeries } from './series.js';
// const series = generateOptionSeries({
//   symbol: 'SUI/USDC',
//   years: 3,
//   interval: 'weekly',
//   minStrike1e6: 50_0000,  // $50.0000
//   maxStrike1e6: 200_0000, // $200.0000
//   stepStrike1e6: 5_0000,  // $5.0000 spacing
//   weeklyOn: 5,            // Friday
//   expiryHourUTC: 0,       // 00:00 UTC
//   excludeWeekdays: [],
// });

// ===== Futures helpers =====

export type FuturesMarketSpec = {
  symbol: string;
  collat: SuiTypeTag;       // Sui type tag for Collat
  contractSize: number;     // quote units per contract (price scale 1e6)
  initialMarginBps: number;
  maintenanceMarginBps: number;
  liquidationFeeBps: number;
  keeperIncentiveBps?: number;
  // orderbook
  tickSize: number;
  lotSize: number;
  minSize: number;
  // optional admin knobs
  closeOnly?: boolean;
  maxDeviationBps?: number;
  pnlFeeShareBps?: number;
  liqTargetBufferBps?: number;
  imbalanceParams?: { surchargeMaxBps: number; thresholdBps: number };
  // risk controls
  accountMaxNotional1e6?: string;
  marketMaxNotional1e6?: string;
  accountShareOfOiBps?: number;
  tierThresholds1e6?: number[];
  tierImBps?: number[];
};

export type GenerateFuturesParams = {
  baseSymbol: string;       // e.g. 'SUI/USDC'
  collat: SuiTypeTag;       // Sui type for Collat
  contractSize: number;
  initialMarginBps: number;
  maintenanceMarginBps: number;
  liquidationFeeBps: number;
  keeperIncentiveBps?: number;
  tickSize: number;
  lotSize: number;
  minSize: number;
  // schedule
  years: number;
  interval: Interval;       // weekly/biweekly/monthly typical
  expiryHourUTC?: number;   // default 0
  weeklyOn?: number;        // 0..6
  monthlyOnDay?: number;    // 1..31
  startMs?: number;         // default now
  // optional admin knobs
  closeOnly?: boolean;
  maxDeviationBps?: number;
  pnlFeeShareBps?: number;
  liqTargetBufferBps?: number;
  imbalanceParams?: { surchargeMaxBps: number; thresholdBps: number };
  // risk controls
  accountMaxNotional1e6?: string;
  marketMaxNotional1e6?: string;
  accountShareOfOiBps?: number;
  tierThresholds1e6?: number[];
  tierImBps?: number[];
  // max number of markets (safety cap)
  maxMarkets?: number;
};

export function generateFuturesMarkets(params: GenerateFuturesParams): Array<FuturesMarketSpec & { expiryMs: number }>{
  const {
    baseSymbol,
    collat,
    contractSize,
    initialMarginBps,
    maintenanceMarginBps,
    liquidationFeeBps,
    keeperIncentiveBps,
    tickSize,
    lotSize,
    minSize,
    years,
    interval,
    expiryHourUTC = 0,
    weeklyOn,
    monthlyOnDay,
    startMs = Date.now(),
    closeOnly,
    maxDeviationBps,
    pnlFeeShareBps,
    liqTargetBufferBps,
    imbalanceParams,
    accountMaxNotional1e6,
    marketMaxNotional1e6,
    accountShareOfOiBps,
    tierThresholds1e6,
    tierImBps,
    maxMarkets,
  } = params;

  const expiries = buildExpirySchedule({
    startMs,
    years,
    interval,
    expiryHourUTC,
    weeklyOn,
    monthlyOnDay,
    excludeWeekdays: [],
    maxSeries: maxMarkets,
  });

  return expiries.map((expiryMs) => ({
    symbol: baseSymbol,
    collat,
    contractSize,
    initialMarginBps,
    maintenanceMarginBps,
    liquidationFeeBps,
    keeperIncentiveBps,
    tickSize,
    lotSize,
    minSize,
    closeOnly,
    maxDeviationBps,
    pnlFeeShareBps,
    liqTargetBufferBps,
    imbalanceParams,
    accountMaxNotional1e6,
    marketMaxNotional1e6,
    accountShareOfOiBps,
    tierThresholds1e6,
    tierImBps,
    expiryMs,
  }));
}

// Example:
// const futs = generateFuturesMarkets({
//   baseSymbol: 'SUI/USDC', collat: '0x2::sui::SUI',
//   contractSize: 2_000_000_000_000, initialMarginBps: 500, maintenanceMarginBps: 300, liquidationFeeBps: 50,
//   tickSize: 10_000, lotSize: 2_000_000_000_000, minSize: 2_000_000_000_000,
//   years: 1, interval: 'monthly', monthlyOnDay: 1, expiryHourUTC: 0,
//   maxMarkets: 6,
// });


