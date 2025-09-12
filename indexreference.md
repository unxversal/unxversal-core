# Sui TS SDK: Poll-based Event Indexer (Condensed Guide)

Below is a compact, production-ready recipe to build a **low-latency, poll-based event listener** with the Sui TypeScript SDK. It covers filtering, backfilling, tail-following, durability, and rate-limit hygiene.

---

## 1) Install & connect

```bash
npm i @mysten/sui better-sqlite3
# or use Postgres/Prisma if you prefer
```

```ts
import { SuiClient, getFullnodeUrl } from '@mysten/sui/client';

export const client = new SuiClient({ url: getFullnodeUrl('mainnet') }); 
// In prod, use a dedicated RPC URL from a provider (not public fullnode).
```

---

## 2) Choose your event **filters**

Pick the narrowest filter possible (less noise = lower latency & cost):

* **MoveModule**: events *emitted by* a package+module
  `{ MoveModule: { package: '0x…', module: 'clob_v2' } }`
* **MoveEventType**: a specific event struct
  `{ MoveEventType: '0x…::my_mod::MyEvent' }`
* **Sender**: by transaction sender
  `{ Sender: '0x…' }`
* **TimeRange**: `[startMs, endMs]` window
  `{ TimeRange: { startTime: 1710000000000, endTime: 1710000009000 } }`
* Combine with `Any` / `All` to intersect/union filters.

**Tip:** Start with one of:

```ts
const FILTER_BY_MODULE = { MoveModule: { package: '0xYOUR_PKG', module: 'your_module' } } as const;
const FILTER_BY_TYPE   = { MoveEventType: '0xYOUR_PKG::your_module::YourEvent' } as const;
```

---

## 3) Minimal **durable storage** (SQLite example)

Use a tiny DB to:

* store a **cursor** `(txDigest, eventSeq)` for resume
* **dedupe** on primary key `(txDigest, eventSeq)`
* keep basic event fields for your app logic

```ts
import Database from 'better-sqlite3';
export const db = new Database('./events.db');
db.exec(`
  PRAGMA journal_mode=WAL;
  CREATE TABLE IF NOT EXISTS cursor_state (id INTEGER PRIMARY KEY CHECK(id=1), tx_digest TEXT, event_seq INTEGER);
  INSERT OR IGNORE INTO cursor_state (id, tx_digest, event_seq) VALUES (1, NULL, NULL);

  CREATE TABLE IF NOT EXISTS events (
    tx_digest TEXT NOT NULL,
    event_seq INTEGER NOT NULL,
    ts_ms INTEGER,
    sender TEXT,
    package_id TEXT,
    module TEXT,
    move_type TEXT,
    parsed_json TEXT,
    PRIMARY KEY (tx_digest, event_seq)
  );
`);
```

Helpers:

```ts
type Cursor = { txDigest: string; eventSeq: number } | null;

const loadCursor = (): Cursor => {
  const r = db.prepare(`SELECT tx_digest, event_seq FROM cursor_state WHERE id=1`).get();
  return r?.tx_digest ? { txDigest: r.tx_digest, eventSeq: Number(r.event_seq) } : null;
};
const saveCursor = (c: Cursor) =>
  db.prepare(`UPDATE cursor_state SET tx_digest=?, event_seq=? WHERE id=1`)
    .run(c?.txDigest ?? null, c?.eventSeq ?? null);

const insertEvent = (e: any) => db.prepare(`
  INSERT OR IGNORE INTO events (tx_digest, event_seq, ts_ms, sender, package_id, module, move_type, parsed_json)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?)
`).run(
  e.id.txDigest,
  Number(e.id.eventSeq),
  e.timestampMs ?? null,
  e.sender ?? null,
  e.packageId ?? null,
  e.transactionModule ?? null,
  e.type ?? null,
  e.parsedJson ? JSON.stringify(e.parsedJson) : null,
);
```

---

## 4) **Backfill → then follow** (recommended pattern)

### A) Backfill (history), optionally in **time windows**

Use ascending order + pagination until window is drained.

```ts
const PAGE_LIMIT = 100;

async function drainWindow(filterCore: any, startMs: number, endMs: number) {
  let cursor: Cursor = null;
  while (true) {
    const res = await client.queryEvents({
      // intersect core filter with time window
      filter: { Any: [filterCore, { TimeRange: { startTime: startMs, endTime: endMs } }] },
      cursor: cursor ? { txDigest: cursor.txDigest, eventSeq: String(cursor.eventSeq) } : null,
      limit: PAGE_LIMIT,
      order: 'ascending',
    });

    const events = res.data ?? [];
    if (events.length === 0) break;

    for (const ev of events) insertEvent(ev);

    cursor = res.nextCursor
      ? { txDigest: res.nextCursor.txDigest, eventSeq: Number(res.nextCursor.eventSeq) }
      : { txDigest: events.at(-1)!.id.txDigest, eventSeq: Number(events.at(-1)!.id.eventSeq) };
    saveCursor(cursor);

    if (!res.hasNextPage) break;
  }
}
```

