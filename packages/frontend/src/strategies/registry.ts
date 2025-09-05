import { db, type StrategyConfigRow } from '../lib/storage';
import type { StrategyConfig } from './config';

export class StrategyRegistry {
  static async save(vaultId: string, cfg: StrategyConfig, version?: number): Promise<StrategyConfigRow> {
    const createdMs = Date.now();
    const json = JSON.stringify(cfg);
    const hash = await sha256(json);
    const ver = version ?? (await StrategyRegistry.latestVersion(vaultId)) + 1;
    const row: StrategyConfigRow = {
      id: `${vaultId}:${ver}`,
      vaultId,
      version: ver,
      kind: cfg.kind,
      createdMs,
      hash,
      config: cfg,
      active: true,
    };
    await db.configs.put(row);
    return row;
  }

  static async get(vaultId: string, version: number): Promise<StrategyConfigRow | undefined> {
    return db.configs.get({ id: `${vaultId}:${version}` } as any);
  }

  static async latestVersion(vaultId: string): Promise<number> {
    const rows = await db.configs.where('vaultId').equals(vaultId).toArray();
    if (!rows.length) return 0;
    return rows.reduce((m, r) => Math.max(m, r.version), 0);
  }

  static async list(vaultId: string): Promise<StrategyConfigRow[]> {
    return db.configs.where('vaultId').equals(vaultId).reverse().sortBy('version');
  }
}

async function sha256(input: string): Promise<string> {
  const enc = new TextEncoder().encode(input);
  const buf = await crypto.subtle.digest('SHA-256', enc);
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
}


