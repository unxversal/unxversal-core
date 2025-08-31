import { Router, Request, Response } from 'express';
import { Pool } from 'pg';
import { SyntheticsKeeper } from '../../synthetics/keeper.js';
import { LendingKeeper } from '../../lending/keeper.js';
import { loadConfig, mergeConfig, saveConfig } from '../../lib/config.js';

export function botsRouter(_pool: Pool) {
  const r = Router();

  // ---- Synthetics ----
  r.get('/bots/synth/health', (_req: Request, res: Response) => {
    const kk: any = (globalThis as any).__unxv_synth_keeper;
    res.json({ ok: true, running: !!kk });
  });

  r.post('/bots/synth/start', async (_req: Request, res: Response) => {
    try {
      let kk: any = (globalThis as any).__unxv_synth_keeper;
      if (!kk) {
        kk = await SyntheticsKeeper.fromConfig();
        (globalThis as any).__unxv_synth_keeper = kk;
      }
      kk.start();
      res.json({ ok: true });
    } catch (e: any) { res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.post('/bots/synth/stop', (_req: Request, res: Response) => {
    const kk: any = (globalThis as any).__unxv_synth_keeper; if (kk) kk.stop?.();
    res.json({ ok: true });
  });

  r.patch('/bots/synth/config', async (req: Request, res: Response) => {
    try {
      const curr = await loadConfig(); if (!curr) throw new Error('no config');
      const next = mergeConfig(curr, { keeper: req.body || {} } as any);
      await saveConfig(next);
      // restart keeper to pick up new intervals
      const kk: any = (globalThis as any).__unxv_synth_keeper;
      if (kk) { kk.stop(); kk.start(); }
      res.json({ ok: true });
    } catch (e: any) { res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  // ---- Lending ----
  r.get('/bots/lend/health', (_req: Request, res: Response) => {
    const kk: any = (globalThis as any).__unxv_lending_keeper;
    res.json({ ok: true, running: !!kk });
  });

  r.post('/bots/lend/start', async (req: Request, res: Response) => {
    try {
      let kk: any = (globalThis as any).__unxv_lending_keeper;
      if (!kk) {
        kk = await LendingKeeper.fromConfig();
        (globalThis as any).__unxv_lending_keeper = kk;
      }
      const intervalMs = Number(req.body?.intervalMs ?? 15000);
      kk.start(intervalMs);
      res.json({ ok: true });
    } catch (e: any) { res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.post('/bots/lend/stop', (_req: Request, res: Response) => {
    const kk: any = (globalThis as any).__unxv_lending_keeper; if (kk) kk.stop?.();
    res.json({ ok: true });
  });

  return r;
}


