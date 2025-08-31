import {SuiClient, getFullnodeUrl, type SuiEvent, type SuiEventFilter, type EventId} from '@mysten/sui/client';
import {z} from 'zod';
import {Pool} from 'pg';
import {loadConfig} from '../lib/config.js';

export type SuiEventsCursor = { txDigest: string; eventSeq: string } | null;

export class SyntheticsIndexer {
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
    return new SyntheticsIndexer(cfg.rpcUrl, cfg.postgresUrl);
  }

  async init() {
    // basic migration marker table
    await this.pool.query(`create table if not exists migrations (id text primary key, applied_at timestamptz default now())`);
    await this.pool.query(`
      create table if not exists synthetic_events (
        tx_digest text not null,
        event_seq text not null,
        type text,
        timestamp_ms bigint,
        parsed_json jsonb,
        primary key (tx_digest, event_seq)
      )
    `);
    // minimal projections for orders, bonds, fees, rebates; can be extended later
    await this.pool.query(`
      create table if not exists orders (
        order_id text primary key,
        symbol text,
        side smallint,
        price bigint,
        size bigint,
        remaining bigint,
        owner text,
        created_at_ms bigint,
        expiry_ms bigint,
        status text
      )
    `);
    await this.pool.query(`create index if not exists idx_orders_symbol on orders(symbol)`);
    await this.pool.query(`create index if not exists idx_orders_status on orders(status)`);
    await this.pool.query(`
      create table if not exists maker_bonds (
        order_id text primary key,
        bond bigint default 0,
        updated_at_ms bigint
      )
    `);
    await this.pool.query(`
      create table if not exists fees (
        tx_digest text,
        event_seq text,
        amount bigint,
        payer text,
        market text,
        reason text,
        timestamp_ms bigint,
        primary key (tx_digest, event_seq)
      )
    `);
    await this.pool.query(`create index if not exists idx_fees_ts on fees(timestamp_ms)`);
    await this.pool.query(`
      create table if not exists rebates (
        tx_digest text,
        event_seq text,
        amount bigint,
        taker text,
        maker text,
        market text,
        timestamp_ms bigint,
        primary key (tx_digest, event_seq)
      )
    `);
    await this.pool.query(`create index if not exists idx_rebates_ts on rebates(timestamp_ms)`);
    // Maker claimed events
    await this.pool.query(`
      create table if not exists maker_claims (
        tx_digest text,
        event_seq text,
        order_id text,
        market text,
        maker text,
        amount bigint,
        timestamp_ms bigint,
        primary key (tx_digest, event_seq)
      )
    `);
    await this.pool.query(`create index if not exists idx_maker_claims_ts on maker_claims(timestamp_ms)`);

    // New: vault and liquidation related tables
    await this.pool.query(`
      create table if not exists vaults (
        vault_id text primary key,
        owner text,
        last_update_ms bigint,
        collateral bigint default 0
      )
    `);
    await this.pool.query(`create index if not exists idx_vaults_owner on vaults(owner)`);
    
    await this.pool.query(`
      create table if not exists vault_debts (
        vault_id text,
        symbol text,
        units bigint default 0,
        primary key (vault_id, symbol)
      )
    `);
    await this.pool.query(`create index if not exists idx_vault_debts_symbol on vault_debts(symbol)`);

    await this.pool.query(`
      create table if not exists collateral_flows (
        tx_digest text,
        event_seq text,
        vault_id text,
        amount bigint,
        kind text,
        actor text,
        timestamp_ms bigint,
        primary key (tx_digest, event_seq)
      )
    `);
    await this.pool.query(`create index if not exists idx_collateral_flows_ts on collateral_flows(timestamp_ms)`);

    await this.pool.query(`
      create table if not exists liquidations (
        tx_digest text,
        event_seq text,
        vault_id text,
        liquidator text,
        liquidated_amount bigint,
        collateral_seized bigint,
        liquidation_penalty bigint,
        synthetic_type text,
        timestamp_ms bigint,
        primary key (tx_digest, event_seq)
      )
    `);
    await this.pool.query(`create index if not exists idx_liquidations_ts on liquidations(timestamp_ms)`);

    await this.pool.query(`
      create table if not exists params_updates (
        tx_digest text,
        event_seq text,
        updater text,
        timestamp_ms bigint,
        primary key (tx_digest, event_seq)
      )
    `);

    await this.pool.query(`
      create table if not exists pause_toggles (
        tx_digest text,
        event_seq text,
        new_state boolean,
        by_addr text,
        timestamp_ms bigint,
        primary key (tx_digest, event_seq)
      )
    `);

    await this.pool.query(`
      create table if not exists synthetics_assets (
        symbol text primary key,
        name text,
        decimals int,
        created_at_ms bigint
      )
    `);
    await this.pool.query(`
      create table if not exists synthetics_info (
        symbol text primary key,
        created_at_ms bigint
      )
    `);
    await this.pool.query(`
      create table if not exists cursors (
        id text primary key,
        tx_digest text,
        event_seq text
      )
    `);
    const row = await this.pool.query('select tx_digest, event_seq from cursors where id=$1', ['synth']);
    if (row.rows.length > 0 && row.rows[0].tx_digest && row.rows[0].event_seq) {
      this.cursor = { txDigest: row.rows[0].tx_digest, eventSeq: row.rows[0].event_seq };
    }
  }

  async saveCursor(c: SuiEventsCursor) {
    this.cursor = c;
    await this.pool.query(
      'insert into cursors (id, tx_digest, event_seq) values ($1,$2,$3) on conflict (id) do update set tx_digest=$2, event_seq=$3',
      ['synth', c?.txDigest || null, c?.eventSeq || null],
    );
  }

  async run(filter: SuiEventFilter) {
    this.running = true;
    while (this.running) {
      try {
        // TS SDK expects `query` key for filters
        const res = await this.client.queryEvents({
          query: filter,
          cursor: (this.cursor as unknown as EventId) ?? null,
          order: 'ascending',
          limit: 200,
        });
        const events = res.data ?? [];
        if (events.length > 0) {
          const client = await this.pool.connect();
          try {
            await client.query('begin');
            for (const ev of events as SuiEvent[]) {
              await client.query(
                'insert into synthetic_events (tx_digest, event_seq, type, timestamp_ms, parsed_json) values ($1,$2,$3,$4,$5) on conflict do nothing',
                [ev.id.txDigest, ev.id.eventSeq, ev.type, ev.timestampMs ? Number(ev.timestampMs) : null, ev.parsedJson ? JSON.stringify(ev.parsedJson) : null],
              );
              // lightweight projections
              if (endsWith(ev, '::synthetics::OrderbookOrderPlaced')) {
                const p = OrderbookPlacedSchema.parse(ev.parsedJson);
                await client.query(
                  `insert into orders(order_id,symbol,side,price,size,remaining,owner,created_at_ms,expiry_ms,status)
                   values ($1,$2,$3,$4,$5,$6,$7,$8,$9,'open')
                   on conflict (order_id) do update set remaining=excluded.remaining, status='open'`,
                  [String(p.order_id), p.symbol, p.side, p.price, p.size, p.remaining, p.owner, p.created_at_ms, p.expiry_ms],
                );
              } else if (endsWith(ev, '::synthetics::OrderbookOrderCancelled')) {
                const p = OrderCancelledSchema.parse(ev.parsedJson);
                await client.query(`update orders set status='canceled' where order_id=$1`, [p.order_id]);
              } else if (endsWith(ev, '::synthetics::OrderExpiredSwept')) {
                const p = OrderExpiredSweptSchema.parse(ev.parsedJson);
                await client.query(`update orders set status='expired' where order_id=$1`, [p.order_id]);
              } else if (endsWith(ev, '::synthetics::OrderMatched')) {
                const p = OrderMatchedSchema.parse(ev.parsedJson);
                // decrement remaining for both sides (best-effort; requires current remaining tracked)
                await client.query(`update orders set remaining = greatest(0, coalesce(remaining,0) - $2) where order_id=$1`, [p.buy_order_id, p.size]);
                await client.query(`update orders set remaining = greatest(0, coalesce(remaining,0) - $2) where order_id=$1`, [p.sell_order_id, p.size]);
                await client.query(`update orders set status='filled' where order_id=$1 and remaining=0`, [p.buy_order_id]);
                await client.query(`update orders set status='filled' where order_id=$1 and remaining=0`, [p.sell_order_id]);
              } else if (endsWith(ev, '::synthetics::BondPosted') || endsWith(ev, '::synthetics::BondToppedUp')) {
                const p = BondDeltaSchema.parse(ev.parsedJson);
                await client.query(`insert into maker_bonds(order_id,bond,updated_at_ms) values($1,$2,$3) on conflict(order_id) do update set bond = maker_bonds.bond + excluded.bond, updated_at_ms=excluded.updated_at_ms`, [p.order_id, p.amount, p.timestamp]);
              } else if (endsWith(ev, '::synthetics::BondRefunded') || endsWith(ev, '::synthetics::BondSlashed') || endsWith(ev, '::synthetics::BondReleased')) {
                const p = BondAnySchema.parse(ev.parsedJson);
                const delta = p.amount ?? p.slash_amount ?? 0;
                await client.query(`insert into maker_bonds(order_id,bond,updated_at_ms) values($1,$2,$3) on conflict(order_id) do update set bond = greatest(0, maker_bonds.bond - excluded.bond), updated_at_ms=excluded.updated_at_ms`, [p.order_id, delta, p.timestamp]);
              } else if (endsWith(ev, '::synthetics::FeeCollected')) {
                const p = FeeCollectedSchema.parse(ev.parsedJson);
                await client.query(`insert into fees(tx_digest,event_seq,amount,payer,market,reason,timestamp_ms) values ($1,$2,$3,$4,$5,$6,$7) on conflict do nothing`, [ev.id.txDigest, ev.id.eventSeq, p.amount, p.payer, p.market, p.reason, p.timestamp]);
              } else if (endsWith(ev, '::synthetics::MakerRebatePaid')) {
                const p = MakerRebateSchema.parse(ev.parsedJson);
                await client.query(`insert into rebates(tx_digest,event_seq,amount,taker,maker,market,timestamp_ms) values ($1,$2,$3,$4,$5,$6,$7) on conflict do nothing`, [ev.id.txDigest, ev.id.eventSeq, p.amount, p.taker, p.maker, p.market, p.timestamp]);
              } else if (endsWith(ev, '::synthetics::VaultCreated')) {
                const p = VaultCreatedSchema.parse(ev.parsedJson);
                await client.query(`insert into vaults(vault_id, owner, last_update_ms, collateral) values($1,$2,$3,coalesce((select collateral from vaults where vault_id=$1),0)) on conflict(vault_id) do update set owner=excluded.owner, last_update_ms=excluded.last_update_ms`, [p.vault_id, p.owner, p.timestamp]);
              } else if (endsWith(ev, '::synthetics::CollateralDeposited')) {
                const p = CollateralDepositedSchema.parse(ev.parsedJson);
                await client.query(`insert into collateral_flows(tx_digest,event_seq,vault_id,amount,kind,actor,timestamp_ms) values($1,$2,$3,$4,'deposit',$5,$6) on conflict do nothing`, [ev.id.txDigest, ev.id.eventSeq, p.vault_id, p.amount, p.depositor, p.timestamp]);
                await client.query(`insert into vaults(vault_id, owner, last_update_ms, collateral) values($1,null,$3,$2) on conflict(vault_id) do update set collateral = greatest(0, coalesce(vaults.collateral,0) + excluded.collateral), last_update_ms=excluded.last_update_ms`, [p.vault_id, p.amount, p.timestamp]);
              } else if (endsWith(ev, '::synthetics::CollateralWithdrawn')) {
                const p = CollateralWithdrawnSchema.parse(ev.parsedJson);
                await client.query(`insert into collateral_flows(tx_digest,event_seq,vault_id,amount,kind,actor,timestamp_ms) values($1,$2,$3,$4,'withdraw',$5,$6) on conflict do nothing`, [ev.id.txDigest, ev.id.eventSeq, p.vault_id, p.amount, p.withdrawer, p.timestamp]);
                await client.query(`update vaults set collateral = greatest(0, coalesce(collateral,0) - $2), last_update_ms=$3 where vault_id=$1`, [p.vault_id, p.amount, p.timestamp]);
              } else if (endsWith(ev, '::synthetics::SyntheticMinted')) {
                const p = SyntheticMintedSchema.parse(ev.parsedJson);
                await client.query(`insert into vault_debts(vault_id, symbol, units) values($1,$2,$3) on conflict(vault_id, symbol) do update set units = coalesce(vault_debts.units,0) + excluded.units`, [p.vault_id, p.synthetic_type, p.amount_minted]);
                await client.query(`update vaults set last_update_ms=$2 where vault_id=$1`, [p.vault_id, p.timestamp]);
              } else if (endsWith(ev, '::synthetics::SyntheticBurned')) {
                const p = SyntheticBurnedSchema.parse(ev.parsedJson);
                await client.query(`update vault_debts set units = greatest(0, coalesce(units,0) - $3) where vault_id=$1 and symbol=$2`, [p.vault_id, p.synthetic_type, p.amount_burned]);
                await client.query(`update vaults set last_update_ms=$2 where vault_id=$1`, [p.vault_id, p.timestamp]);
              } else if (endsWith(ev, '::synthetics::StabilityAccrued')) {
                const p = StabilityAccruedSchema.parse(ev.parsedJson);
                await client.query(`insert into vault_debts(vault_id, symbol, units) values($1,$2,$3) on conflict(vault_id, symbol) do update set units = coalesce(vault_debts.units,0) + excluded.units`, [p.vault_id, p.synthetic_type, p.delta_units]);
                await client.query(`update vaults set last_update_ms=$2 where vault_id=$1`, [p.vault_id, p.to_ms]);
              } else if (endsWith(ev, '::synthetics::LiquidationExecuted')) {
                const p = LiquidationExecutedSchema.parse(ev.parsedJson);
                await client.query(`insert into liquidations(tx_digest,event_seq,vault_id,liquidator,liquidated_amount,collateral_seized,liquidation_penalty,synthetic_type,timestamp_ms) values($1,$2,$3,$4,$5,$6,$7,$8,$9) on conflict do nothing`, [ev.id.txDigest, ev.id.eventSeq, p.vault_id, p.liquidator, p.liquidated_amount, p.collateral_seized, p.liquidation_penalty, p.synthetic_type, p.timestamp]);
                await client.query(`update vault_debts set units = greatest(0, coalesce(units,0) - $3) where vault_id=$1 and symbol=$2`, [p.vault_id, p.synthetic_type, p.liquidated_amount]);
                await client.query(`update vaults set collateral = greatest(0, coalesce(collateral,0) - $2), last_update_ms=$3 where vault_id=$1`, [p.vault_id, p.collateral_seized, p.timestamp]);
              } else if (endsWith(ev, '::synthetics::MakerClaimed')) {
                const p = MakerClaimedSchema.parse(ev.parsedJson);
                await client.query(`insert into maker_claims(tx_digest,event_seq,order_id,market,maker,amount,timestamp_ms) values ($1,$2,$3,$4,$5,$6,$7) on conflict do nothing`, [ev.id.txDigest, ev.id.eventSeq, p.order_id, p.market, p.maker, p.amount, p.timestamp]);
              } else if (endsWith(ev, '::synthetics::ParamsUpdated')) {
                const p = ParamsUpdatedSchema.parse(ev.parsedJson);
                await client.query(`insert into params_updates(tx_digest,event_seq,updater,timestamp_ms) values($1,$2,$3,$4) on conflict do nothing`, [ev.id.txDigest, ev.id.eventSeq, p.updater, p.timestamp]);
              } else if (endsWith(ev, '::synthetics::EmergencyPauseToggled')) {
                const p = PauseToggledSchema.parse(ev.parsedJson);
                await client.query(`insert into pause_toggles(tx_digest,event_seq,new_state,by_addr,timestamp_ms) values($1,$2,$3,$4,$5) on conflict do nothing`, [ev.id.txDigest, ev.id.eventSeq, p.new_state, p.by, p.timestamp]);
              } else if (endsWith(ev, '::synthetics::SyntheticAssetCreated')) {
                const p = SyntheticAssetCreatedSchema.parse(ev.parsedJson);
                await client.query(`insert into synthetics_assets(symbol,name,decimals,created_at_ms) values($1,$2,$3,$4) on conflict(symbol) do nothing`, [p.asset_symbol, p.asset_name, p.decimals ?? null, p.timestamp]);
              } else if (endsWith(ev, '::synthetics::SyntheticAssetInfoCreated')) {
                const p = SyntheticAssetInfoCreatedSchema.parse(ev.parsedJson);
                await client.query(`insert into synthetics_info(symbol,created_at_ms) values($1,$2) on conflict(symbol) do nothing`, [p.symbol, p.timestamp]);
              }
            }
            const last = events[events.length - 1];
            if (res.nextCursor) {
              await this.saveCursor({ txDigest: res.nextCursor.txDigest, eventSeq: String(res.nextCursor.eventSeq) });
            } else if (last) {
              await this.saveCursor({ txDigest: last.id.txDigest, eventSeq: String(last.id.eventSeq) });
            }
            await client.query('commit');
          } finally {
            client.release();
          }
          this.lastWriteMs = Date.now();
          continue; // immediately fetch next page
        }
        await new Promise(r => setTimeout(r, 300));
      } catch (e) {
        console.error('[indexer] error', e);
        await new Promise(r => setTimeout(r, 500 + Math.floor(Math.random()*300)));
      }
    }
  }

  stop() { this.running = false; }

  // Compose a filter that targets the synthetics module in this package
  static buildModuleFilter(packageId: string): SuiEventFilter {
    return { MoveEventModule: { package: packageId, module: 'synthetics' } };
  }

  // Build a single MoveEventType string like `${pkg}::synthetics::EventName`
  static buildTypeFilter(packageId: string, eventName: string): SuiEventFilter {
    return { MoveEventType: `${packageId}::synthetics::${eventName}` };
  }

  // Combine module filter with a TimeRange for backfill windows
  static buildWindowFilter(filterCore: SuiEventFilter, startMs: number, endMs: number): SuiEventFilter {
    return { Any: [filterCore, { TimeRange: { startTime: startMs, endTime: endMs } }] } as SuiEventFilter;
  }

  // Backfill in [startMs, endMs] window; returns last cursor
  async backfillWindow(filterCore: SuiEventFilter, startMs: number, endMs: number, cursor: SuiEventsCursor): Promise<SuiEventsCursor> {
    let cur: SuiEventsCursor = cursor;
    while (true) {
      const res = await this.client.queryEvents({
        query: SyntheticsIndexer.buildWindowFilter(filterCore, startMs, endMs),
        cursor: (cur as unknown as EventId) ?? null,
        order: 'ascending',
        limit: 200,
      });
      const events = res.data ?? [];
      if (events.length === 0) break;
      // reuse the same processor path as run()
      const client = await this.pool.connect();
      try {
        await client.query('begin');
        for (const ev of events as SuiEvent[]) {
          await client.query(
            'insert into synthetic_events (tx_digest, event_seq, type, timestamp_ms, parsed_json) values ($1,$2,$3,$4,$5) on conflict do nothing',
            [ev.id.txDigest, ev.id.eventSeq, ev.type, ev.timestampMs ? Number(ev.timestampMs) : null, ev.parsedJson ? JSON.stringify(ev.parsedJson) : null],
          );
          // projections
          if (endsWith(ev, '::synthetics::OrderbookOrderPlaced')) {
            const p = OrderbookPlacedSchema.parse(ev.parsedJson);
            await client.query(
              `insert into orders(order_id,symbol,side,price,size,remaining,owner,created_at_ms,expiry_ms,status)
               values ($1,$2,$3,$4,$5,$6,$7,$8,$9,'open')
               on conflict (order_id) do update set remaining=excluded.remaining, status='open'`,
              [p.order_id, p.symbol, p.side, p.price, p.size, p.remaining, p.owner, p.created_at_ms, p.expiry_ms],
            );
          } else if (endsWith(ev, '::synthetics::OrderbookOrderCancelled')) {
            const p = OrderCancelledSchema.parse(ev.parsedJson);
            await client.query(`update orders set status='canceled' where order_id=$1`, [p.order_id]);
          } else if (endsWith(ev, '::synthetics::OrderExpiredSwept')) {
            const p = OrderExpiredSweptSchema.parse(ev.parsedJson);
            await client.query(`update orders set status='expired' where order_id=$1`, [p.order_id]);
          } else if (endsWith(ev, '::synthetics::OrderMatched')) {
            const p = OrderMatchedSchema.parse(ev.parsedJson);
            await client.query(`update orders set remaining = greatest(0, coalesce(remaining,0) - $2) where order_id=$1`, [p.buy_order_id, p.size]);
            await client.query(`update orders set remaining = greatest(0, coalesce(remaining,0) - $2) where order_id=$1`, [p.sell_order_id, p.size]);
          } else if (endsWith(ev, '::synthetics::BondPosted') || endsWith(ev, '::synthetics::BondToppedUp')) {
            const p = BondDeltaSchema.parse(ev.parsedJson);
            await client.query(`insert into maker_bonds(order_id,bond,updated_at_ms) values($1,$2,$3) on conflict(order_id) do update set bond = maker_bonds.bond + excluded.bond, updated_at_ms=excluded.updated_at_ms`, [p.order_id, p.amount, p.timestamp]);
          } else if (endsWith(ev, '::synthetics::BondRefunded') || endsWith(ev, '::synthetics::BondSlashed') || endsWith(ev, '::synthetics::BondReleased')) {
            const p = BondAnySchema.parse(ev.parsedJson);
            const delta = p.amount ?? p.slash_amount ?? 0;
            await client.query(`insert into maker_bonds(order_id,bond,updated_at_ms) values($1,$2,$3) on conflict(order_id) do update set bond = greatest(0, maker_bonds.bond - excluded.bond), updated_at_ms=excluded.updated_at_ms`, [p.order_id, delta, p.timestamp]);
          } else if (endsWith(ev, '::synthetics::FeeCollected')) {
            const p = FeeCollectedSchema.parse(ev.parsedJson);
            await client.query(`insert into fees(tx_digest,event_seq,amount,payer,market,reason,timestamp_ms) values ($1,$2,$3,$4,$5,$6,$7) on conflict do nothing`, [ev.id.txDigest, ev.id.eventSeq, p.amount, p.payer, p.market, p.reason, p.timestamp]);
          } else if (endsWith(ev, '::synthetics::MakerRebatePaid')) {
            const p = MakerRebateSchema.parse(ev.parsedJson);
            await client.query(`insert into rebates(tx_digest,event_seq,amount,taker,maker,market,timestamp_ms) values ($1,$2,$3,$4,$5,$6,$7) on conflict do nothing`, [ev.id.txDigest, ev.id.eventSeq, p.amount, p.taker, p.maker, p.market, p.timestamp]);
          } else if (endsWith(ev, '::synthetics::MakerClaimed')) {
            const p = MakerClaimedSchema.parse(ev.parsedJson);
            await client.query(`insert into maker_claims(tx_digest,event_seq,order_id,market,maker,amount,timestamp_ms) values ($1,$2,$3,$4,$5,$6,$7) on conflict do nothing`, [ev.id.txDigest, ev.id.eventSeq, p.order_id, p.market, p.maker, p.amount, p.timestamp]);
          }
        }
        await client.query('commit');
      } finally {
        client.release();
      }
      const last = events.length > 0 ? events[events.length - 1] : null;
      cur = res.nextCursor ?? (last ? { txDigest: last.id.txDigest, eventSeq: String(last.id.eventSeq) } : null);
      await this.saveCursor(cur);
      if (!res.hasNextPage) break;
    }
    return cur;
  }

  // Backfill sinceMs in windows, then tail-follow using cursor loop
  async backfillThenFollow(packageId: string, sinceMs: number, types?: string[], windowDays = 7) {
    const coreFilter: SuiEventFilter = types && types.length > 0
      ? ({ Any: [SyntheticsIndexer.buildModuleFilter(packageId), ...types.map(t => SyntheticsIndexer.buildTypeFilter(packageId, t))] } as SuiEventFilter)
      : SyntheticsIndexer.buildModuleFilter(packageId);

    // Windows of 7 days
    const WINDOW = windowDays * 24 * 3600 * 1000;
    let start = sinceMs;
    while (start < Date.now()) {
      const end = Math.min(start + WINDOW, Date.now());
      this.cursor = await this.backfillWindow(coreFilter, start, end, this.cursor);
      start = end;
    }

    // Tail-follow
    await this.run(coreFilter);
  }

  health(): { running: boolean; lastWriteMs: number | null; cursor: SuiEventsCursor } {
    return { running: this.running, lastWriteMs: this.lastWriteMs, cursor: this.cursor };
  }

  // optional: lightweight HTTP health server (disabled by default; call startHealthServer to start)
  startHealthServer(port = 0): { port: number; close: () => void } {
    const http = require('node:http');
    const server = http.createServer((_req: any, res: any) => {
      const h = this.health();
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ ok: true, ...h }));
    });
    server.listen(port);
    const addr = server.address();
    const boundPort = typeof addr === 'object' && addr ? addr.port : (port || 0);
    return { port: boundPort, close: () => server.close() };
  }
}

