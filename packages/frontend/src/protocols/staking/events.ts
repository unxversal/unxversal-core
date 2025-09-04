import { db } from '../../lib/storage';

export type Staked = { pool_id: string; who: string; amount: number; activate_week: number; timestamp_ms: number };
export type Unstaked = { pool_id: string; who: string; amount: number; effective_week: number; timestamp_ms: number };
export type RewardAdded = { pool_id: string; amount: number; week: number; timestamp_ms: number };
export type RewardsClaimed = { pool_id: string; who: string; from_week: number; to_week: number; amount: number; timestamp_ms: number };

function et(pkg: string, name: string) { return `${pkg}::staking::${name}`; }

async function recent<T>(typeName: string, limit: number): Promise<T[]> {
  const rows = await db.events.where('type').equals(typeName).toArray();
  rows.sort((a, b) => (b.tsMs ?? 0) - (a.tsMs ?? 0));
  return rows.slice(0, limit).map((r) => r.parsedJson as T).filter(Boolean) as T[];
}

export const recentStakes = (pkg: string, limit = 200) => recent<Staked>(et(pkg, 'Staked'), limit);
export const recentUnstakes = (pkg: string, limit = 200) => recent<Unstaked>(et(pkg, 'Unstaked'), limit);
export const recentRewardAdds = (pkg: string, limit = 200) => recent<RewardAdded>(et(pkg, 'RewardAdded'), limit);
export const recentClaims = (pkg: string, limit = 200) => recent<RewardsClaimed>(et(pkg, 'RewardsClaimed'), limit);


