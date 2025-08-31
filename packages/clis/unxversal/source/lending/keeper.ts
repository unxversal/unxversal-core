import {SuiClient, getFullnodeUrl} from '@mysten/sui/client';
import {Transaction} from '@mysten/sui/transactions';
import {Ed25519Keypair} from '@mysten/sui/keypairs/ed25519';
import {loadConfig} from '../lib/config.js';
import {Pool} from 'pg';

export class LendingKeeper {
  private client: SuiClient;
  private running = false;
  private timer: NodeJS.Timeout | null = null;
  private db: Pool | null = null;

  constructor(client: SuiClient) { this.client = client; }

  static async fromConfig() { const cfg = await loadConfig(); if (!cfg) throw new Error('No config'); return new LendingKeeper(new SuiClient({ url: cfg.rpcUrl || getFullnodeUrl('testnet') })); }

  start(intervalMs = 10_000) {
    this.stop();
    this.running = true;
    this.timer = setInterval(() => { if (this.running) void this.tick().catch(() => {}); }, intervalMs);
  }

  stop() { if (this.timer) { clearInterval(this.timer); this.timer = null; } this.running = false; }

  private async tick() {
    const cfg = await loadConfig(); if (!cfg?.lending?.packageId) return;
    const keypair = this.getSignerFromConfig()(cfg.wallet.privateKey);
    // DB-driven: fetch pools that need rate updates or accrual (based on last_update_ms)
    const pools = await this.getStalePools().catch(() => [] as { pool_id: string }[]);
    for (const p of pools) {
      try {
        const tx = new Transaction();
        tx.moveCall({ target: `${cfg.lending.packageId}::lending::update_pool_rates`, arguments: [tx.object(cfg.lending.registryId!), tx.object(p.pool_id), tx.object('0x6')] });
        await this.client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      } catch {}
      try {
        const tx = new Transaction();
        tx.moveCall({ target: `${cfg.lending.packageId}::lending::accrue_pool_interest`, arguments: [tx.object(cfg.lending.registryId!), tx.object(p.pool_id), tx.object('0x6')] });
        await this.client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      } catch {}
    }
  }

  private getSignerFromConfig() {
    return (cfgKey: string | undefined) => { if (!cfgKey) throw new Error('wallet.privateKey missing'); const raw = Buffer.from(cfgKey, 'base64'); return Ed25519Keypair.fromSecretKey(new Uint8Array(raw)); };
  }

  private async getDb(): Promise<Pool> {
    const cfg = await loadConfig(); if (!cfg?.postgresUrl) throw new Error('postgresUrl missing'); if (!this.db) this.db = new Pool({ connectionString: cfg.postgresUrl }); return this.db;
  }

  private async getStalePools(limit = 50): Promise<{ pool_id: string }[]> {
    const db = await this.getDb();
    const res = await db.query(`select pool_id from lending_pools order by coalesce(last_update_ms,0) asc limit $1`, [limit]);
    return res.rows.map(r => ({ pool_id: String(r.pool_id) }));
  }
}


