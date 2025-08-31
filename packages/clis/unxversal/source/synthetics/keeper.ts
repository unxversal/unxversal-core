import {SuiClient, getFullnodeUrl} from '@mysten/sui/client';
import {Transaction} from '@mysten/sui/transactions';
import {Ed25519Keypair} from '@mysten/sui/keypairs/ed25519';
import {loadConfig} from '../lib/config.js';
import {Pool} from 'pg';

export class SyntheticsKeeper {
  private client: SuiClient;
  private timer: NodeJS.Timeout | null = null;
  private running = false;
  private oracleCache: Map<string, { v: bigint; t: number }> = new Map();
  private dbPool: Pool | null = null;
  private matchTimer: NodeJS.Timeout | null = null;
  private gcTimer: NodeJS.Timeout | null = null;
  private accrueTimer: NodeJS.Timeout | null = null;
  private liqTimer: NodeJS.Timeout | null = null;

  constructor(client: SuiClient) {
    this.client = client;
  }

  static async fromConfig() {
    const cfg = await loadConfig();
    if (!cfg) throw new Error('No config found; run settings first.');
    return new SyntheticsKeeper(new SuiClient({ url: cfg.rpcUrl || getFullnodeUrl('testnet') }));
  }

  start(_intervalMs = 5_000) {
    // Backward-compatible single-tick if needed
    this.stop();
    this.running = true;
    void (async () => {
      const cfg = await loadConfig();
      const iv = cfg?.keeper?.intervalsMs || { match: 3000, gc: 5000, accrue: 60000, liq: 5000 };
      this.gcTimer = setInterval(() => { if (this.running) { void this.tickGc().catch(() => {}); } }, iv.gc);
      this.matchTimer = setInterval(() => { if (this.running) { void this.tickMatch().catch(() => {}); } }, iv.match);
      this.accrueTimer = setInterval(() => { if (this.running) { void this.accrueAll().catch(() => {}); } }, iv.accrue);
      this.liqTimer = setInterval(() => { if (this.running) { void this.scanAndLiquidate().catch(() => {}); } }, iv.liq);
    })();
  }

  stop() {
    if (this.timer) { clearInterval(this.timer); this.timer = null; }
    if (this.matchTimer) { clearInterval(this.matchTimer); this.matchTimer = null; }
    if (this.gcTimer) { clearInterval(this.gcTimer); this.gcTimer = null; }
    if (this.accrueTimer) { clearInterval(this.accrueTimer); this.accrueTimer = null; }
    if (this.liqTimer) { clearInterval(this.liqTimer); this.liqTimer = null; }
    this.running = false;
  }


  private async tickGc() {
    const cfg = await loadConfig(); if (!cfg) return;
    const s = cfg.synthetics;
    const markets = s.markets as Record<string, { marketId: string; escrowId: string }>;
    const nowMs = Date.now();
    for (const [symbol, m] of Object.entries(markets)) {
      // Skip GC if no expired orders exist (best-effort via DB)
      const hasExpired = await this.hasExpiredOrders(symbol, nowMs).catch(() => true);
      if (!hasExpired) continue;
      try { await this.gcMarket(symbol, m.escrowId, m.marketId, s.registryId!, s.treasuryId!, cfg.keeper.gcMaxRemovals); } catch {}
    }
  }

  private async tickMatch() {
    const cfg = await loadConfig(); if (!cfg) return;
    const s = cfg.synthetics;
    const markets = s.markets as Record<string, { marketId: string; escrowId: string }>;
    for (const [symbol, m] of Object.entries(markets)) {
      // Only match when there are open orders
      const hasOpen = await this.hasOpenOrders(symbol).catch(() => true);
      if (!hasOpen) continue;
      try { await this.matchMarket(symbol, m.marketId, s.registryId!, cfg.keeper.matchMaxSteps, cfg.keeper.priceBandBps); } catch {}
    }
  }

  private getSignerFromConfig() {
    // Expect base64 32-byte secret key
    // In production, consider mnemonic/zkLogin integrations
    return (cfgKey: string | undefined) => {
      if (!cfgKey) throw new Error('wallet.privateKey missing');
      const raw = Buffer.from(cfgKey, 'base64');
      return Ed25519Keypair.fromSecretKey(new Uint8Array(raw));
    };
  }

