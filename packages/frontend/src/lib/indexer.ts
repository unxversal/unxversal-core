import { SuiClient } from '@mysten/sui/client';
import { db, type EventRow } from './storage';
import { loadIndexerSettings } from './settings';

export type EventFilter =
  | { MoveModule: { package: string; module: string } }
  | { MoveEventType: string }
  | { Sender: string }
  | { TimeRange: { startTime: number; endTime: number } }
  | { Any: EventFilter[] };

export type IndexerTracker = {
  id: string;                // unique name
  filter: EventFilter;
  pageLimit?: number;
};

export type Cursor = { txDigest: string; eventSeq: string } | null;

function keyOf(txDigest: string, eventSeq: string): string {
  return `${txDigest}:${eventSeq}`;
}

export async function loadCursor(id: string): Promise<Cursor> {
  const row = await db.cursors.get(id);
  if (!row || row.txDigest == null || row.eventSeq == null) return null;
  return { txDigest: row.txDigest, eventSeq: String(row.eventSeq) };
}

export async function saveCursor(id: string, c: Cursor): Promise<void> {
  await db.cursors.put({ id, txDigest: c?.txDigest ?? null, eventSeq: c ? Number(c.eventSeq) : null });
}

export async function insertEvents(rows: EventRow[]): Promise<void> {
  if (!rows.length) return;
  await db.events.bulkPut(rows);
}

export async function pollOnce(client: SuiClient, tracker: IndexerTracker, cursor: Cursor): Promise<{ cursor: Cursor; hasNext: boolean; count: number }>{
  const settings = loadIndexerSettings();
  const res = await client.queryEvents({
    query: tracker.filter as any,
    cursor: cursor as any,
    limit: tracker.pageLimit ?? settings.pageLimit,
    order: 'ascending',
  } as any);

  const data = (res as any).data ?? [];
  const rows: EventRow[] = [];
  for (const ev of data) {
    rows.push({
      key: keyOf(ev.id.txDigest, String(ev.id.eventSeq)),
      txDigest: ev.id.txDigest,
      eventSeq: Number(ev.id.eventSeq),
      tsMs: ev.timestampMs ? Number(ev.timestampMs) : null,
      type: ev.type ?? null,
      module: ev.transactionModule ?? null,
      packageId: ev.packageId ?? null,
      sender: ev.sender ?? null,
      parsedJson: ev.parsedJson ?? null,
    });
  }
  await insertEvents(rows);

  const next = (res as any).nextCursor ?? null;
  const hasNext = Boolean((res as any).hasNextPage);
  await saveCursor(tracker.id, next);
  return { cursor: next, hasNext, count: rows.length };
}

export async function runPollLoop(client: SuiClient, tracker: IndexerTracker, _idleMs = 400): Promise<never> {
  let cursor = await loadCursor(tracker.id);
  while (true) {
    try {
      const { cursor: nc, hasNext, count } = await pollOnce(client, tracker, cursor);
      cursor = nc;
      if (hasNext || count > 0) continue; // immediate next to catch up
      const { pollEveryMs } = loadIndexerSettings();
      await sleep(pollEveryMs);
    } catch (e) {
      await sleep(300 + Math.floor(Math.random() * 500));
    }
  }
}

function sleep(ms: number) { return new Promise((r) => setTimeout(r, ms)); }

export async function startTrackers(client: SuiClient, trackers: IndexerTracker[], idleMs = 400): Promise<void> {
  for (const t of trackers) {
    // fire-and-forget; run each tracker in its own task
    // eslint-disable-next-line @typescript-eslint/no-floating-promises
    (async () => runPollLoop(client, t, idleMs))();
  }
}

export function withTimeRange(filter: EventFilter, startTime: number, endTime: number): EventFilter {
  return { Any: [filter, { TimeRange: { startTime, endTime } }] } as const;
}

export async function pollWindowOnce(
  client: SuiClient,
  tracker: IndexerTracker,
  startTime: number,
  endTime: number,
): Promise<number> {
  const settings = loadIndexerSettings();
  let cursor: Cursor = null;
  let total = 0;
  while (true) {
    const res = await client.queryEvents({
      query: withTimeRange(tracker.filter as any, startTime, endTime) as any,
      cursor: cursor as any,
      limit: tracker.pageLimit ?? settings.pageLimit,
      order: 'ascending',
    } as any);

    const data = (res as any).data ?? [];
    const rows: EventRow[] = [];
    for (const ev of data) {
      rows.push({
        key: keyOf(ev.id.txDigest, String(ev.id.eventSeq)),
        txDigest: ev.id.txDigest,
        eventSeq: Number(ev.id.eventSeq),
        tsMs: ev.timestampMs ? Number(ev.timestampMs) : null,
        type: ev.type ?? null,
        module: ev.transactionModule ?? null,
        packageId: ev.packageId ?? null,
        sender: ev.sender ?? null,
        parsedJson: ev.parsedJson ?? null,
      });
    }
    await insertEvents(rows);
    total += rows.length;

    const hasNext = Boolean((res as any).hasNextPage);
    const next = (res as any).nextCursor ?? null;
    if (!hasNext || !next) break;
    cursor = next;
  }
  return total;
}

export async function runWindowLoop(client: SuiClient, tracker: IndexerTracker): Promise<never> {
  // second-based polling with small overlap to avoid boundary misses
  while (true) {
    const { pollEveryMs, windowSeconds } = loadIndexerSettings();
    const now = Date.now();
    const windowMs = Math.max(1000, windowSeconds * 1000);
    const start = now - windowMs - 300; // 300ms overlap
    try {
      await pollWindowOnce(client, tracker, start, now);
    } catch (e) {
      // best-effort; wait a bit more on errors
      await sleep(500 + Math.floor(Math.random() * 500));
    }
    await sleep(pollEveryMs);
  }
}

