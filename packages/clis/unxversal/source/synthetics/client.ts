import {SuiClient, getFullnodeUrl} from '@mysten/sui/client';
import {Transaction} from '@mysten/sui/transactions';
import {loadConfig} from '../lib/config.js';

export class SyntheticsClient {
  private client: SuiClient;
  constructor(rpcUrl: string) {
    this.client = new SuiClient({ url: rpcUrl || getFullnodeUrl('testnet')});
  }

  static async fromConfig() {
    const cfg = await loadConfig();
    if (!cfg) throw new Error('No config found; run settings first.');
    return new SyntheticsClient(cfg.rpcUrl);
  }

  // -------- Admin / Governance PTBs --------

  // Set the concrete collateral type C for the system (one-time). Transfers returned Display object to caller.
  async buildSetCollateralAdminTx(): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg) throw new Error('missing config');
    const adminId = cfg.synthetics.admin.adminRegistryId; if (!adminId) throw new Error('missing synthetics.admin.adminRegistryId');
    const registryId = cfg.synthetics.registryId; if (!registryId) throw new Error('missing synthetics.registryId');
    const publisherId = cfg.synthetics.admin.publisherId; if (!publisherId) throw new Error('missing synthetics.admin.publisherId');
    const tx = new Transaction();
    const disp = tx.moveCall({
      target: `${cfg.synthetics.packageId}::synthetics::set_collateral_admin`,
      arguments: [
        tx.object(adminId),
        tx.object(registryId),
        tx.object(publisherId),
      ],
      typeArguments: [cfg.synthetics.collateralType!],
    });
    // Transfer resulting Display to the wallet owner
    tx.transferObjects([disp as any], tx.pure.address((cfg.wallet.address || '0x0') as string));
    return tx;
  }

  // Point the registry at the chosen Treasury<C>
  async buildSetRegistryTreasuryAdminTx(): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg) throw new Error('missing config');
    const adminId = cfg.synthetics.admin.adminRegistryId; if (!adminId) throw new Error('missing synthetics.admin.adminRegistryId');
    const registryId = cfg.synthetics.registryId; if (!registryId) throw new Error('missing synthetics.registryId');
    const treasuryId = cfg.synthetics.treasuryId; if (!treasuryId) throw new Error('missing synthetics.treasuryId');
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.synthetics.packageId}::synthetics::set_registry_treasury_admin`,
      arguments: [
        tx.object(adminId),
        tx.object(registryId),
        tx.object(treasuryId),
      ],
      typeArguments: [cfg.synthetics.collateralType!],
    });
    return tx;
  }

  // Create/list a new synthetic asset and auto-create market/escrow
  async buildCreateSyntheticAssetTx(params: { name: string; symbol: string; decimals: number; feedBytes: string | Uint8Array; minCollateralRatioBps: bigint }): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg) throw new Error('missing config');
    const adminId = cfg.synthetics.admin.adminRegistryId; if (!adminId) throw new Error('missing synthetics.admin.adminRegistryId');
    const registryId = cfg.synthetics.registryId; if (!registryId) throw new Error('missing synthetics.registryId');
    const cfgId = cfg.synthetics.collateralCfgId; if (!cfgId) throw new Error('missing synthetics.collateralCfgId');
    const tx = new Transaction();
    const bytes = this.bytesFrom(params.feedBytes);
    tx.moveCall({
      // deprecated in v2: create_synthetic_asset removed
      target: `${cfg.synthetics.packageId}::synthetics::admin_list_instrument`,
      arguments: [
        tx.object(adminId),
        tx.object(registryId),
        tx.pure.string(params.name),
        tx.pure.string(params.symbol),
        tx.pure.u8(params.decimals),
        tx.pure.vector('u8', Array.from(bytes)),
        tx.pure.u64(params.minCollateralRatioBps),
        tx.object(cfgId),
      ],
      typeArguments: [cfg.synthetics.collateralType!],
    });
    return tx;
  }

  // Toggle pause or resume via AdminRegistry
  async buildTogglePauseTx(pause: boolean): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg) throw new Error('missing config');
    const adminId = cfg.synthetics.admin.adminRegistryId; if (!adminId) throw new Error('missing synthetics.admin.adminRegistryId');
    const registryId = cfg.synthetics.registryId; if (!registryId) throw new Error('missing synthetics.registryId');
    const tx = new Transaction();
    tx.moveCall({
      target: pause
        ? `${cfg.synthetics.packageId}::synthetics::emergency_pause_admin`
        : `${cfg.synthetics.packageId}::synthetics::resume_admin`,
      arguments: [tx.object(adminId), tx.object(registryId)],
    });
    return tx;
  }

  // Per-asset fee/param updates (admin)
  async buildSetAssetFeeBpsTx(kind: 'stability' | 'liq_threshold' | 'liq_penalty' | 'mint' | 'burn', symbol: string, bps: bigint): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg) throw new Error('missing config');
    const adminId = cfg.synthetics.admin.adminRegistryId; if (!adminId) throw new Error('missing synthetics.admin.adminRegistryId');
    const registryId = cfg.synthetics.registryId; if (!registryId) throw new Error('missing synthetics.registryId');
    const tx = new Transaction();
    const base = `${cfg.synthetics.packageId}::synthetics`;
    const target = (
      kind === 'stability' ? `${base}::set_asset_stability_fee_admin`
      : kind === 'liq_threshold' ? `${base}::set_asset_liquidation_threshold_admin`
      : kind === 'liq_penalty' ? `${base}::set_asset_liquidation_penalty_admin`
      : kind === 'mint' ? `${base}::set_asset_mint_fee_admin` : `${base}::set_asset_burn_fee_admin`
    );
    tx.moveCall({
      target,
      arguments: [
        tx.object(adminId),
        tx.object(registryId),
        tx.pure.string(symbol),
        tx.pure.u64(bps),
      ],
    });
    return tx;
  }

  private bytesFrom(input: string | Uint8Array): Uint8Array {
    if (input instanceof Uint8Array) return input;
    const s = input.trim();
    if (s.startsWith('0x') || s.startsWith('0X')) {
      const hex = s.slice(2);
      if (hex.length % 2 !== 0) throw new Error('hex string must have even length');
      const out = new Uint8Array(hex.length / 2);
      for (let i=0;i<out.length;i++) out[i] = parseInt(hex.slice(i*2, i*2+2), 16);
      return out;
    }
    // assume base64
    return new Uint8Array(Buffer.from(s, 'base64'));
  }

  // Example: query vaults, markets, etc. (stubs)
  async getObjectsByOwner(address: string) {
    return this.client.getOwnedObjects({ owner: address });
  }

  // ---- PTB helpers (high-level) ----
  async buildCreateVaultTx(): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg) throw new Error('missing config');
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.synthetics.packageId}::synthetics::create_vault`,
      arguments: [tx.object(cfg.synthetics.collateralCfgId!), tx.object(cfg.synthetics.registryId!)],
      typeArguments: [cfg.synthetics.collateralType!],
    });
    return tx;
  }

  async buildDepositCollateralTx(vaultId: string, coinId: string): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg) throw new Error('missing config');
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.synthetics.packageId}::synthetics::deposit_collateral`,
      arguments: [tx.object(vaultId), tx.object(coinId)],
      typeArguments: [cfg.synthetics.collateralType!],
    });
    return tx;
  }

  async buildPlaceOrderTx(params: { symbol: string; marketId: string; escrowId: string; registryId: string; vaultId: string; takerIsBid: boolean; price: bigint; size: bigint; expiryMs: bigint; treasuryId: string; }): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg) throw new Error('missing config');
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.synthetics.packageId}::synthetics::place_synth_limit_with_escrow`,
      arguments: [
        tx.object(params.registryId),
        tx.object(params.marketId),
        tx.object(params.escrowId),
        tx.object('0x6'),
        tx.object(cfg.synthetics.oracleConfigId! as unknown as string),
        tx.object(cfg.synthetics.aggregators[params.symbol]! as unknown as string),
        tx.object(cfg.synthetics.unxvAggregatorId! as unknown as string),
        tx.pure.bool(params.takerIsBid),
        tx.pure.u64(params.price),
        tx.pure.u64(params.size),
        tx.pure.u64(params.expiryMs),
        tx.object(params.vaultId),
        tx.makeMoveVec({ type: `${cfg.synthetics.packageId}::unxv::UNXV`, elements: [] }),
        tx.object(params.treasuryId),
      ],
      typeArguments: [cfg.synthetics.collateralType!],
    });
    return tx;
  }

  async buildWithdrawCollateralTx(vaultId: string, amount: bigint, symbol: string, oraclePriceObj: string): Promise<Transaction> {
    // Withdraw needs cfg, registry, clock, oracle_cfg, price, symbol, amount
    // Caller is responsible for providing the concrete oracle Aggregator object id for symbol
    const cfg = await loadConfig(); if (!cfg) throw new Error('missing config');
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.synthetics.packageId}::synthetics::withdraw_collateral`,
      arguments: [
        tx.object(cfg.synthetics.collateralCfgId! as unknown as string), // CollateralConfig<C> shared object id
        tx.object(vaultId),
        tx.object(cfg.synthetics.registryId!),
        tx.object('0x6'),
        tx.object(cfg.synthetics.oracleConfigId! as unknown as string),
        tx.object(oraclePriceObj),
        tx.pure.string(symbol),
        tx.pure.u64(amount),
      ],
      typeArguments: [cfg.synthetics.collateralType!],
    });
    return tx;
  }

  async buildMintTx(params: { vaultId: string; symbol: string; amount: bigint; priceObj: string; unxvPriceObj: string; treasuryId: string; unxvCoins?: string[] }): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg) throw new Error('missing config');
    const tx = new Transaction();
    const vecUNXV = tx.makeMoveVec({ type: `${cfg.synthetics.packageId}::unxv::UNXV`, elements: (params.unxvCoins ?? []).map(id => tx.object(id)) });
    tx.moveCall({
      target: `${cfg.synthetics.packageId}::synthetics::mint_synthetic`,
      arguments: [
        tx.object(cfg.synthetics.collateralCfgId! as unknown as string),
        tx.object(params.vaultId),
        tx.object(cfg.synthetics.registryId!),
        tx.object('0x6'),
        tx.object(cfg.synthetics.oracleConfigId! as unknown as string),
        tx.object(params.priceObj),
        tx.pure.string(params.symbol),
        tx.pure.u64(params.amount),
        vecUNXV,
        tx.object(params.unxvPriceObj),
        tx.object(params.treasuryId),
      ],
      typeArguments: [cfg.synthetics.collateralType!],
    });
    return tx;
  }

  async buildBurnTx(params: { vaultId: string; symbol: string; amount: bigint; priceObj: string; unxvPriceObj: string; treasuryId: string; unxvCoins?: string[] }): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg) throw new Error('missing config');
    const tx = new Transaction();
    const vecUNXV = tx.makeMoveVec({ type: `${cfg.synthetics.packageId}::unxv::UNXV`, elements: (params.unxvCoins ?? []).map(id => tx.object(id)) });
    tx.moveCall({
      target: `${cfg.synthetics.packageId}::synthetics::burn_synthetic`,
      arguments: [
        tx.object(cfg.synthetics.collateralCfgId! as unknown as string),
        tx.object(params.vaultId),
        tx.object(cfg.synthetics.registryId!),
        tx.object('0x6'),
        tx.object(cfg.synthetics.oracleConfigId! as unknown as string),
        tx.object(params.priceObj),
        tx.pure.string(params.symbol),
        tx.pure.u64(params.amount),
        vecUNXV,
        tx.object(params.unxvPriceObj),
        tx.object(params.treasuryId),
      ],
      typeArguments: [cfg.synthetics.collateralType!],
    });
    return tx;
  }

  async buildCancelOrderTx(params: { marketId: string; escrowId: string; orderId: string; vaultId: string }): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg) throw new Error('missing config');
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.synthetics.packageId}::synthetics::cancel_synth_clob_with_escrow`,
      arguments: [tx.object(params.marketId), tx.object(params.escrowId), tx.pure.u128(params.orderId), tx.object(params.vaultId)],
      typeArguments: [cfg.synthetics.collateralType!],
    });
    return tx;
  }

  async buildModifyOrderTx(params: { registryId: string; marketId: string; escrowId: string; orderId: string; newQty: bigint; nowMs: bigint; vaultId: string }): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg) throw new Error('missing config');
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.synthetics.packageId}::synthetics::modify_synth_clob`,
      arguments: [
        tx.object(params.registryId),
        tx.object(params.marketId),
        tx.object(params.escrowId),
        tx.pure.u128(params.orderId),
        tx.pure.u64(params.newQty),
        tx.pure.u64(params.nowMs),
        tx.object(params.vaultId),
      ],
      typeArguments: [cfg.synthetics.collateralType!],
    });
    return tx;
  }

  async buildClaimFillsTx(params: { registryId: string; marketId: string; escrowId: string; orderId: string; vaultId: string }): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg) throw new Error('missing config');
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.synthetics.packageId}::synthetics::claim_maker_fills`,
      arguments: [tx.object(params.registryId), tx.object(params.marketId), tx.object(params.escrowId), tx.pure.u128(params.orderId), tx.object(params.vaultId)],
      typeArguments: [cfg.synthetics.collateralType!],
    });
    return tx;
  }
}