  private async matchMarket(_symbol: string, marketId: string, registryId: string, maxSteps: number, priceBandBps: number) {
    const cfg = await loadConfig(); if (!cfg || !cfg.synthetics.packageId) return;
    const keypair = this.getSignerFromConfig()(cfg.wallet.privateKey);
    // Compute a simple price band around the oracle price for this market symbol
    let minPx: bigint = 0n;
    let maxPx: bigint = 18_446_744_073_709_551_615n; // u64::MAX
    try {
      const aggId = cfg.synthetics.aggregators?.[_symbol];
      if (aggId) {
        const px = await this.readOracleMicroPrice(aggId);
        if (px && px > 0n) {
          const band = (px * BigInt(priceBandBps)) / 10_000n;
          minPx = px > band ? (px - band) : 0n;
          maxPx = px + band;
        }
      }
    } catch {}
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.synthetics.packageId}::synthetics::match_step_auto_with_points`,
      arguments: [
        tx.object(cfg.synthetics.botPointsId!),
        tx.object('0x6'),
        tx.object(registryId),
        tx.object(marketId),
        tx.pure.u64(BigInt(maxSteps)),
        tx.pure.u64(minPx),
        tx.pure.u64(maxPx),
      ],
    });
    await this.client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
  }

  private async gcMarket(_symbol: string, escrowId: string, marketId: string, registryId: string, treasuryId: string, maxRemovals: number) {
    const cfg = await loadConfig(); if (!cfg || !cfg.synthetics.packageId) return;
    const keypair = this.getSignerFromConfig()(cfg.wallet.privateKey);
    const now = BigInt(Date.now());
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.synthetics.packageId}::synthetics::gc_step_with_points`,
      arguments: [
        tx.object(registryId),
        tx.object(marketId),
        tx.object(escrowId),
        tx.object(treasuryId),
        tx.pure.u64(now),
        tx.pure.u64(BigInt(maxRemovals)),
      ],
      typeArguments: [cfg.synthetics.collateralType!],
    });
    await this.client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
  }

  private async accrueAll() {
    const cfg = await loadConfig(); if (!cfg?.synthetics.packageId) return;
    const keypair = this.getSignerFromConfig()(cfg.wallet.privateKey);
    const vaults = await this.getCandidateVaultsFromDb().catch(() => null);
    const vaultList = (vaults && vaults.length > 0) ? vaults : (cfg.synthetics.vaultIds || []);
    for (const vaultId of vaultList) {
      const symbols = await this.getDebtSymbolsFromDb(vaultId).catch(() => [] as string[]);
      for (const symbol of symbols) {
        const aggId = cfg.synthetics.aggregators?.[symbol];
        if (!aggId) continue;
        const tx = new Transaction();
        tx.moveCall({
          target: `${cfg.synthetics.packageId}::synthetics::accrue_stability_with_points`,
          arguments: [
            tx.object(cfg.synthetics.botPointsId!),
            tx.object(vaultId),
            tx.object(cfg.synthetics.registryId!),
            tx.object('0x6'),
            tx.object(aggId as unknown as string),
            tx.object(cfg.synthetics.oracleConfigId! as unknown as string),
            tx.pure.string(symbol),
          ],
          typeArguments: [cfg.synthetics.collateralType!],
        });
        await this.client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      }
    }
  }

  private async scanAndLiquidate() {
    // For now, use configured vaultIds; a richer version can query the indexer DB
    const cfg = await loadConfig(); if (!cfg?.synthetics.packageId) return;
    const keypair = this.getSignerFromConfig()(cfg.wallet.privateKey);
    const candidateVaults = await this.getCandidateVaultsFromDb().catch(() => null);
    const vaultList = (candidateVaults && candidateVaults.length > 0) ? candidateVaults : (cfg.synthetics.vaultIds || []);
    for (const vaultId of vaultList) {
      for (const [symbol, aggId] of Object.entries(cfg.synthetics.aggregators)) {
        // Skip if no debt
        const outstanding = await this.getVaultDebtUnits(vaultId, symbol);
        if (outstanding <= 0n) continue;
        // Pre-check health via devInspect to avoid failed attempts
        const liqOk = await this.isLiquidatable(vaultId, symbol, aggId);
        if (!liqOk) continue;
        // Smarter repay sizing: 10% of outstanding, min 1
        const repay = (() => { const x = outstanding / 10n; return x > 0n ? x : 1n; })();
        const tx = new Transaction();
        tx.moveCall({
          target: `${cfg.synthetics.packageId}::synthetics::liquidate_vault`,
          arguments: [
            tx.object(cfg.synthetics.registryId!),
            tx.object('0x6'),
            tx.object(cfg.synthetics.oracleConfigId! as unknown as string),
            tx.object(aggId as unknown as string),
            tx.object(vaultId),
            tx.pure.string(symbol),
            tx.pure.u64(repay),
            tx.pure.address((cfg.wallet.address || '0x0') as any),
            tx.object(cfg.synthetics.treasuryId!),
          ],
          typeArguments: [cfg.synthetics.collateralType!],
        });
        await this.client.signAndExecuteTransaction({ transaction: tx, signer: keypair } as any);
      }
    }
  }

  // Read Switchboard aggregator's current_result.result.value as micro-USD price (u64)
  private async readOracleMicroPrice(aggregatorId: string): Promise<bigint | null> {
    try {
      const now = Date.now();
      const cached = this.oracleCache.get(aggregatorId);
      if (cached && (now - cached.t) < 1000) return cached.v;
      const res: any = await this.client.getObject({ id: aggregatorId, options: { showContent: true } as any });
      const content = res?.data?.content ?? res?.content;
      if (!content || content.dataType !== 'moveObject') return null;
      const fields = content.fields;
      const cr = fields?.current_result?.fields;
      const result = cr?.result?.fields ?? cr?.result;
      const valueRaw = result?.value ?? result?.fields?.value;
      const negRaw = result?.neg ?? result?.negative ?? result?.fields?.neg ?? result?.fields?.negative;
      if (valueRaw === undefined || valueRaw === null) return null;
      const v = BigInt(typeof valueRaw === 'string' ? valueRaw : String(valueRaw));
      const neg = !!negRaw;
      if (neg) return null;
      this.oracleCache.set(aggregatorId, { v, t: now });
      return v;
    } catch {
      return null;
    }
  }

  // DevInspect helper: check if vault is liquidatable for a symbol
  private async isLiquidatable(vaultId: string, symbol: string, aggId: string): Promise<boolean> {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics.packageId) return false;
      const tx = new Transaction();
      tx.moveCall({
        target: `${cfg.synthetics.packageId}::synthetics::check_vault_health`,
        arguments: [
          tx.object(vaultId),
          tx.object(cfg.synthetics.registryId!),
          tx.object('0x6'),
          tx.object(cfg.synthetics.oracleConfigId! as unknown as string),
          tx.object(aggId as unknown as string),
          tx.pure.string(symbol),
        ],
        typeArguments: [cfg.synthetics.collateralType!],
      });
      const sender = (cfg.wallet.address || '0x0') as string;
      const out: any = await (this.client as any).devInspectTransactionBlock({ sender, transactionBlock: tx });
      const rets = out?.results?.[0]?.returnValues as any[] | undefined;
      if (!rets || rets.length < 2) return false;
      // returns (u64, bool)
      const boolB64 = rets[1]?.[0];
      if (!boolB64) return false;
      const buf = Buffer.from(boolB64, 'base64');
      return buf.length > 0 && buf[0] !== 0;
    } catch {
      return false;
    }
  }

  // DevInspect helper retained via getVaultDebtUnits

  private async getVaultDebtUnits(vaultId: string, symbol: string): Promise<bigint> {
    try {
      const cfg = await loadConfig(); if (!cfg?.synthetics.packageId) return 0n;
      const tx = new Transaction();
      tx.moveCall({
        target: `${cfg.synthetics.packageId}::synthetics::get_vault_debt`,
        arguments: [tx.object(vaultId), tx.pure.string(symbol)],
        typeArguments: [cfg.synthetics.collateralType!],
      });
      const sender = (cfg.wallet.address || '0x0') as string;
      const out: any = await (this.client as any).devInspectTransactionBlock({ sender, transactionBlock: tx });
      const rets = out?.results?.[0]?.returnValues as any[] | undefined;
      if (!rets || rets.length < 1) return 0n;
      const u64b64 = rets[0]?.[0];
      if (!u64b64) return 0n;
      const buf = Buffer.from(u64b64, 'base64');
      if (buf.length < 8) return 0n;
      return buf.readBigUInt64LE(0);
    } catch { return 0n; }
  }


  private async getCandidateVaultsFromDb(limit = 50): Promise<string[]> {
    const cfg = await loadConfig(); if (!cfg?.postgresUrl) return [];
    if (!this.dbPool) this.dbPool = new Pool({ connectionString: cfg.postgresUrl });
    const q = `
      select v.vault_id
      from vaults v
      join vault_debts d on d.vault_id = v.vault_id
      where d.units > 0
      group by v.vault_id, v.last_update_ms
      order by v.last_update_ms asc
      limit $1
    `;
    const res = await this.dbPool.query(q, [limit]);
    return res.rows.map(r => r.vault_id as string);
  }

  private async getDb(): Promise<Pool> {
    const cfg = await loadConfig();
    if (!cfg?.postgresUrl) throw new Error('postgresUrl missing');
    if (!this.dbPool) this.dbPool = new Pool({ connectionString: cfg.postgresUrl });
    return this.dbPool;
  }

  private async hasOpenOrders(symbol: string): Promise<boolean> {
    const db = await this.getDb();
    const res = await db.query(`select 1 from orders where symbol=$1 and status='open' limit 1`, [symbol]);
    return (res.rowCount ?? 0) > 0;
  }

  private async hasExpiredOrders(symbol: string, nowMs: number): Promise<boolean> {
    const db = await this.getDb();
    const res = await db.query(`select 1 from orders where symbol=$1 and status='open' and expiry_ms is not null and expiry_ms < $2 limit 1`, [symbol, nowMs]);
    return (res.rowCount ?? 0) > 0;
  }

  private async getDebtSymbolsFromDb(vaultId: string): Promise<string[]> {
    const cfg = await loadConfig(); if (!cfg?.postgresUrl) return [];
    if (!this.dbPool) this.dbPool = new Pool({ connectionString: cfg.postgresUrl });
    const q = `
      select d.symbol
      from vault_debts d
      where d.vault_id = $1
      and d.units > 0
    `;
    const res = await this.dbPool.query(q, [vaultId]);
    return res.rows.map(r => r.symbol as string);
  }
}