export async function startWindowTrackers(client: SuiClient, trackers: IndexerTracker[]): Promise<void> {
  for (const t of trackers) {
    // eslint-disable-next-line @typescript-eslint/no-floating-promises
    (async () => runWindowLoop(client, t))();
  }
}

export function buildDeepbookPublicIndexer(baseUrl: string) {
  async function j(path: string) {
    const r = await fetch(`${baseUrl.replace(/\/$/, '')}${path}`);
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return r.json();
  }
  return {
    getPools: () => j('/get_pools') as Promise<any[]>,
    allHistoricalVolume: (params?: { start_time?: number; end_time?: number; volume_in_base?: boolean }) => {
      const sp = new URLSearchParams();
      if (params?.start_time != null) sp.set('start_time', String(params.start_time));
      if (params?.end_time != null) sp.set('end_time', String(params.end_time));
      if (params?.volume_in_base != null) sp.set('volume_in_base', String(params.volume_in_base));
      const q = sp.toString();
      return j(`/all_historical_volume${q ? `?${q}` : ''}`) as Promise<Record<string, number>>;
    },
    historicalVolume: (poolNames: string[], params?: { start_time?: number; end_time?: number; volume_in_base?: boolean }) => {
      const sp = new URLSearchParams();
      if (params?.start_time != null) sp.set('start_time', String(params.start_time));
      if (params?.end_time != null) sp.set('end_time', String(params.end_time));
      if (params?.volume_in_base != null) sp.set('volume_in_base', String(params.volume_in_base));
      const q = sp.toString();
      return j(`/historical_volume/${poolNames.join(',')}${q ? `?${q}` : ''}`) as Promise<Record<string, number>>;
    },
    historicalVolumeByBM: (poolNames: string[], balanceManagerId: string, params?: { start_time?: number; end_time?: number; volume_in_base?: boolean }) => {
      const sp = new URLSearchParams();
      if (params?.start_time != null) sp.set('start_time', String(params.start_time));
      if (params?.end_time != null) sp.set('end_time', String(params.end_time));
      if (params?.volume_in_base != null) sp.set('volume_in_base', String(params.volume_in_base));
      const q = sp.toString();
      return j(`/historical_volume_by_balance_manager_id/${poolNames.join(',')}/${balanceManagerId}${q ? `?${q}` : ''}`) as Promise<Record<string, [number, number]>>;
    },
    historicalVolumeByBMWithInterval: (
      poolNames: string[],
      balanceManagerId: string,
      params: { start_time?: number; end_time?: number; interval?: number; volume_in_base?: boolean } = {}
    ) => {
      const sp = new URLSearchParams();
      if (params?.start_time != null) sp.set('start_time', String(params.start_time));
      if (params?.end_time != null) sp.set('end_time', String(params.end_time));
      if (params?.interval != null) sp.set('interval', String(params.interval));
      if (params?.volume_in_base != null) sp.set('volume_in_base', String(params.volume_in_base));
      const q = sp.toString();
      return j(`/historical_volume_by_balance_manager_id_with_interval/${poolNames.join(',')}/${balanceManagerId}${q ? `?${q}` : ''}`) as Promise<Record<string, Record<string, [number, number]>>>;
    },
    summary: () => j('/summary') as Promise<any[]>,
    ticker: () => j('/ticker') as Promise<Record<string, { base_volume: number; quote_volume: number; last_price: number; isFrozen: 0 | 1 }>>,
    trades: (poolName: string, params?: { limit?: number; start_time?: number; end_time?: number; maker_balance_manager_id?: string; taker_balance_manager_id?: string }) => {
      const sp = new URLSearchParams();
      if (params?.limit != null) sp.set('limit', String(params.limit));
      if (params?.start_time != null) sp.set('start_time', String(params.start_time));
      if (params?.end_time != null) sp.set('end_time', String(params.end_time));
      if (params?.maker_balance_manager_id) sp.set('maker_balance_manager_id', params.maker_balance_manager_id);
      if (params?.taker_balance_manager_id) sp.set('taker_balance_manager_id', params.taker_balance_manager_id);
      const q = sp.toString();
      return j(`/trades/${poolName}${q ? `?${q}` : ''}`) as Promise<any[]>;
    },
    orderUpdates: (poolName: string, params?: { limit?: number; start_time?: number; end_time?: number; status?: 'Placed' | 'Canceled'; balance_manager_id?: string }) => {
      const sp = new URLSearchParams();
      if (params?.limit != null) sp.set('limit', String(params.limit));
      if (params?.start_time != null) sp.set('start_time', String(params.start_time));
      if (params?.end_time != null) sp.set('end_time', String(params.end_time));
      if (params?.status) sp.set('status', params.status);
      if (params?.balance_manager_id) sp.set('balance_manager_id', params.balance_manager_id);
      const q = sp.toString();
      return j(`/order_updates/${poolName}${q ? `?${q}` : ''}`) as Promise<any[]>;
    },
    orderbook: (poolName: string, params?: { level?: 1 | 2; depth?: number }) => {
      const sp = new URLSearchParams();
      if (params?.level != null) sp.set('level', String(params.level));
      if (params?.depth != null) sp.set('depth', String(params.depth));
      const q = sp.toString();
      return j(`/orderbook/${poolName}${q ? `?${q}` : ''}`) as Promise<{ timestamp: string; bids: [string, string][]; asks: [string, string][] }>;
    },
    assets: () => j('/assets') as Promise<Record<string, any>>,
  };
}


