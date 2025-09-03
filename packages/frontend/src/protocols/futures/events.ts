import { db } from '../../lib/storage';

export type MarketInitialized = { market_id: string; symbol: string; expiry_ms: number; contract_size: number; initial_margin_bps: number; maintenance_margin_bps: number; liquidation_fee_bps: number };
export type CollateralDeposited = { market_id: string; who: string; amount: number; timestamp_ms: number };
export type CollateralWithdrawn = { market_id: string; who: string; amount: number; timestamp_ms: number };
export type PositionChanged = { market_id: string; who: string; is_long: boolean; qty_delta: number; exec_price_1e6: number; realized_gain: number; realized_loss: number; new_long: number; new_short: number; timestamp_ms: number };
export type FeeCharged = { market_id: string; who: string; notional_units: number; fee_paid: number; paid_in_unxv: boolean; timestamp_ms: number };
export type Liquidated = { market_id: string; who: string; qty_closed: number; exec_price_1e6: number; penalty_collat: number; timestamp_ms: number };
export type Settled = { market_id: string; who: string; price_1e6: number; timestamp_ms: number };

function et(pkg: string, name: string) { return `${pkg}::futures::${name}`; }

async function recent<T>(typeName: string, limit: number): Promise<T[]> {
  const rows = await db.events.where('type').equals(typeName).toArray();
  rows.sort((a, b) => (b.tsMs ?? 0) - (a.tsMs ?? 0));
  return rows.slice(0, limit).map((r) => r.parsedJson as T).filter(Boolean) as T[];
}

export const recentMarkets = (pkg: string, limit = 50) => recent<MarketInitialized>(et(pkg, 'MarketInitialized'), limit);
export const recentDeposits = (pkg: string, limit = 200) => recent<CollateralDeposited>(et(pkg, 'CollateralDeposited'), limit);
export const recentWithdraws = (pkg: string, limit = 200) => recent<CollateralWithdrawn>(et(pkg, 'CollateralWithdrawn'), limit);
export const recentPositions = (pkg: string, limit = 500) => recent<PositionChanged>(et(pkg, 'PositionChanged'), limit);
export const recentFees = (pkg: string, limit = 500) => recent<FeeCharged>(et(pkg, 'FeeCharged'), limit);
export const recentLiquidations = (pkg: string, limit = 200) => recent<Liquidated>(et(pkg, 'Liquidated'), limit);
export const recentSettlements = (pkg: string, limit = 200) => recent<Settled>(et(pkg, 'Settled'), limit);


