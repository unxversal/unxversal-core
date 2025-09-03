import { db, type EventRow } from '../../lib/storage';

export type SeriesCreated = { key: string; expiry_ms: number; strike_1e6: number; is_call: boolean };
export type SeriesCreatedV2 = { key: string; expiry_ms: number; strike_1e6: number; is_call: boolean; symbol_bytes: string; tick_size: number; lot_size: number; min_size: number };
export type OrderPlaced = { key: string; order_id: string; maker: string; price: number; quantity: number; is_bid: boolean; expire_ts: number };
export type OrderCanceled = { key: string; order_id: string; maker: string; quantity: number };
export type Matched = { key: string; taker: string; total_units: number; total_premium_quote: number };
export type Exercised = { key: string; exerciser: string; amount: number; spot_1e6: number };
export type OrderFilled = { key: string; maker_order_id: string; maker: string; taker: string; price: number; base_qty: number; premium_quote: number; maker_remaining_qty: number; timestamp_ms: number };
export type OrderExpired = { key: string; order_id: string; maker: string; timestamp_ms: number };
export type CollateralLocked = { key: string; writer: string; is_call: boolean; amount_base: number; amount_quote: number; timestamp_ms: number };
export type CollateralUnlocked = { key: string; writer: string; is_call: boolean; amount_base: number; amount_quote: number; reason: number; timestamp_ms: number };
export type OptionPositionUpdated = { key: string; owner: string; position_id: string; increase: boolean; delta_units: number; new_amount: number; timestamp_ms: number };
export type WriterClaimed = { key: string; writer: string; amount_base: number; amount_quote: number; timestamp_ms: number };

function et(pkg: string, name: string) { return `${pkg}::options::${name}`; }

async function recent<T>(typeName: string, limit: number): Promise<T[]> {
  const rows = await db.events.where('type').equals(typeName).toArray();
  rows.sort((a, b) => (b.tsMs ?? 0) - (a.tsMs ?? 0));
  const out: T[] = [];
  for (const r of rows.slice(0, limit)) {
    if (r.parsedJson) out.push(r.parsedJson as T);
  }
  return out;
}

export const recentSeries = (pkg: string, limit = 100) => recent<SeriesCreated>(et(pkg, 'SeriesCreated'), limit);
export const recentSeriesV2 = (pkg: string, limit = 100) => recent<SeriesCreatedV2>(et(pkg, 'SeriesCreatedV2'), limit);
export const recentPlacements = (pkg: string, limit = 200) => recent<OrderPlaced>(et(pkg, 'OrderPlaced'), limit);
export const recentCancels = (pkg: string, limit = 200) => recent<OrderCanceled>(et(pkg, 'OrderCanceled'), limit);
export const recentMatches = (pkg: string, limit = 200) => recent<Matched>(et(pkg, 'Matched'), limit);
export const recentExercises = (pkg: string, limit = 200) => recent<Exercised>(et(pkg, 'Exercised'), limit);
export const recentFills = (pkg: string, limit = 500) => recent<OrderFilled>(et(pkg, 'OrderFilled'), limit);
export const recentExpirations = (pkg: string, limit = 200) => recent<OrderExpired>(et(pkg, 'OrderExpired'), limit);
export const recentCollateralLocks = (pkg: string, limit = 200) => recent<CollateralLocked>(et(pkg, 'CollateralLocked'), limit);
export const recentCollateralUnlocks = (pkg: string, limit = 200) => recent<CollateralUnlocked>(et(pkg, 'CollateralUnlocked'), limit);
export const recentPositionUpdates = (pkg: string, limit = 200) => recent<OptionPositionUpdated>(et(pkg, 'OptionPositionUpdated'), limit);
export const recentWriterClaims = (pkg: string, limit = 200) => recent<WriterClaimed>(et(pkg, 'WriterClaimed'), limit);


