import { Router, Request, Response } from 'express';
import {Pool} from 'pg';
import {loadConfig, saveConfig, mergeConfig, type AppConfig} from '../../lib/config.js';

export function coreRouter(pool: Pool) {
  const r = Router();

  r.get('/health', async (_req: Request, res: Response) => {
    try { await pool.query('select 1'); res.json({ ok: true }); } catch { res.status(500).json({ ok: false }); }
  });

  r.get('/status', async (_req: Request, res: Response) => {
    const sx: any = (globalThis as any).__unxv_indexer;
    const lx: any = (globalThis as any).__unxv_lending_indexer;
    const lk: any = (globalThis as any).__unxv_lending_keeper;
    const srv: any = (globalThis as any).__unxv_server;
    res.json({
      ok: true,
      server: { port: srv?.port ?? null },
      syntheticsIndexer: sx ? sx.health?.() : null,
      lendingIndexer: lx ? lx.health?.() : null,
      lendingKeeper: !!lk,
    });
  });

  r.get('/config', async (_req: Request, res: Response) => {
    const cfg = await loadConfig();
    if (!cfg) return res.json({});
    const redacted: AppConfig = JSON.parse(JSON.stringify(cfg));
    if (redacted.wallet?.privateKey) redacted.wallet.privateKey = '***';
    return res.json(redacted);
  });

  r.put('/config', async (req: Request, res: Response) => {
    try {
      const current = (await loadConfig()) ?? ({} as any);
      const next = mergeConfig(current as any, req.body || {});
      await saveConfig(next);
      res.json({ ok: true });
    } catch (e: any) {
      res.status(400).json({ ok: false, error: String(e?.message || e) });
    }
  });

  r.post('/settings/wallet', async (req: Request, res: Response) => {
    try {
      const { address, privateKey } = req.body || {};
      const curr = (await loadConfig()) as any;
      const next = mergeConfig(curr, { wallet: { address, privateKey } } as any);
      await saveConfig(next);
      res.json({ ok: true });
    } catch (e: any) { res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.post('/settings/network', async (req: Request, res: Response) => {
    try {
      const { rpcUrl, network } = req.body || {};
      const curr = (await loadConfig()) as any;
      const next = mergeConfig(curr, { rpcUrl, network } as any);
      await saveConfig(next);
      res.json({ ok: true });
    } catch (e: any) { res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  return r;
}


