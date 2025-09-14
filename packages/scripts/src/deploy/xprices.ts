// Reference prices for X assets (synthetics), 1e6 scale (USD * 1e6)
// Adjust as needed. These are just placeholders; keep them realistic for strike banding.

export const X_REF_PRICES_1E6: Record<string, number> = {
  // ========= Private companies (synthetic "reference share" in USD) =========
  // These are *synthetic* per-unit references (not actual secondary prices).
  // Pick round numbers that keep your strike grid readable and liquid.

  xOPENAI:     10_000_000,  // $10  — synthetic unit for OpenAI exposure
  xANTHROPIC:  10_000_000,  // $10
  xSPACEX:    100_000_000,  // $100
  xXAI:        10_000_000,  // $10
  xKRAKEN:     10_000_000,  // $10
  xANDURIL:    20_000_000,  // $20
  xCURSOR:      1_000_000,  // $1
  xSTRIPE:     50_000_000,  // $50
  xBREX:       10_000_000,  // $10
  xDISCORD:    10_000_000,  // $10
  xPOLYMARKET:  1_000_000,  // $1
  xKALSHI:      1_000_000,  // $1

  // ========= Gas synthetics (USD cost of reference/average gas price) =========
  // Naming: xgETH, xgPOL, etc. (keep tickers for gas futures the same)
  // Unit meaning: **USD per standard tx** on that chain (at typical/current conditions).
  // These “ref” values are sensible midpoints so your strike bands make sense.
  // You’ll still compute live marks from your EMA indexer; these are just centers.

  xgETH:   2_000_000,   // $2.00   — L1 ETH simple transfer (21k gas; ~15–30 gwei, ETH~$3k)
  xgPOL:     10_000,    // $0.01   — Polygon PoS
  xgNEAR:     5_000,    // $0.005  — NEAR simple transfer
  xgSOL:      1_000,    // $0.001  — Solana simple transfer
  xgARB:     50_000,    // $0.05   — Arbitrum
  xgBASE:    30_000,    // $0.03   — Base
  xgAVAX:    50_000,    // $0.05   — Avalanche C-Chain
  xgBNB:     30_000,    // $0.03   — BNB Chain
  xgOP:      30_000,    // $0.03   — Optimism
};

export type XPolicy = {
  bandLow?: number;   // fraction of ref price, default 0.5
  bandHigh?: number;  // fraction of ref price, default 2.0
  stepAbs?: number;   // absolute USD step
  stepPct?: number;   // fraction of ref price
  cadence?: 'daily' | 'weekly' | 'biweekly' | 'monthly'; // default weekly
  years?: number;     // default 1
};

export const X_POLICIES: Record<string, XPolicy> = {
  // ======== Private companies ========
  xOPENAI:     { bandLow: 0.5, bandHigh: 2.0, stepPct: 0.10, cadence: 'monthly', years: 1 },
  xANTHROPIC:  { bandLow: 0.5, bandHigh: 2.0, stepPct: 0.10, cadence: 'monthly', years: 1 },
  xSPACEX:     { bandLow: 0.5, bandHigh: 2.0, stepPct: 0.10, cadence: 'monthly', years: 1 },
  xXAI:        { bandLow: 0.5, bandHigh: 2.0, stepPct: 0.10, cadence: 'monthly', years: 1 },
  xKRAKEN:     { bandLow: 0.5, bandHigh: 2.0, stepPct: 0.10, cadence: 'monthly', years: 1 },
  xANDURIL:    { bandLow: 0.5, bandHigh: 2.0, stepPct: 0.10, cadence: 'monthly', years: 1 },
  xCURSOR:     { bandLow: 0.5, bandHigh: 2.5, stepPct: 0.15, cadence: 'monthly', years: 1 }, // allow more boom/bust
  xSTRIPE:     { bandLow: 0.6, bandHigh: 2.0, stepPct: 0.08, cadence: 'monthly', years: 1 },
  xBREX:       { bandLow: 0.5, bandHigh: 2.0, stepPct: 0.10, cadence: 'monthly', years: 1 },
  xDISCORD:    { bandLow: 0.5, bandHigh: 2.0, stepPct: 0.10, cadence: 'monthly', years: 1 },
  xPOLYMARKET: { bandLow: 0.4, bandHigh: 3.0, stepPct: 0.20, cadence: 'monthly', years: 1 }, // higher vol
  xKALSHI:     { bandLow: 0.4, bandHigh: 3.0, stepPct: 0.20, cadence: 'monthly', years: 1 },

  // ======== Gas synthetics (USD per simple native transfer) ========
  // Steps chosen so you get ~20–40 strikes across the band; tweak per taste.
  xgETH:   { bandLow: 0.5, bandHigh: 2.5, stepAbs: 0.05, cadence: 'weekly', years: 1 },    // $2 ref → strikes $1–$5 by $0.05
  xgPOL:   { bandLow: 0.5, bandHigh: 2.5, stepAbs: 0.0025, cadence: 'weekly', years: 1 },  // $0.01 → $0.005–$0.025 by $0.0025
  xgNEAR:  { bandLow: 0.5, bandHigh: 2.5, stepAbs: 0.0025, cadence: 'weekly', years: 1 },  // $0.005 → $0.0025–$0.0125
  xgSOL:   { bandLow: 0.5, bandHigh: 3.0, stepAbs: 0.0005, cadence: 'weekly', years: 1 },  // $0.001 → $0.0005–$0.003
  xgARB:   { bandLow: 0.5, bandHigh: 2.5, stepAbs: 0.01, cadence: 'weekly', years: 1 },    // $0.05 → $0.025–$0.125
  xgBASE:  { bandLow: 0.5, bandHigh: 2.5, stepAbs: 0.01, cadence: 'weekly', years: 1 },    // $0.03 → $0.015–$0.075
  xgAVAX:  { bandLow: 0.5, bandHigh: 2.5, stepAbs: 0.01, cadence: 'weekly', years: 1 },    // $0.05 → ...
  xgBNB:   { bandLow: 0.5, bandHigh: 2.5, stepAbs: 0.01, cadence: 'weekly', years: 1 },    // $0.03 → ...
  xgOP:    { bandLow: 0.5, bandHigh: 2.5, stepAbs: 0.01, cadence: 'weekly', years: 1 },
};


