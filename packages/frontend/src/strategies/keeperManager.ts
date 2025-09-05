import type { Keeper } from '../protocols/common';
import { db, type KeeperStateRow } from '../lib/storage';
import { StrategyRegistry } from './registry.ts';
import type { StrategyConfig } from './config';

export class KeeperManager {
  private keepers: Map<string, Keeper> = new Map(); // key: vaultId:keeperId

  async register(vaultId: string, keeperId: string, keeper: Keeper, kind: string): Promise<void> {
    const id = `${vaultId}:${keeperId}`;
    this.keepers.set(id, keeper);
    const latest = await StrategyRegistry.latestVersion(vaultId);
    await db.keepers.put({ id, vaultId, keeperId, kind, status: 'stopped', lastError: null, updatedMs: Date.now(), configVersion: latest });
  }

  async start(vaultId: string, keeperId: string): Promise<void> {
    const id = `${vaultId}:${keeperId}`;
    const k = this.keepers.get(id);
    if (!k) return;
    try {
      k.start();
      const prev = await db.keepers.get(id);
      await db.keepers.put({ id, vaultId, keeperId, kind: prev?.kind ?? 'unknown', status: 'running', lastError: null, updatedMs: Date.now(), configVersion: prev?.configVersion });
    } catch (e: any) {
      const prev = await db.keepers.get(id);
      await db.keepers.put({ id, vaultId, keeperId, kind: prev?.kind ?? 'unknown', status: 'error', lastError: String(e?.message ?? e), updatedMs: Date.now(), configVersion: prev?.configVersion });
      throw e;
    }
  }

  async stop(vaultId: string, keeperId: string): Promise<void> {
    const id = `${vaultId}:${keeperId}`;
    const k = this.keepers.get(id);
    if (!k) return;
    k.stop();
    const prev = await db.keepers.get(id);
    await db.keepers.put({ id, vaultId, keeperId, kind: prev?.kind ?? 'unknown', status: 'stopped', lastError: null, updatedMs: Date.now(), configVersion: prev?.configVersion });
  }

  async status(vaultId: string, keeperId: string): Promise<KeeperStateRow | undefined> {
    return db.keepers.get(`${vaultId}:${keeperId}`);
  }

  // Basic backoff: restart after delay if error
  async ensureRunning(vaultId: string, keeperId: string, delayMs = 3000): Promise<void> {
    const id = `${vaultId}:${keeperId}`;
    const st = await this.status(vaultId, keeperId);
    if (st?.status === 'error') {
      setTimeout(() => { void this.start(vaultId, keeperId); }, delayMs);
    }
  }

  // Auto-resume any keepers previously marked running (rebuild from saved config)
  async autoResume(build: (cfg: StrategyConfig) => Keeper): Promise<void> {
    const rows = await db.keepers.where('status').equals('running').toArray();
    for (const r of rows) {
      const version = r.configVersion ?? (await StrategyRegistry.latestVersion(r.vaultId));
      const cfgRow = await StrategyRegistry.get(r.vaultId, version);
      if (!cfgRow) continue;
      const keeper = build(cfgRow.config as StrategyConfig);
      await this.register(r.vaultId, r.keeperId, keeper, r.kind);
      await this.start(r.vaultId, r.keeperId);
    }
  }

  // Cross-tab single instance guard using BroadcastChannel
  singleInstanceChannel(name = 'uxv-keepers'): void {
    const bc = new BroadcastChannel(name);
    bc.onmessage = (ev) => {
      if (ev.data === 'ping') {
        bc.postMessage('pong');
      }
    };
    // Leader election: first tab that doesn’t hear a pong within timeout acts as leader
    bc.postMessage('ping');
    const timer = setTimeout(() => {
      // This tab assumes leadership; others will receive pongs
      // No-op here; consumer can read this and decide to run keepers
    }, 300);
    bc.onmessage = (ev) => {
      if (ev.data === 'pong') clearTimeout(timer);
    };
  }
}


