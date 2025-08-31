import {SuiClient, getFullnodeUrl, type SuiEvent, type SuiEventFilter, type EventId} from '@mysten/sui/client';
import {z} from 'zod';
import {Pool} from 'pg';
import {loadConfig} from '../lib/config.js';

export type SuiEventsCursor = { txDigest: string; eventSeq: string } | null;

export class LendingIndexer {
  private client: SuiClient;
  private pool: Pool;
  private running = false;
  private cursor: SuiEventsCursor = null;
  private lastWriteMs: number | null = null;

  constructor(rpcUrl: string, postgresUrl: string) {
    this.client = new SuiClient({ url: rpcUrl || getFullnodeUrl('testnet') });
    this.pool = new Pool({ connectionString: postgresUrl });
  }

  static async fromConfig() {
    const cfg = await loadConfig();
    if (!cfg) throw new Error('No config found; run settings first.');
    return new LendingIndexer(cfg.rpcUrl, cfg.postgresUrl);
  }

  async init() {
    await this.pool.query(`create table if not exists lending_events (tx_digest text, event_seq text, type text, timestamp_ms bigint, parsed_json jsonb, primary key(tx_digest,event_seq))`);
    await this.pool.query(`create table if not exists lending_accounts (account_id text primary key, owner text, last_update_ms bigint)`);
    await this.pool.query(`create table if not exists lending_pools (pool_id text primary key, asset text, total_supply bigint, total_borrows bigint, total_reserves bigint, last_update_ms bigint)`);
    await this.pool.query(`create table if not exists lending_balances (account_id text, asset text, supply_scaled bigint default 0, borrow_scaled bigint default 0, primary key (account_id, asset))`);
    await this.pool.query(`create table if not exists lending_fees (tx_digest text, event_seq text, asset text, amount bigint, timestamp_ms bigint, primary key(tx_digest,event_seq))`);
    await this.pool.query(`create table if not exists cursors (id text primary key, tx_digest text, event_seq text)`);
    const row = await this.pool.query('select tx_digest, event_seq from cursors where id=$1', ['lend']);
    if (row.rows.length > 0 && row.rows[0].tx_digest && row.rows[0].event_seq) {
      this.cursor = { txDigest: row.rows[0].tx_digest, eventSeq: row.rows[0].event_seq };
    }
  }

  async saveCursor(c: SuiEventsCursor) {
    this.cursor = c;
    await this.pool.query('insert into cursors (id,tx_digest,event_seq) values ($1,$2,$3) on conflict (id) do update set tx_digest=$2,event_seq=$3', ['lend', c?.txDigest || null, c?.eventSeq || null]);
  }

  async run(filter: SuiEventFilter) {
    this.running = true;
    while (this.running) {
      try {
        const res = await this.client.queryEvents({ query: filter, cursor: (this.cursor as unknown as EventId) ?? null, order: 'ascending', limit: 200 });
        const events = res.data ?? [];
        if (events.length > 0) {
          const client = await this.pool.connect();
          try {
            await client.query('begin');
            for (const ev of events as SuiEvent[]) {
              await client.query('insert into lending_events(tx_digest,event_seq,type,timestamp_ms,parsed_json) values($1,$2,$3,$4,$5) on conflict do nothing', [ev.id.txDigest, ev.id.eventSeq, ev.type, ev.timestampMs ? Number(ev.timestampMs) : null, ev.parsedJson ? JSON.stringify(ev.parsedJson) : null]);
              if (endsWith(ev, '::lending::AssetSupplied')) {
                const p = AssetSuppliedSchema.parse(ev.parsedJson);
                await client.query('insert into lending_balances(account_id,asset,supply_scaled,borrow_scaled) values ($1,$2,$3,0) on conflict(account_id,asset) do update set supply_scaled = lending_balances.supply_scaled + excluded.supply_scaled', [p.user, p.asset, p.amount]);
              } else if (endsWith(ev, '::lending::AssetWithdrawn')) {
                const p = AssetWithdrawnSchema.parse(ev.parsedJson);
                await client.query('update lending_balances set supply_scaled = greatest(0, supply_scaled - $3) where account_id=$1 and asset=$2', [p.user, p.asset, p.amount]);
              } else if (endsWith(ev, '::lending::AssetBorrowed')) {
                const p = AssetBorrowedSchema.parse(ev.parsedJson);
                await client.query('insert into lending_balances(account_id,asset,borrow_scaled,supply_scaled) values ($1,$2,$3,0) on conflict(account_id,asset) do update set borrow_scaled = lending_balances.borrow_scaled + excluded.borrow_scaled', [p.user, p.asset, p.amount]);
              } else if (endsWith(ev, '::lending::DebtRepaid')) {
                const p = DebtRepaidSchema.parse(ev.parsedJson);
                await client.query('update lending_balances set borrow_scaled = greatest(0, borrow_scaled - $3) where account_id=$1 and asset=$2', [p.user, p.asset, p.amount]);
              } else if (endsWith(ev, '::lending::RateUpdated')) {
                const p = RateUpdatedSchema.parse(ev.parsedJson);
                await client.query('insert into lending_pools(pool_id,asset,total_supply,total_borrows,total_reserves,last_update_ms) values ($1,$2,0,0,0,$3) on conflict(pool_id) do update set last_update_ms=excluded.last_update_ms', [ev.id.txDigest, p.asset, p.timestamp]);
              } else if (endsWith(ev, '::lending::InterestAccrued')) {
                const p = InterestAccruedSchema.parse(ev.parsedJson);
                await client.query('insert into lending_fees(tx_digest,event_seq,asset,amount,timestamp_ms) values ($1,$2,$3,$4,$5) on conflict do nothing', [ev.id.txDigest, ev.id.eventSeq, p.asset, p.reserves_added, p.timestamp]);
              }
            }
            const last = events[events.length - 1];
            if (res.nextCursor) { await this.saveCursor({ txDigest: res.nextCursor.txDigest, eventSeq: String(res.nextCursor.eventSeq) }); }
            else if (last) { await this.saveCursor({ txDigest: last.id.txDigest, eventSeq: String(last.id.eventSeq) }); }
            await client.query('commit');
          } finally { client.release(); }
          this.lastWriteMs = Date.now();
          continue;
        }
        await new Promise(r => setTimeout(r, 300));
      } catch (e) {
        console.error('[lend-indexer] error', e);
        await new Promise(r => setTimeout(r, 700));
      }
    }
  }

