// Reference prices for X assets (synthetics), 1e6 scale (USD * 1e6)
// Adjust as needed. These are just placeholders; keep them realistic for strike banding.

export const X_REF_PRICES_1E6: Record<string, number> = {
  // ---------- Private companies ----------
  // Formula: Valuation ($B) ÷ 0.75, expressed in USD × 1e6

  // OpenAI ~ $500B → 500 / 0.75 = 666.7 → $667
  xOPENAI:     667_000_000,

  // Anthropic ~ $183B → 183 / 0.75 = 244
  xANTHROPIC:  244_000_000,

  // SpaceX ~ $380B → 380 / 0.75 = 507
  xSPACEX:     507_000_000,

  // xAI ~ $190B → 190 / 0.75 = 253
  xXAI:        253_000_000,

  // Kraken ~ $15B → 15 / 0.75 = 20
  xKRAKEN:      20_000_000,

  // Anduril ~ $30.5B → 30.5 / 0.75 ≈ 41
  xANDURIL:     41_000_000,

  // Cursor ~ $9.9B → 9.9 / 0.75 ≈ 13
  xCURSOR:      13_000_000,

  // Stripe ~ $91.5B → 91.5 / 0.75 = 122
  xSTRIPE:     122_000_000,

  // Brex ~ $12.3B → 12.3 / 0.75 ≈ 16
  xBREX:        16_000_000,

  // Discord ~ $15B → 15 / 0.75 = 20
  xDISCORD:     20_000_000,

  // Polymarket ~ $9B → 9 / 0.75 = 12
  xPOLYMARKET:  12_000_000,

  // Kalshi ~ $2B → 2 / 0.75 ≈ 2.7
  xKALSHI:       3_000_000,

  // ---------- Gas synthetics (unchanged) ----------
  xGASUSD_ETH:   450_000,   // $0.45
  xGASUSD_POL:     5_300,   // $0.0053
  xGASUSD_NEAR:    1_000,   // $0.0010
  xGASUSD_SOL:     6_300,   // $0.0063
  xGASUSD_ARB:    12_300,   // $0.0123
  xGASUSD_BASE:   18_500,   // $0.0185
  xGASUSD_AVAX:   23_500,   // $0.0235
  xGASUSD_BNB:    25_000,   // $0.0250
  xGASUSD_OP:      2_500,   // $0.0025
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


