import { Router, Request, Response } from 'express';
import { Pool } from 'pg';
import { loadConfig } from '../../lib/config.js';
import { Transaction } from '@mysten/sui/transactions';
import { SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import {
  VaultDetailResponse,
  PlaceOrderBody,
  ModifyOrderBody,
  CancelOrderBody,
  ClaimOrderBody,
  CreateVaultBody,
  DepositBody,
  WithdrawBody,
  MintBody,
  BurnBody,
  LiquidateBody,
  TxOkResponse,
} from '../../synthetics/types.js';

function signerFrom(pk?: string) { if (!pk) throw new Error('wallet.privateKey missing'); const raw = Buffer.from(pk,'base64'); return Ed25519Keypair.fromSecretKey(new Uint8Array(raw)); }

export function synthOrdersVaultsRouter(pool: Pool) {
  const r = Router();

  // ---- Vault detail ----
  r.get('/synth/vaults/:id', async (req: Request<{ id: string }>, res: Response<VaultDetailResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.postgresUrl) throw new Error('missing postgresUrl');
      const { id } = req.params;
      const vq = await pool.query('select vault_id, owner, last_update_ms, collateral from vaults where vault_id=$1', [id]);
      if (vq.rowCount === 0) return res.status(404).json({ ok: false, error: 'vault not found' });
      const vault = vq.rows[0];
      const dq = await pool.query('select symbol, units from vault_debts where vault_id=$1 and units > 0', [id]);
      const client = new SuiClient({ url: cfg.rpcUrl });
      const debts = [] as any[];
      let totalDebtValueMicro = 0;
      for (const row of dq.rows) {
        const symbol = String(row.symbol);
        const units = Number(row.units);
        const aggId = cfg.synthetics.aggregators?.[symbol as any];
        let priceMicro: number | null = null;
        if (aggId) {
          try {
            const obj: any = await client.getObject({ id: aggId, options: { showContent: true } as any });
            const content = obj?.data?.content ?? obj?.content; const fields = content?.fields; const cr = fields?.current_result?.fields;
            const valueRaw = cr?.result?.fields?.value ?? cr?.result?.value; const neg = cr?.result?.fields?.neg ?? cr?.result?.neg;
            if (!neg && valueRaw != null) priceMicro = Number(String(valueRaw));
          } catch {}
        }
        const valueMicro = priceMicro != null ? Math.floor(units * priceMicro) : null;
        if (typeof valueMicro === 'number') totalDebtValueMicro += valueMicro;
        debts.push({ symbol, units, priceMicro, valueMicro });
      }
      // Optional collateral price (if configured as '__collateral' aggregator)
      let collateralPriceMicro: number | null = null;
      const collateralAgg = (cfg.synthetics.aggregators as any)?.['__collateral'];
      if (collateralAgg) {
        try {
          const obj: any = await client.getObject({ id: collateralAgg, options: { showContent: true } as any });
          const content = obj?.data?.content ?? obj?.content; const fields = content?.fields; const cr = fields?.current_result?.fields;
          const valueRaw = cr?.result?.fields?.value ?? cr?.result?.value; const neg = cr?.result?.fields?.neg ?? cr?.result?.neg;
          if (!neg && valueRaw != null) collateralPriceMicro = Number(String(valueRaw));
        } catch {}
      }
      const collateralUnits = Number(vault.collateral ?? 0);
      const collateralValueMicro = collateralPriceMicro != null ? Math.floor(collateralUnits * collateralPriceMicro) : null;
      const ratio = collateralValueMicro != null && totalDebtValueMicro > 0 ? (collateralValueMicro / totalDebtValueMicro) : null;
      return res.json({ ok: true, vault: { id: vault.vault_id, owner: vault.owner, last_update_ms: Number(vault.last_update_ms), collateralUnits }, debts, totals: { totalDebtValueMicro }, collateralPriceMicro, collateralValueMicro, ratio });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  // ---- Orders ----
  r.post('/synth/orders', async (req: Request<{}, TxOkResponse, PlaceOrderBody>, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics?.packageId) throw new Error('missing cfg');
      const { symbol, takerIsBid, price, size, expiryMs, marketId, escrowId, registryId, vaultId, treasuryId } = req.body || {};
      const keypair = signerFrom(cfg.wallet.privateKey);
      const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      tx.moveCall({
        target: `${cfg.synthetics.packageId}::synthetics::place_synth_limit_with_escrow`,
        arguments: [
          tx.object(String(registryId)),
          tx.object(String(marketId)),
          tx.object(String(escrowId)),
          tx.object('0x6'),
          tx.object(String(cfg.synthetics.oracleConfigId! as unknown as string)),
          tx.object(String((cfg.synthetics.aggregators as any)[String(symbol)])),
          tx.object(String(cfg.synthetics.unxvAggregatorId! as unknown as string)),
          tx.pure.bool(!!takerIsBid),
          tx.pure.u64(BigInt(String(price))),
          tx.pure.u64(BigInt(String(size))),
          tx.pure.u64(BigInt(expiryMs ?? (Date.now() + 3600_000))),
          tx.object(String(vaultId)),
          tx.makeMoveVec({ type: `${cfg.synthetics.packageId}::unxv::UNXV`, elements: [] }),
          tx.object(String(treasuryId)),
        ],
        typeArguments: [cfg.synthetics.collateralType!],
      });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.post('/synth/orders/:orderId/modify', async (req: Request<{ orderId: string }, TxOkResponse, ModifyOrderBody>, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics?.packageId) throw new Error('missing cfg');
      const { orderId } = req.params;
      const { newQty, nowMs, registryId, marketId, escrowId, vaultId } = req.body || {};
      const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.synthetics.packageId}::synthetics::modify_synth_clob`, arguments: [ tx.object(String(registryId)), tx.object(String(marketId)), tx.object(String(escrowId)), tx.pure.u128(String(orderId)), tx.pure.u64(BigInt(String(newQty))), tx.pure.u64(BigInt(nowMs ?? Date.now())), tx.object(String(vaultId)) ], typeArguments: [cfg.synthetics.collateralType!] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.post('/synth/orders/:orderId/cancel', async (req: Request<{ orderId: string }, TxOkResponse, CancelOrderBody>, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics?.packageId) throw new Error('missing cfg');
      const { orderId } = req.params; const { marketId, escrowId, vaultId } = req.body || {};
      const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.synthetics.packageId}::synthetics::cancel_synth_clob_with_escrow`, arguments: [ tx.object(String(marketId)), tx.object(String(escrowId)), tx.pure.u128(String(orderId)), tx.object(String(vaultId)) ], typeArguments: [cfg.synthetics.collateralType!] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.post('/synth/orders/:orderId/claim', async (req: Request<{ orderId: string }, TxOkResponse, ClaimOrderBody>, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics?.packageId) throw new Error('missing cfg');
      const { orderId } = req.params; const { registryId, marketId, escrowId, vaultId } = req.body || {};
      const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.synthetics.packageId}::synthetics::claim_maker_fills`, arguments: [ tx.object(String(registryId)), tx.object(String(marketId)), tx.object(String(escrowId)), tx.pure.u128(String(orderId)), tx.object(String(vaultId)) ], typeArguments: [cfg.synthetics.collateralType!] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  // ---- Vaults ----
  r.post('/synth/vaults', async (req: Request<{}, TxOkResponse, CreateVaultBody>, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics?.packageId) throw new Error('missing cfg');
      const { collateralCfgId, registryId } = req.body || {};
      const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.synthetics.packageId}::synthetics::create_vault`, arguments: [ tx.object(String(collateralCfgId)), tx.object(String(registryId)) ], typeArguments: [cfg.synthetics.collateralType!] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair, options: { showEffects: true } } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.post('/synth/vaults/:id/deposit', async (req: Request<{ id: string }, TxOkResponse, DepositBody>, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics?.packageId) throw new Error('missing cfg');
      const { id } = req.params; const { coinId } = req.body || {};
      const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.synthetics.packageId}::synthetics::deposit_collateral`, arguments: [ tx.object(String(id)), tx.object(String(coinId)) ], typeArguments: [cfg.synthetics.collateralType!] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
    return res.end();
  });

  r.post('/synth/vaults/:id/withdraw', async (req: Request<{ id: string }, TxOkResponse, WithdrawBody>, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics?.packageId) throw new Error('missing cfg');
      const { id } = req.params; const { amount, symbol, priceObj } = req.body || {};
      const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.synthetics.packageId}::synthetics::withdraw_collateral`, arguments: [ tx.object(String(cfg.synthetics.collateralCfgId! as unknown as string)), tx.object(String(id)), tx.object(String(cfg.synthetics.registryId!)), tx.object('0x6'), tx.object(String(cfg.synthetics.oracleConfigId! as unknown as string)), tx.object(String(priceObj)), tx.pure.string(String(symbol)), tx.pure.u64(BigInt(String(amount))) ], typeArguments: [cfg.synthetics.collateralType!] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
    return res.end();
  });

  r.post('/synth/vaults/:id/mint', async (req: Request<{ id: string }, TxOkResponse, MintBody>, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics?.packageId) throw new Error('missing cfg');
      const { id } = req.params; const { symbol, amount, priceObj, unxvPriceObj, treasuryId, unxvCoins } = req.body || {};
      const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      const vecUNXV = tx.makeMoveVec({ type: `${cfg.synthetics.packageId}::unxv::UNXV`, elements: (unxvCoins ?? []).map((cid: string) => tx.object(String(cid))) });
      tx.moveCall({ target: `${cfg.synthetics.packageId}::synthetics::mint_synthetic`, arguments: [ tx.object(String(cfg.synthetics.collateralCfgId! as unknown as string)), tx.object(String(id)), tx.object(String(cfg.synthetics.registryId!)), tx.object('0x6'), tx.object(String(cfg.synthetics.oracleConfigId! as unknown as string)), tx.object(String(priceObj)), tx.pure.string(String(symbol)), tx.pure.u64(BigInt(String(amount))), vecUNXV, tx.object(String(unxvPriceObj)), tx.object(String(treasuryId)) ], typeArguments: [cfg.synthetics.collateralType!] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
    return res.end();
  });

  r.post('/synth/vaults/:id/burn', async (req: Request<{ id: string }, TxOkResponse, BurnBody>, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics?.packageId) throw new Error('missing cfg');
      const { id } = req.params; const { symbol, amount, priceObj, unxvPriceObj, treasuryId, unxvCoins } = req.body || {};
      const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      const vecUNXV = tx.makeMoveVec({ type: `${cfg.synthetics.packageId}::unxv::UNXV`, elements: (unxvCoins ?? []).map((cid: string) => tx.object(String(cid))) });
      tx.moveCall({ target: `${cfg.synthetics.packageId}::synthetics::burn_synthetic`, arguments: [ tx.object(String(cfg.synthetics.collateralCfgId! as unknown as string)), tx.object(String(id)), tx.object(String(cfg.synthetics.registryId!)), tx.object('0x6'), tx.object(String(cfg.synthetics.oracleConfigId! as unknown as string)), tx.object(String(priceObj)), tx.pure.string(String(symbol)), tx.pure.u64(BigInt(String(amount))), vecUNXV, tx.object(String(unxvPriceObj)), tx.object(String(treasuryId)) ], typeArguments: [cfg.synthetics.collateralType!] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
    return res.end();
  });

  r.post('/synth/vaults/:id/liquidate', async (req: Request<{ id: string }, TxOkResponse, LiquidateBody>, res: Response<TxOkResponse | { ok: false; error: string }>) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics?.packageId) throw new Error('missing cfg');
      const { id } = req.params; const { symbol, repay } = req.body || {};
      const aggId = (cfg.synthetics.aggregators as any)[String(symbol)]; if (!aggId) throw new Error('unknown symbol');
      const keypair = signerFrom(cfg.wallet.privateKey); const client = new SuiClient({ url: cfg.rpcUrl });
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.synthetics.packageId}::synthetics::liquidate_vault`, arguments: [ tx.object(String(cfg.synthetics.registryId!)), tx.object('0x6'), tx.object(String(cfg.synthetics.oracleConfigId! as unknown as string)), tx.object(String(aggId as unknown as string)), tx.object(String(id)), tx.pure.string(String(symbol)), tx.pure.u64(BigInt(repay ?? 1)), tx.pure.address((String(cfg.wallet.address || '0x0') as any)), tx.object(String(cfg.synthetics.treasuryId!)) ], typeArguments: [cfg.synthetics.collateralType!] });
      const out = await client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      return res.json({ ok: true, txDigest: out.digest });
    } catch (e: any) { return res.status(400).json({ ok: false, error: String(e?.message || e) }); }
    return res.end();
  });

  return r;
}


