import { Router, Request, Response } from 'express';
import {Pool} from 'pg';
import { loadConfig } from '../../lib/config.js';
import { Transaction } from '@mysten/sui/transactions';
import { SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import {
  SynthOrdersQuery,
  VaultsQuery,
  LiquidationsQuery,
  FeesQuery,
  RebatesQuery,
  EventsQuery,
  CandlesQuery,
  MatchMarketBody,
  GcMarketBody,
  MarketsMap,
  OrderRow,
  VaultRow,
  LiquidationRow,
  FeeRow,
  RebateRow,
  CandlePoint,
  OkResponse,
  TxOkResponse,
} from '../../synthetics/types.js';

function signerFrom(pk?: string) { if (!pk) throw new Error('wallet.privateKey missing'); const raw = Buffer.from(pk,'base64'); return Ed25519Keypair.fromSecretKey(new Uint8Array(raw)); }

export function synthRouter(pool: Pool) {
  const r = Router();

  // Data endpoints
  r.get('/orders', async (req: Request<{}, OrderRow[], {}, SynthOrdersQuery>, res: Response<OrderRow[]>) => {
    const { symbol, status, owner, minTs, maxTs, limit } = req.query;
    let q = 'select * from orders'; const args: any[] = [];
    const cond: string[] = [];
    if (symbol) { cond.push(`symbol = $${args.length+1}`); args.push(symbol); }
    if (status) { cond.push(`status = $${args.length+1}`); args.push(status); }
    if (owner) { cond.push(`owner = $${args.length+1}`); args.push(owner); }
    if (minTs) { cond.push(`created_at_ms >= $${args.length+1}`); args.push(Number(minTs)); }
    if (maxTs) { cond.push(`created_at_ms <= $${args.length+1}`); args.push(Number(maxTs)); }
    if (cond.length > 0) q += ' where ' + cond.join(' and ');
    const lim = Math.max(1, Math.min(1000, Number(limit ?? 200)));
    q += ` order by created_at_ms desc limit ${lim}`;
    const rdb = await pool.query(q, args);
    return res.json(rdb.rows as unknown as OrderRow[]);
  });

  r.get('/vaults', async (req: Request<{}, VaultRow[], {}, VaultsQuery>, res: Response<VaultRow[]>) => {
    const { owner, minTs, maxTs, limit } = req.query;
    let q = 'select * from vaults'; const args: any[] = []; const cond: string[] = [];
    if (owner) { cond.push(`owner = $${args.length+1}`); args.push(owner); }
    if (minTs) { cond.push(`last_update_ms >= $${args.length+1}`); args.push(Number(minTs)); }
    if (maxTs) { cond.push(`last_update_ms <= $${args.length+1}`); args.push(Number(maxTs)); }
    if (cond.length > 0) q += ' where ' + cond.join(' and ');
    const lim = Math.max(1, Math.min(1000, Number(limit ?? 200)));
    q += ` order by last_update_ms desc limit ${lim}`;
    const rdb = await pool.query(q, args);
    return res.json(rdb.rows as unknown as VaultRow[]);
  });

  r.get('/liquidations', async (req: Request<{}, LiquidationRow[], {}, LiquidationsQuery>, res: Response<LiquidationRow[]>) => {
    const { vaultId, symbol, liquidator, minTs, maxTs, limit } = req.query;
    let q = 'select * from liquidations'; const args: any[] = []; const cond: string[] = [];
    if (vaultId) { cond.push(`vault_id = $${args.length+1}`); args.push(vaultId); }
    if (symbol) { cond.push(`synthetic_type = $${args.length+1}`); args.push(symbol); }
    if (liquidator) { cond.push(`liquidator = $${args.length+1}`); args.push(liquidator); }
    if (minTs) { cond.push(`timestamp_ms >= $${args.length+1}`); args.push(Number(minTs)); }
    if (maxTs) { cond.push(`timestamp_ms <= $${args.length+1}`); args.push(Number(maxTs)); }
    if (cond.length > 0) q += ' where ' + cond.join(' and ');
    const lim = Math.max(1, Math.min(1000, Number(limit ?? 200)));
    q += ` order by timestamp_ms desc limit ${lim}`;
    const rdb = await pool.query(q, args);
    return res.json(rdb.rows as unknown as LiquidationRow[]);
  });

  r.get('/fees', async (req: Request<{}, FeeRow[], {}, FeesQuery>, res: Response<FeeRow[]>) => {
    const { market, payer, reason, minTs, maxTs, limit } = req.query;
    let q = 'select * from fees'; const args: any[] = []; const cond: string[] = [];
    if (market) { cond.push(`market = $${args.length+1}`); args.push(market); }
    if (payer) { cond.push(`payer = $${args.length+1}`); args.push(payer); }
    if (reason) { cond.push(`reason = $${args.length+1}`); args.push(reason); }
    if (minTs) { cond.push(`timestamp_ms >= $${args.length+1}`); args.push(Number(minTs)); }
    if (maxTs) { cond.push(`timestamp_ms <= $${args.length+1}`); args.push(Number(maxTs)); }
    if (cond.length > 0) q += ' where ' + cond.join(' and ');
    const lim = Math.max(1, Math.min(1000, Number(limit ?? 200)));
    q += ` order by timestamp_ms desc limit ${lim}`;
    const rdb = await pool.query(q, args);
    return res.json(rdb.rows as unknown as FeeRow[]);
  });

  r.get('/rebates', async (req: Request<{}, RebateRow[], {}, RebatesQuery>, res: Response<RebateRow[]>) => {
    const { market, taker, maker, minTs, maxTs, limit } = req.query;
    let q = 'select * from rebates'; const args: any[] = []; const cond: string[] = [];
    if (market) { cond.push(`market = $${args.length+1}`); args.push(market); }
    if (taker) { cond.push(`taker = $${args.length+1}`); args.push(taker); }
    if (maker) { cond.push(`maker = $${args.length+1}`); args.push(maker); }
    if (minTs) { cond.push(`timestamp_ms >= $${args.length+1}`); args.push(Number(minTs)); }
    if (maxTs) { cond.push(`timestamp_ms <= $${args.length+1}`); args.push(Number(maxTs)); }
    if (cond.length > 0) q += ' where ' + cond.join(' and ');
    const lim = Math.max(1, Math.min(1000, Number(limit ?? 200)));
    q += ` order by timestamp_ms desc limit ${lim}`;
    const rdb = await pool.query(q, args);
    return res.json(rdb.rows as unknown as RebateRow[]);
  });

  r.get('/candles/:market', async (req: Request<{ market: string }, CandlePoint[], {}, CandlesQuery>, res: Response<CandlePoint[]>) => {
    const { market } = req.params; const { bucket = 'minute', limit = '300' } = req.query;
    const allowed = new Set(['minute','hour','day']); const b = allowed.has(String(bucket)) ? String(bucket) : 'minute';
    const lim = Math.max(1, Math.min(2000, Number(limit ?? '300')));
    const rdb = await pool.query(
      `select date_trunc($1, to_timestamp(timestamp_ms/1000)) as bucket, sum(amount) as volume from fees where market = $2 group by 1 order by 1 desc limit $3`,
      [b, market, lim]
    );
    return res.json(rdb.rows.map((row: any) => ({ t: row.bucket, v: Number(row.volume) })) as CandlePoint[]);
  });

  // Keeper actions
  r.post('/markets/:symbol/match', async (req: Request<{ symbol: string }, {}, MatchMarketBody>, res: Response<OkResponse | TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics?.packageId) throw new Error('missing cfg');
      const symbol = String((req.params as any)['symbol']);
      const { maxSteps = 3, priceBandBps } = req.body || {};
      const market = (cfg.synthetics.markets as any)[symbol]; if (!market) throw new Error('unknown symbol');
      const keypair = signerFrom(cfg.wallet.privateKey);
      const client = new SuiClient({ url: cfg.rpcUrl });
      // compute simple band if priceBandBps provided
      let minPx = 0n; let maxPx = 18_446_744_073_709_551_615n;
      try {
        const bps = BigInt(priceBandBps ?? cfg.keeper.priceBandBps ?? 0);
        if (bps > 0n) {
          const aggId = cfg.synthetics.aggregators?.[symbol as any];
          if (aggId) {
            const obj: any = await client.getObject({ id: aggId, options: { showContent: true } as any });
            const content = obj?.data?.content ?? obj?.content; const fields = content?.fields; const cr = fields?.current_result?.fields;
            const valueRaw = cr?.result?.fields?.value ?? cr?.result?.value; const neg = cr?.result?.fields?.neg ?? cr?.result?.neg;
            if (!neg && valueRaw != null) {
              const px = BigInt(String(valueRaw)); const band = (px * bps) / 10_000n; minPx = px > band ? (px - band) : 0n; maxPx = px + band;
            }
          }
        }
      } catch {}
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.synthetics.packageId}::synthetics::match_step_auto_with_points`, arguments: [ tx.object(cfg.synthetics.botPointsId!), tx.object('0x6'), tx.object(cfg.synthetics.registryId!), tx.object(market.marketId), tx.pure.u64(BigInt(maxSteps)), tx.pure.u64(minPx), tx.pure.u64(maxPx) ] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.post('/markets/:symbol/gc', async (req: Request<{ symbol: string }, {}, GcMarketBody>, res: Response<OkResponse | TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics?.packageId) throw new Error('missing cfg');
      const symbol = String((req.params as any)['symbol']); const { maxRemovals = cfg.keeper.gcMaxRemovals } = req.body || {};
      const market = (cfg.synthetics.markets as any)[symbol]; if (!market) throw new Error('unknown symbol');
      const keypair = signerFrom(cfg.wallet.privateKey);
      const client = new SuiClient({ url: cfg.rpcUrl });
      const now = BigInt(Date.now());
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.synthetics.packageId}::synthetics::gc_step_with_points`, arguments: [ tx.object(cfg.synthetics.registryId!), tx.object(market.marketId), tx.object(market.escrowId), tx.object(cfg.synthetics.treasuryId!), tx.pure.u64(now), tx.pure.u64(BigInt(maxRemovals)) ], typeArguments: [cfg.synthetics.collateralType!] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  // Markets listing from config
  r.get('/markets', async (_req: Request, res: Response<{ ok: boolean; markets: MarketsMap }>) => {
    const cfg = await loadConfig();
    const markets = cfg?.synthetics?.markets ?? {};
    return res.json({ ok: true, markets: markets as unknown as MarketsMap });
  });

  r.get('/markets/:symbol', async (req: Request<{ symbol: string }>, res: Response<{ ok: true; market: { marketId: string; escrowId: string } } | { ok: false; error: string }>) => {
    const cfg = await loadConfig(); const symbol = String((req.params as any)['symbol']);
    const m = (cfg?.synthetics?.markets as any)?.[symbol];
    if (!m) return res.status(404).json({ ok: false, error: 'unknown symbol' });
    return res.json({ ok: true, market: m });
  });

  // Events
  r.get('/events', async (req: Request<{}, any[], {}, EventsQuery>, res: Response<any[]>) => {
    const { type, minTs, maxTs, limit } = req.query;
    let q = 'select * from synthetic_events'; const args: any[] = []; const cond: string[] = [];
    if (type) { cond.push(`type = $${args.length+1}`); args.push(type); }
    if (minTs) { cond.push(`timestamp_ms >= $${args.length+1}`); args.push(Number(minTs)); }
    if (maxTs) { cond.push(`timestamp_ms <= $${args.length+1}`); args.push(Number(maxTs)); }
    if (cond.length > 0) q += ' where ' + cond.join(' and ');
    const lim = Math.max(1, Math.min(1000, Number(limit ?? 200)));
    q += ` order by timestamp_ms desc limit ${lim}`;
    const rdb = await pool.query(q, args);
    return res.json(rdb.rows as any[]);
  });

  // Orders (place/modify/cancel/claim) could be added similarly; for brevity, focus on core keeper flows here.

  return r;
}


