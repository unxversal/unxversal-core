import { Router, Request, Response } from 'express';
import {Pool} from 'pg';
import { loadConfig } from '../../lib/config.js';
import { Transaction } from '@mysten/sui/transactions';
import { SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import {
  PoolsQuery,
  LendingPoolRow,
  AccountBalancesQuery,
  LendingBalanceRow,
  LendFeesQuery,
  LendingFeeRow,
  TxOkResponse,
  SupplyBody,
  WithdrawLendBody,
  BorrowBody,
  RepayBody,
  LendingPoolDetailResponse,
} from '../../lending/types.js';

function signerFrom(pk?: string) { if (!pk) throw new Error('wallet.privateKey missing'); const raw = Buffer.from(pk,'base64'); return Ed25519Keypair.fromSecretKey(new Uint8Array(raw)); }
function reqString(v: any, name: string): string { if (typeof v !== 'string' || v.length === 0) throw new Error(`missing ${name}`); return v; }

export function lendingRouter(pool: Pool) {
  const r = Router();

  r.get('/pools', async (req: Request<{}, LendingPoolRow[], {}, PoolsQuery>, res: Response<LendingPoolRow[]>) => {
    const { asset, minTs, maxTs, limit } = req.query;
    let q = 'select * from lending_pools'; const args: any[] = []; const cond: string[] = [];
    if (asset) { cond.push(`asset = $${args.length+1}`); args.push(asset); }
    if (minTs) { cond.push(`last_update_ms >= $${args.length+1}`); args.push(Number(minTs)); }
    if (maxTs) { cond.push(`last_update_ms <= $${args.length+1}`); args.push(Number(maxTs)); }
    if (cond.length > 0) q += ' where ' + cond.join(' and ');
    const lim = Math.max(1, Math.min(1000, Number(limit ?? 200)));
    q += ` order by last_update_ms desc limit ${lim}`;
    const rows = await pool.query(q, args);
    return res.json(rows.rows as unknown as LendingPoolRow[]);
  });

  r.get('/pools/:poolId', async (req: Request<{ poolId: string }>, res: Response<LendingPoolDetailResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.postgresUrl) throw new Error('missing postgresUrl');
      const { poolId } = req.params; const rows = await pool.query('select * from lending_pools where pool_id=$1', [poolId]);
      if (rows.rowCount === 0) return res.status(404).json({ ok: false, error: 'pool not found' });
      const poolRow = rows.rows[0];
      // summarize balances across accounts for this asset
      const asset = poolRow.asset;
      const sum = await pool.query('select sum(supply_scaled) as total_supply_scaled, sum(borrow_scaled) as total_borrow_scaled from lending_balances where asset=$1', [asset]);
      return res.json({ ok: true, pool: poolRow as LendingPoolRow, totals: { totalSupplyScaled: Number(sum.rows[0]?.total_supply_scaled ?? 0), totalBorrowScaled: Number(sum.rows[0]?.total_borrow_scaled ?? 0) } });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.get('/accounts/:accountId', async (req: Request<{ accountId: string }, LendingBalanceRow[], {}, AccountBalancesQuery>, res: Response<LendingBalanceRow[]>) => {
    const { accountId } = req.params; const { asset } = req.query;
    if (asset) {
      const rows = await pool.query('select * from lending_balances where account_id=$1 and asset=$2', [accountId, asset]);
      return res.json(rows.rows as unknown as LendingBalanceRow[]);
    }
    const rows = await pool.query('select * from lending_balances where account_id=$1', [accountId]); return res.json(rows.rows as unknown as LendingBalanceRow[]);
  });

  r.get('/fees', async (req: Request<{}, LendingFeeRow[], {}, LendFeesQuery>, res: Response<LendingFeeRow[]>) => {
    const { asset, minTs, maxTs, limit } = req.query;
    let q = 'select * from lending_fees'; const args: any[] = []; const cond: string[] = [];
    if (asset) { cond.push(`asset = $${args.length+1}`); args.push(asset); }
    if (minTs) { cond.push(`timestamp_ms >= $${args.length+1}`); args.push(Number(minTs)); }
    if (maxTs) { cond.push(`timestamp_ms <= $${args.length+1}`); args.push(Number(maxTs)); }
    if (cond.length > 0) q += ' where ' + cond.join(' and ');
    const lim = Math.max(1, Math.min(1000, Number(limit ?? 200)));
    q += ` order by timestamp_ms desc limit ${lim}`;
    const rows = await pool.query(q, args); return res.json(rows.rows as unknown as LendingFeeRow[]);
  });

  // ---- Accounts/PTBs ----
  r.post('/accounts', async (_req: Request, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing lending.packageId');
      const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.lending.packageId}::lending::open_account`, arguments: [] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair, options: { showEffects: true } } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.post('/accounts/:accountId/supply', async (req: Request<{ accountId: string }, TxOkResponse, SupplyBody>, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing lending.packageId');
      const { accountId } = req.params; const { poolId, coinId, amount } = req.body || {};
      const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      const registryId = reqString(cfg.lending.registryId, 'lending.registryId');
      tx.moveCall({ target: `${cfg.lending.packageId}::lending::supply`, arguments: [ tx.object(registryId), tx.object(reqString(poolId,'poolId')), tx.object(reqString(accountId,'accountId')), tx.object(reqString(coinId,'coinId')), tx.pure.u64(BigInt(amount)), tx.object('0x6') ] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.post('/accounts/:accountId/withdraw', async (req: Request<{ accountId: string }, TxOkResponse, WithdrawLendBody>, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing lending.packageId');
      const { accountId } = req.params;
      const { poolId, amount, oracleRegistryId, oracleConfigId, priceSelfAggId, symbols, pricesSetId, supplyIdx, borrowIdx } = req.body || {};
      const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      const registryId = reqString(cfg.lending.registryId, 'lending.registryId');
      tx.moveCall({ target: `${cfg.lending.packageId}::lending::withdraw`, arguments: [ tx.object(registryId), tx.object(reqString(poolId,'poolId')), tx.object(reqString(accountId,'accountId')), tx.pure.u64(BigInt(amount)), tx.object(reqString(oracleRegistryId,'oracleRegistryId')), tx.object(reqString(oracleConfigId,'oracleConfigId')), tx.object('0x6'), tx.object(reqString(priceSelfAggId,'priceSelfAggId')), tx.makeMoveVec({ type: '0x1::string::String', elements: (symbols || []).map((s: string) => tx.pure.string(String(s))) }), tx.object(reqString(pricesSetId,'pricesSetId')), tx.makeMoveVec({ type: 'u64', elements: (supplyIdx || []).map((x: any) => tx.pure.u64(BigInt(x))) }), tx.makeMoveVec({ type: 'u64', elements: (borrowIdx || []).map((x: any) => tx.pure.u64(BigInt(x))) }) ] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.post('/accounts/:accountId/borrow', async (req: Request<{ accountId: string }, TxOkResponse, BorrowBody>, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing lending.packageId');
      const { accountId } = req.params;
      const { poolId, amount, oracleRegistryId, oracleConfigId, priceDebtAggId, symbols, pricesSetId, supplyIdx, borrowIdx } = req.body || {};
      const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      const registryId = reqString(cfg.lending.registryId, 'lending.registryId');
      tx.moveCall({ target: `${cfg.lending.packageId}::lending::borrow`, arguments: [ tx.object(registryId), tx.object(reqString(poolId,'poolId')), tx.object(reqString(accountId,'accountId')), tx.pure.u64(BigInt(amount)), tx.object(reqString(oracleRegistryId,'oracleRegistryId')), tx.object(reqString(oracleConfigId,'oracleConfigId')), tx.object('0x6'), tx.object(reqString(priceDebtAggId,'priceDebtAggId')), tx.makeMoveVec({ type: '0x1::string::String', elements: (symbols || []).map((s: string) => tx.pure.string(String(s))) }), tx.object(reqString(pricesSetId,'pricesSetId')), tx.makeMoveVec({ type: 'u64', elements: (supplyIdx || []).map((x: any) => tx.pure.u64(BigInt(x))) }), tx.makeMoveVec({ type: 'u64', elements: (borrowIdx || []).map((x: any) => tx.pure.u64(BigInt(x))) }) ] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.post('/accounts/:accountId/repay', async (req: Request<{ accountId: string }, TxOkResponse, RepayBody>, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing lending.packageId');
      const { accountId } = req.params; const { poolId, paymentCoinId } = req.body || {};
      const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      const registryId = reqString(cfg.lending.registryId, 'lending.registryId');
      tx.moveCall({ target: `${cfg.lending.packageId}::lending::repay`, arguments: [ tx.object(registryId), tx.object(reqString(poolId,'poolId')), tx.object(reqString(accountId,'accountId')), tx.object(reqString(paymentCoinId,'paymentCoinId')), tx.object('0x6') ] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  // ---- Data / analytics ----
  r.get('/events', async (req: Request, res: Response) => {
    const { type, minTs, maxTs, limit } = req.query as any;
    let q = 'select * from lending_events'; const args: any[] = []; const cond: string[] = [];
    if (type) { cond.push(`type = $${args.length+1}`); args.push(type); }
    if (minTs) { cond.push(`timestamp_ms >= $${args.length+1}`); args.push(Number(minTs)); }
    if (maxTs) { cond.push(`timestamp_ms <= $${args.length+1}`); args.push(Number(maxTs)); }
    if (cond.length > 0) q += ' where ' + cond.join(' and ');
    const lim = Math.max(1, Math.min(1000, Number(limit ?? 200)));
    q += ` order by timestamp_ms desc limit ${lim}`;
    const rows = await pool.query(q, args); res.json(rows.rows);
  });

  r.get('/candles/:asset', async (req: Request, res: Response) => {
    const { asset } = req.params; const { bucket = 'minute', limit = 300 } = req.query as any;
    const allowed = new Set(['minute','hour','day']); const b = allowed.has(String(bucket)) ? String(bucket) : 'minute';
    const lim = Math.max(1, Math.min(2000, Number(limit)));
    const rows = await pool.query(`select date_trunc($1, to_timestamp(timestamp_ms/1000)) as bucket, sum(amount) as volume from lending_fees where asset = $2 group by 1 order by 1 desc limit $3`, [b, asset, lim]);
    res.json(rows.rows.map((row: any) => ({ t: row.bucket, v: Number(row.volume) })));
  });

  r.post('/pools/:poolId/update-rates', async (req: Request, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing cfg.lending');
      const { poolId } = req.params; const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      const registryId = reqString(cfg.lending.registryId, 'lending.registryId');
      tx.moveCall({ target: `${cfg.lending.packageId}::lending::update_pool_rates`, arguments: [ tx.object(registryId), tx.object(reqString(poolId,'poolId')), tx.object('0x6') ] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.post('/pools/:poolId/accrue', async (req: Request, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing cfg.lending');
      const { poolId } = req.params; const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      const registryId = reqString(cfg.lending.registryId, 'lending.registryId');
      tx.moveCall({ target: `${cfg.lending.packageId}::lending::accrue_pool_interest`, arguments: [ tx.object(registryId), tx.object(reqString(poolId,'poolId')), tx.object('0x6') ] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  // Account operations via server can be added later; supply/borrow/repay are typically client-side PTBs.

  return r;
}


