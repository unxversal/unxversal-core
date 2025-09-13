// Reference prices for X assets (synthetics), 1e6 scale (USD * 1e6)
// Adjust as needed. These are just placeholders; keep them realistic for strike banding.

export const X_REF_PRICES_1E6: Record<string, number> = {
  // Private companies
  xOPENAI: 10_000_000,     // $10
  xANTHROPIC: 10_000_000,  // $10
  xSPACEX: 100_000_000,    // $100
  xXAI: 10_000_000,        // $10
  xKRAKEN: 10_000_000,
  xANDURIL: 20_000_000,
  xCURSOR: 1_000_000,      // $1
  xSTRIPE: 50_000_000,     // $50
  xBREX: 10_000_000,
  xDISCORD: 10_000_000,
  xPOLYMARKET: 1_000_000,
  xKALSHI: 1_000_000,

  // Gas synthetics
  xgETH: 2_000_000,   // $2 (arbitrary ref)
  xgPOL: 1_000_000,   // $1
  xgNEAR: 1_000_000,  // $1
  xgSOL: 2_000_000,   // $2
  xgARB: 1_000_000,
  xgBASE: 1_000_000,
  xgAVAX: 1_000_000,
  xgBNB: 2_000_000,
  xgOP: 1_000_000,
};

export type XPolicy = {
  bandLow?: number;   // fraction of ref price, default 0.5
  bandHigh?: number;  // fraction of ref price, default 2.0
  stepAbs?: number;   // absolute USD step
  stepPct?: number;   // fraction of ref price
  cadence?: 'daily' | 'weekly' | 'biweekly' | 'monthly'; // default weekly
  years?: number;     // default 1
};

export const X_POLICIES: Record<string, XPolicy> = {};


