import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';

function readU128LE(bytes: Uint8Array): bigint {
  let v = 0n;
  for (let i = 0; i < Math.min(16, bytes.length); i++) {
    v |= BigInt(bytes[i]) << (8n * BigInt(i));
  }
  return v;
}

function readU32LE(bytes: Uint8Array): number {
  const b0 = bytes[0] ?? 0, b1 = bytes[1] ?? 0, b2 = bytes[2] ?? 0, b3 = bytes[3] ?? 0;
  return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
}

export async function getUserPointsAndRank(
  client: SuiClient,
  pkgUnxversal: string,
  rewardsId: string,
  user: string,
): Promise<{ allTimePoints: bigint; weekPoints: bigint; rankExact?: number; percentileBps?: number } | null> {
  try {
    const tx = new Transaction();
    // view_alltime_points
    tx.moveCall({
      target: `${pkgUnxversal}::rewards::view_alltime_points`,
      arguments: [tx.object(rewardsId), tx.pure.address(user)],
    });
    // compute current week id from local time
    const weekId = Math.floor(Date.now() / 86400000) / 7 | 0;
    tx.moveCall({
      target: `${pkgUnxversal}::rewards::view_week_points`,
      arguments: [tx.object(rewardsId), tx.pure.address(user), tx.pure.u64(weekId)],
    });
    tx.moveCall({
      target: `${pkgUnxversal}::rewards::view_week_rank_exact`,
      arguments: [tx.object(rewardsId), tx.pure.address(user), tx.pure.u64(weekId)],
    });
    tx.moveCall({
      target: `${pkgUnxversal}::rewards::view_week_percentile`,
      arguments: [tx.object(rewardsId), tx.pure.address(user), tx.pure.u64(weekId)],
    });
    const res = await client.devInspectTransactionBlock({ sender: user, transactionBlock: tx });
    const rv = res.results?.flatMap(r => r.returnValues ?? []) ?? [];
    if (rv.length < 4) return null;
    const [allTimeRaw] = rv[0];
    const [weekRaw] = rv[1];
    const [rankOptRaw] = rv[2];
    const [pctRaw] = rv[3];
    const allTime = readU128LE(Buffer.from(allTimeRaw, 'base64'));
    const week = readU128LE(Buffer.from(weekRaw, 'base64'));
    const rankBytes = Buffer.from(rankOptRaw, 'base64');
    let rankExact: number | undefined;
    if (rankBytes.length >= 1) {
      const tag = rankBytes[0];
      if (tag === 1 && rankBytes.length >= 5) {
        rankExact = readU32LE(rankBytes.subarray(1, 5));
      }
    }
    const pct = Buffer.from(pctRaw, 'base64');
    const percentileBps = pct.length >= 2 ? (pct[0] | (pct[1] << 8)) : undefined;
    return { allTimePoints: allTime, weekPoints: week, rankExact, percentileBps };
  } catch {
    return null;
  }
}