// --------- type guards & schemas (zod-validated) ---------
function endsWith(ev: SuiEvent, suffix: string): boolean { return typeof ev.type === 'string' && ev.type.endsWith(suffix); }

const ZNum = z.union([z.number(), z.string()]).transform(v => typeof v === 'number' ? v : Number(v));
const ZStr = z.union([z.string(), z.number()]).transform(v => String(v));
const ZBool = z.union([z.boolean(), z.string()]).transform(v => typeof v === 'boolean' ? v : v === 'true');

const OrderbookPlacedSchema = z.object({ order_id: ZStr, symbol: ZStr, side: ZNum, price: ZNum, size: ZNum, remaining: ZNum, owner: ZStr, created_at_ms: ZNum, expiry_ms: ZNum }).strip();
const OrderCancelledSchema = z.object({ order_id: ZStr }).strip();
const OrderExpiredSweptSchema = z.object({ order_id: ZStr }).strip();
const OrderMatchedSchema = z.object({ buy_order_id: ZStr, sell_order_id: ZStr, size: ZNum }).strip();
const BondDeltaSchema = z.object({ order_id: ZStr, amount: ZNum, timestamp: ZNum }).strip();
const BondAnySchema = z.object({ order_id: ZStr, amount: ZNum.optional(), slash_amount: ZNum.optional(), timestamp: ZNum }).strip();
const FeeCollectedSchema = z.object({ amount: ZNum, payer: ZStr, market: ZStr, reason: ZStr, timestamp: ZNum }).strip();
const MakerRebateSchema = z.object({ amount: ZNum, taker: ZStr, maker: ZStr, market: ZStr, timestamp: ZNum }).strip();
const MakerClaimedSchema = z.object({ order_id: ZStr, market: ZStr, maker: ZStr, amount: ZNum, timestamp: ZNum }).strip();
const VaultCreatedSchema = z.object({ vault_id: ZStr, owner: ZStr, timestamp: ZNum }).strip();
const CollateralDepositedSchema = z.object({ vault_id: ZStr, amount: ZNum, depositor: ZStr, timestamp: ZNum }).strip();
const CollateralWithdrawnSchema = z.object({ vault_id: ZStr, amount: ZNum, withdrawer: ZStr, timestamp: ZNum }).strip();
const SyntheticMintedSchema = z.object({ vault_id: ZStr, synthetic_type: ZStr, amount_minted: ZNum, timestamp: ZNum }).strip();
const SyntheticBurnedSchema = z.object({ vault_id: ZStr, synthetic_type: ZStr, amount_burned: ZNum, timestamp: ZNum }).strip();
const StabilityAccruedSchema = z.object({ vault_id: ZStr, synthetic_type: ZStr, delta_units: ZNum, from_ms: ZNum, to_ms: ZNum }).strip();
const LiquidationExecutedSchema = z.object({ vault_id: ZStr, liquidator: ZStr, liquidated_amount: ZNum, collateral_seized: ZNum, liquidation_penalty: ZNum, synthetic_type: ZStr, timestamp: ZNum }).strip();
const ParamsUpdatedSchema = z.object({ updater: ZStr, timestamp: ZNum }).strip();
const PauseToggledSchema = z.object({ new_state: ZBool, by: ZStr, timestamp: ZNum }).strip();
const SyntheticAssetCreatedSchema = z.object({ asset_name: ZStr, asset_symbol: ZStr, decimals: ZNum.optional(), timestamp: ZNum }).strip();
const SyntheticAssetInfoCreatedSchema = z.object({ symbol: ZStr, timestamp: ZNum }).strip();

