import { Router, Request, Response } from 'express';
import { Pool } from 'pg';
import { SyntheticsIndexer } from '../../synthetics/indexer.js';
import { LendingIndexer } from '../../lending/indexer.js';
import { loadConfig } from '../../lib/config.js';

export function indexerRouter(_pool: Pool) {
  const r = Router();

  // ---- Synthetics ----
  r.get('/indexer/synth/health', (_req: Request, res: Response) => {
    const sx: any = (globalThis as any).__unxv_indexer;
    res.json({ ok: true, health: sx ? sx.health?.() : null });
  });

  r.get('/indexer/synth/cursor', (_req: Request, res: Response) => {
    const sx: any = (globalThis as any).__unxv_indexer;
    res.json({ ok: true, cursor: sx?.health?.().cursor ?? null });
  });

  r.post('/indexer/synth/start', async (req: Request, res: Response) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics?.packageId) throw new Error('missing synthetics.packageId');
      let sx: any = (globalThis as any).__unxv_indexer;
      if (!sx) { sx = await SyntheticsIndexer.fromConfig(); await sx.init(); (globalThis as any).__unxv_indexer = sx; }
      const sinceMs = (req.body?.sinceMs as number | undefined) ?? (cfg.indexer.backfillSinceMs ?? Date.now());
      const types = (req.body?.types as string[] | undefined) ?? cfg.indexer.types;
      const windowDays = (req.body?.windowDays as number | undefined) ?? cfg.indexer.windowDays;
      void sx.backfillThenFollow(cfg.synthetics.packageId!, sinceMs, types, windowDays);
      res.json({ ok: true });
    } catch (e: any) { res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.post('/indexer/synth/stop', (_req: Request, res: Response) => {
    const sx: any = (globalThis as any).__unxv_indexer; if (sx) sx.stop?.();
    res.json({ ok: true });
  });

  r.post('/indexer/synth/backfill', async (req: Request, res: Response) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics?.packageId) throw new Error('missing synthetics.packageId');
      let sx: any = (globalThis as any).__unxv_indexer;
      if (!sx) { sx = await SyntheticsIndexer.fromConfig(); await sx.init(); (globalThis as any).__unxv_indexer = sx; }
      const sinceMs = Number(req.body?.sinceMs);
      const types = req.body?.types as string[] | undefined;
      const windowDays = Number(req.body?.windowDays ?? cfg.indexer.windowDays);
      void sx.backfillThenFollow(cfg.synthetics.packageId!, sinceMs, types, windowDays);
      res.json({ ok: true });
    } catch (e: any) { res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  // ---- Lending ----
  r.get('/indexer/lend/health', (_req: Request, res: Response) => {
    const lx: any = (globalThis as any).__unxv_lending_indexer;
    res.json({ ok: true, health: lx ? lx.health?.() : null });
  });

  r.get('/indexer/lend/cursor', (_req: Request, res: Response) => {
    const lx: any = (globalThis as any).__unxv_lending_indexer;
    res.json({ ok: true, cursor: lx?.health?.().cursor ?? null });
  });

  r.post('/indexer/lend/start', async (req: Request, res: Response) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing lending.packageId');
      let lx: any = (globalThis as any).__unxv_lending_indexer;
      if (!lx) { lx = await LendingIndexer.fromConfig(); await lx.init(); (globalThis as any).__unxv_lending_indexer = lx; }
      const sinceMs = (req.body?.sinceMs as number | undefined) ?? (cfg.indexer.backfillSinceMs ?? Date.now());
      void lx.backfillThenFollow(cfg.lending.packageId!, sinceMs);
      res.json({ ok: true });
    } catch (e: any) { res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  r.post('/indexer/lend/stop', (_req: Request, res: Response) => {
    const lx: any = (globalThis as any).__unxv_lending_indexer; if (lx) lx.stop?.();
    res.json({ ok: true });
  });

  r.post('/indexer/lend/backfill', async (req: Request, res: Response) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing lending.packageId');
      let lx: any = (globalThis as any).__unxv_lending_indexer;
      if (!lx) { lx = await LendingIndexer.fromConfig(); await lx.init(); (globalThis as any).__unxv_lending_indexer = lx; }
      const sinceMs = Number(req.body?.sinceMs);
      void lx.backfillThenFollow(cfg.lending.packageId!, sinceMs);
      res.json({ ok: true });
    } catch (e: any) { res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  return r;
}