Then sweep windows from deploy time (or a chosen `sinceMs`) to **now**:

```ts
async function backfillSince(filterCore: any, sinceMs: number) {
  const WIN = 7 * 24 * 3600 * 1000; // 7d windows (tune as needed)
  for (let s = sinceMs; s < Date.now(); s += WIN) {
    await drainWindow(filterCore, s, Math.min(s + WIN, Date.now()));
  }
}
```

### B) Follow (live tail)

* Keep your latest cursor
* Tight loop: if page has data, process immediately (no sleep); if empty, sleep briefly
* Always **ascending** for deterministic order

```ts
const IDLE_MS = 300; // 300–500ms is a good start

async function followLive(filterCore: any) {
  let cursor: Cursor = loadCursor();
  while (true) {
    try {
      const res = await client.queryEvents({
        filter: filterCore,
        cursor: cursor ? { txDigest: cursor.txDigest, eventSeq: String(cursor.eventSeq) } : null,
        limit: PAGE_LIMIT,
        order: 'ascending',
      });

      const events = res.data ?? [];
      if (events.length > 0) {
        for (const ev of events) insertEvent(ev);
        cursor = res.nextCursor
          ? { txDigest: res.nextCursor.txDigest, eventSeq: Number(res.nextCursor.eventSeq) }
          : { txDigest: events.at(-1)!.id.txDigest, eventSeq: Number(events.at(-1)!.id.eventSeq) };
        saveCursor(cursor);
        continue; // got data → poll again immediately
      }

      await sleep(IDLE_MS); // idle
    } catch (e) {
      await sleep(200 + Math.random() * 400); // backoff on errors
    }
  }
}
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
```

**Kickoff:**

```ts
(async () => {
  const filter = { MoveModule: { package: '0xYOUR_PKG', module: 'your_module' } } as const;
  await backfillSince(filter, Date.parse('2025-01-01T00:00:00Z')); // pick your start
  await followLive(filter);
})();
```

---

## 5) Alternative: **Per-second “slices”** (optional)

If you want fixed time slices instead of cursors:

* Every 1s, query `[now−1s−overlap, now]`
* **Paginate**, **dedupe by (txDigest,eventSeq)**, **small overlap** (e.g., 200–500ms) to survive clock skew
* Cursors are still better for **high volume** & strict ordering

```ts
async function fetchWindow(filterCore: any, startMs: number, endMs: number, seen: Set<string>) {
  let cursor: any = null;
  while (true) {
    const res = await client.queryEvents({
      filter: { Any: [filterCore, { TimeRange: { startTime: startMs, endTime: endMs } }] },
      cursor, limit: 200, order: 'ascending',
    });
    for (const e of res.data ?? []) {
      const k = `${e.id.txDigest}:${e.id.eventSeq}`;
      if (!seen.has(k)) { seen.add(k); insertEvent(e); }
    }
    if (!res.hasNextPage || !res.nextCursor) break;
    cursor = res.nextCursor;
  }
}
```

---

## 6) **Rate-limit & reliability** checklist

* **Use dedicated RPC(s)** in production; public nodes are \~100 req / 30s and best-effort.
* **Token bucket** per process (e.g., \~3 req/s, burst 10); **jitter** timers to avoid herds.
* **429/5xx backoff** with jitter; respect `Retry-After` if provided.
* **Redundancy**: maintain a small pool of providers; health-check and fail over.
* **Minimize calls**: narrow filters, paginate correctly, never re-scan history, cache static data.
* **Observability**: track events/sec, p95 latency, error rate, last successful timestamp.
* **Idempotency**: DB primary key `(txDigest,eventSeq)` to dedupe.
* **Crash-safe resume**: persist `nextCursor` after every processed page.

---

## 7) When to prefer a **custom indexer**

* You need **complex transforms**, multiple tables, or high throughput
* You want **checkpoint-aligned** ingestion with framework batching & retries
* You plan to write to **Postgres/other DB** with ORMs (Diesel/Prisma) and partitioning

For many **bot/front-end** cases, the **poller** above is simpler and plenty fast.

---