  stop() { this.running = false; }

  static buildModuleFilter(packageId: string): SuiEventFilter { return { MoveEventModule: { package: packageId, module: 'lending' } }; }

  async backfillThenFollow(packageId: string, sinceMs: number) {
    const core = LendingIndexer.buildModuleFilter(packageId);
    const WINDOW = 7 * 24 * 3600 * 1000;
    let start = sinceMs;
    while (start < Date.now()) {
      const end = Math.min(start + WINDOW, Date.now());
      this.cursor = await this.backfillWindow(core, start, end, this.cursor);
      start = end;
    }
    await this.run(core);
  }

  async backfillWindow(filterCore: SuiEventFilter, startMs: number, endMs: number, cursor: SuiEventsCursor): Promise<SuiEventsCursor> {
    let cur: SuiEventsCursor = cursor;
    const res = await this.client.queryEvents({ query: { Any: [filterCore, { TimeRange: { startTime: startMs, endTime: endMs } }] } as any, cursor: (cur as unknown as EventId) ?? null, order: 'ascending', limit: 200 });
    const events = res.data ?? [];
    if (events.length > 0) {
      const client = await this.pool.connect();
      try {
        await client.query('begin');
        for (const ev of events as SuiEvent[]) {
          await client.query('insert into lending_events(tx_digest,event_seq,type,timestamp_ms,parsed_json) values($1,$2,$3,$4,$5) on conflict do nothing', [ev.id.txDigest, ev.id.eventSeq, ev.type, ev.timestampMs ? Number(ev.timestampMs) : null, ev.parsedJson ? JSON.stringify(ev.parsedJson) : null]);
        }
        await client.query('commit');
      } finally { client.release(); }
      const last = events[events.length - 1];
      cur = res.nextCursor ?? (last ? { txDigest: last.id.txDigest, eventSeq: String(last.id.eventSeq) } : null);
      await this.saveCursor(cur);
    }
    return cur;
  }

  health() { return { running: this.running, lastWriteMs: this.lastWriteMs, cursor: this.cursor }; }
}

function endsWith(ev: SuiEvent, suffix: string): boolean { return typeof ev.type === 'string' && ev.type.endsWith(suffix); }

const ZNum = z.union([z.number(), z.string()]).transform(v => typeof v === 'number' ? v : Number(v));
const ZStr = z.union([z.string(), z.number()]).transform(v => String(v));

const AssetSuppliedSchema = z.object({ user: ZStr, asset: ZStr, amount: ZNum, new_balance: ZNum, timestamp: ZNum }).strip();
const AssetWithdrawnSchema = z.object({ user: ZStr, asset: ZStr, amount: ZNum, remaining_balance: ZNum, timestamp: ZNum }).strip();
const AssetBorrowedSchema = z.object({ user: ZStr, asset: ZStr, amount: ZNum, new_borrow_balance: ZNum, timestamp: ZNum }).strip();
const DebtRepaidSchema = z.object({ user: ZStr, asset: ZStr, amount: ZNum, remaining_debt: ZNum, timestamp: ZNum }).strip();
const RateUpdatedSchema = z.object({ asset: ZStr, utilization_bps: ZNum, borrow_rate_bps: ZNum, supply_rate_bps: ZNum, timestamp: ZNum }).strip();
const InterestAccruedSchema = z.object({ asset: ZStr, dt_ms: ZNum, new_borrow_index: ZNum, new_supply_index: ZNum, delta_borrows: ZNum, reserves_added: ZNum, timestamp: ZNum }).strip();


