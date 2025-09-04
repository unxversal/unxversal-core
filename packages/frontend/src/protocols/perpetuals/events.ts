import { db } from '../../lib/storage';

export type PerpInitialized = { market_id: string; symbol: string; contract_size: number; funding_interval_ms: number; initial_margin_bps: number; maintenance_margin_bps: number; liquidation_fee_bps: number };
export type CollateralDeposited = { market_id: string; who: string; amount: number; timestamp_ms: number };
export type CollateralWithdrawn = { market_id: string; who: string; amount: number; timestamp_ms: number };
export type PositionChanged = { market_id: string; who: string; is_long: boolean; qty_delta: number; exec_price_1e6: number; realized_gain: number; realized_loss: number; new_long: number; new_short: number; timestamp_ms: number };
export type FeeCharged = { market_id: string; who: string; notional_1e6: string | number; fee_paid: number; paid_in_unxv: boolean; timestamp_ms: number };
export type FundingIndexUpdated = { market_id: string; longs_pay: boolean; delta_1e6: number; cum_long_pay_1e6: string; cum_short_pay_1e6: string; timestamp_ms: number };
export type FundingSettled = { market_id: string; who: string; amount_paid: number; amount_credited: number; credit_left: number; timestamp_ms: number };
export type Liquidated = { market_id: string; who: string; qty_closed: number; exec_price_1e6: number; penalty_collat: number; timestamp_ms: number };

function et(pkg: string, name: string) { return `${pkg}::perpetuals::${name}`; }

async function recent<T>(typeName: string, limit: number): Promise<T[]> {
  const rows = await db.events.where('type').equals(typeName).toArray();
  rows.sort((a, b) => (b.tsMs ?? 0) - (a.tsMs ?? 0));
  return rows.slice(0, limit).map((r) => r.parsedJson as T).filter(Boolean) as T[];
}

export const recentMarkets = (pkg: string, limit = 50) => recent<PerpInitialized>(et(pkg, 'PerpInitialized'), limit);
export const recentDeposits = (pkg: string, limit = 200) => recent<CollateralDeposited>(et(pkg, 'CollateralDeposited'), limit);
export const recentWithdraws = (pkg: string, limit = 200) => recent<CollateralWithdrawn>(et(pkg, 'CollateralWithdrawn'), limit);
export const recentPositions = (pkg: string, limit = 500) => recent<PositionChanged>(et(pkg, 'PositionChanged'), limit);
export const recentFees = (pkg: string, limit = 500) => recent<FeeCharged>(et(pkg, 'FeeCharged'), limit);
export const recentFunding = (pkg: string, limit = 500) => recent<FundingIndexUpdated>(et(pkg, 'FundingIndexUpdated'), limit);
export const recentFundingSettlements = (pkg: string, limit = 500) => recent<FundingSettled>(et(pkg, 'FundingSettled'), limit);
export const recentLiquidations = (pkg: string, limit = 200) => recent<Liquidated>(et(pkg, 'Liquidated'), limit);


