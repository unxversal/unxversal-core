import { Router, Request, Response } from 'express';
import { Pool } from 'pg';
import { loadConfig } from '../../lib/config.js';
import { SuiClient } from '@mysten/sui/client';

export function oraclesRouter(_pool: Pool) {
  const r = Router();

  r.get('/synth/oracles', async (_req: Request, res: Response) => {
    const cfg = await loadConfig();
    res.json({ ok: true, aggregators: cfg?.synthetics?.aggregators ?? {} });
  });

  r.get('/synth/oracles/:symbol/price', async (req: Request, res: Response) => {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics?.aggregators) throw new Error('missing cfg');
      const sym = String((req.params as any)['symbol']);
      const aggId = (cfg.synthetics.aggregators as any)[sym]; if (!aggId) throw new Error('unknown symbol');
      const client = new SuiClient({ url: cfg.rpcUrl });
      const obj: any = await client.getObject({ id: aggId, options: { showContent: true } as any });
      const content = obj?.data?.content ?? obj?.content; const fields = content?.fields; const cr = fields?.current_result?.fields;
      const valueRaw = cr?.result?.fields?.value ?? cr?.result?.value; const minTs = cr?.min_timestamp_ms ?? cr?.fields?.min_timestamp_ms; const maxTs = cr?.max_timestamp_ms ?? cr?.fields?.max_timestamp_ms;
      const v = valueRaw == null ? null : Number(valueRaw);
      res.json({ ok: true, microPrice: v, minTimestampMs: Number(minTs ?? 0), maxTimestampMs: Number(maxTs ?? 0) });
    } catch (e: any) { res.status(400).json({ ok: false, error: String(e?.message || e) }); }
  });

  return r;
}


