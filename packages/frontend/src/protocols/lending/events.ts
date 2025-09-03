import { db, type EventRow } from '../../lib/storage';

export type DepositEvent = { who: string; amount: number; shares: string; timestamp_ms: number };
export type WithdrawEvent = { who: string; amount: number; shares: string; timestamp_ms: number };
export type BorrowEvent = { who: string; amount: number; new_principal: string; timestamp_ms: number };
export type RepayEvent = { who: string; amount: number; remaining_principal: string; timestamp_ms: number };
export type LiquidatedEvent = { borrower: string; liquidator: string; repay_amount: number; shares_seized: string; bonus_bps: number; timestamp_ms: number };
export type AccruedEvent = { interest_index: string; dt_ms: number; new_reserves: number; timestamp_ms: number };
export type ParamsUpdatedEvent = { reserve_bps: number; collat_bps: number; liq_bonus_bps: number; timestamp_ms: number };

function et(pkg: string, name: string) { return `${pkg}::lending::${name}`; }

async function recent<T>(typeName: string, limit: number): Promise<T[]> {
  const rows = await db.events.where('type').equals(typeName).toArray();
  rows.sort((a, b) => (b.tsMs ?? 0) - (a.tsMs ?? 0));
  const out: T[] = [];
  for (const r of rows.slice(0, limit)) {
    if (r.parsedJson) out.push(r.parsedJson as T);
  }
  return out;
}

export const recentDeposits = (pkg: string, limit = 100) => recent<DepositEvent>(et(pkg, 'Deposit'), limit);
export const recentWithdraws = (pkg: string, limit = 100) => recent<WithdrawEvent>(et(pkg, 'Withdraw'), limit);
export const recentBorrows = (pkg: string, limit = 100) => recent<BorrowEvent>(et(pkg, 'Borrow'), limit);
export const recentRepays = (pkg: string, limit = 100) => recent<RepayEvent>(et(pkg, 'Repay'), limit);
export const recentLiquidations = (pkg: string, limit = 100) => recent<LiquidatedEvent>(et(pkg, 'Liquidated'), limit);
export const recentAccruals = (pkg: string, limit = 200) => recent<AccruedEvent>(et(pkg, 'Accrued'), limit);
export const recentParamUpdates = (pkg: string, limit = 50) => recent<ParamsUpdatedEvent>(et(pkg, 'ParamsUpdated'), limit);