## 8) Quick “drop-in” template (copy/paste)

```ts
// indexer.ts
import { SuiClient, getFullnodeUrl } from '@mysten/sui/client';
import Database from 'better-sqlite3';

const client = new SuiClient({ url: getFullnodeUrl('mainnet') });
const db = new Database('./events.db'); db.exec(`
  PRAGMA journal_mode=WAL;
  CREATE TABLE IF NOT EXISTS cursor_state (id INTEGER PRIMARY KEY CHECK(id=1), tx_digest TEXT, event_seq INTEGER);
  INSERT OR IGNORE INTO cursor_state (id, tx_digest, event_seq) VALUES (1, NULL, NULL);
  CREATE TABLE IF NOT EXISTS events (
    tx_digest TEXT, event_seq INTEGER, ts_ms INTEGER, move_type TEXT, parsed_json TEXT,
    PRIMARY KEY (tx_digest, event_seq)
  );
`);

type Cursor = { txDigest: string; eventSeq: number } | null;
const loadCursor = (): Cursor => {
  const r = db.prepare(`SELECT tx_digest, event_seq FROM cursor_state WHERE id=1`).get();
  return r?.tx_digest ? { txDigest: r.tx_digest, eventSeq: Number(r.event_seq) } : null;
};
const saveCursor = (c: Cursor) =>
  db.prepare(`UPDATE cursor_state SET tx_digest=?, event_seq=? WHERE id=1`).run(c?.txDigest ?? null, c?.eventSeq ?? null);

const insertEvent = (e: any) => db.prepare(`
  INSERT OR IGNORE INTO events (tx_digest, event_seq, ts_ms, move_type, parsed_json)
  VALUES (?, ?, ?, ?, ?)
`).run(e.id.txDigest, Number(e.id.eventSeq), e.timestampMs ?? null, e.type ?? null, e.parsedJson ? JSON.stringify(e.parsedJson) : null);

const PAGE_LIMIT = 100, IDLE_MS = 300;

async function backfillSince(filterCore: any, sinceMs: number) {
  const WIN = 7 * 24 * 3600 * 1000;
  for (let s = sinceMs; s < Date.now(); s += WIN) {
    let cursor: Cursor = null;
    while (true) {
      const res = await client.queryEvents({
        filter: { Any: [filterCore, { TimeRange: { startTime: s, endTime: Math.min(s + WIN, Date.now()) } }] },
        cursor: cursor ? { txDigest: cursor.txDigest, eventSeq: String(cursor.eventSeq) } : null,
        limit: PAGE_LIMIT, order: 'ascending',
      });
      const events = res.data ?? [];
      if (events.length === 0) break;
      for (const ev of events) insertEvent(ev);
      cursor = res.nextCursor
        ? { txDigest: res.nextCursor.txDigest, eventSeq: Number(res.nextCursor.eventSeq) }
        : { txDigest: events.at(-1)!.id.txDigest, eventSeq: Number(events.at(-1)!.id.eventSeq) };
      saveCursor(cursor);
      if (!res.hasNextPage) break;
    }
  }
}

async function followLive(filterCore: any) {
  let cursor: Cursor = loadCursor();
  while (true) {
    try {
      const res = await client.queryEvents({
        filter: filterCore,
        cursor: cursor ? { txDigest: cursor.txDigest, eventSeq: String(cursor.eventSeq) } : null,
        limit: PAGE_LIMIT, order: 'ascending',
      });
      const events = res.data ?? [];
      if (events.length > 0) {
        for (const ev of events) insertEvent(ev);
        cursor = res.nextCursor
          ? { txDigest: res.nextCursor.txDigest, eventSeq: Number(res.nextCursor.eventSeq) }
          : { txDigest: events.at(-1)!.id.txDigest, eventSeq: Number(events.at(-1)!.id.eventSeq) };
        saveCursor(cursor);
        continue;
      }
      await new Promise(r => setTimeout(r, IDLE_MS));
    } catch {
      await new Promise(r => setTimeout(r, 200 + Math.random() * 400));
    }
  }
}

(async () => {
  const FILTER = { MoveModule: { package: '0xYOUR_PKG', module: 'your_module' } } as const;
  await backfillSince(FILTER, Date.parse('2025-01-01T00:00:00Z'));
  await followLive(FILTER);
})();
```

---

If you tell me the **package/module** (and any specific **event types** like `::clob_v2::OrderFilled<…>`), I can plug them into this template, add derived columns you’ll care about (e.g., quantities/prices), and swap SQLite for Postgres/Prisma with proper indexes and partitions.
