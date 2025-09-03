import { db, type EventRow } from '../../lib/storage';

export type ProtocolFeeTakenEvent = {
  payer: string;
  base_fee_asset_unxv: boolean;
  amount: number;
  timestamp_ms: number;
};

export type PoolCreationFeePaidEvent = {
  payer: string;
  amount_unxv: number;
  timestamp_ms: number;
};

function eventType(pkg: string, name: string): string {
  return `${pkg}::dex::${name}`;
}

function mapParsedJson<T>(row: EventRow): T | null {
  const j = row.parsedJson;
  if (!j) return null;
  return j as T;
}

export async function getRecentProtocolFees(pkg: string, limit = 100): Promise<ProtocolFeeTakenEvent[]> {
  const t = eventType(pkg, 'ProtocolFeeTaken');
  const rows = await db.events.where('type').equals(t).toArray();
  rows.sort((a, b) => (b.tsMs ?? 0) - (a.tsMs ?? 0));
  return rows.slice(0, limit).map((r) => mapParsedJson<ProtocolFeeTakenEvent>(r)).filter((x): x is ProtocolFeeTakenEvent => Boolean(x));
}

export async function getRecentPoolCreationFees(pkg: string, limit = 50): Promise<PoolCreationFeePaidEvent[]> {
  const t = eventType(pkg, 'PoolCreationFeePaid');
  const rows = await db.events.where('type').equals(t).toArray();
  rows.sort((a, b) => (b.tsMs ?? 0) - (a.tsMs ?? 0));
  return rows.slice(0, limit).map((r) => mapParsedJson<PoolCreationFeePaidEvent>(r)).filter((x): x is PoolCreationFeePaidEvent => Boolean(x));
}


