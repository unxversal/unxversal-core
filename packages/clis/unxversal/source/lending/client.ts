import {Transaction} from '@mysten/sui/transactions';
import {loadConfig} from '../lib/config.js';

export class LendingClient {
  constructor(_rpcUrl: string) {}

  static async fromConfig() {
    const cfg = await loadConfig();
    if (!cfg) throw new Error('No config found; run settings first.');
    return new LendingClient(cfg.rpcUrl);
  }

  async buildOpenAccountTx(): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing lending.packageId');
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.lending.packageId}::lending::open_account`, arguments: [] });
    return tx;
  }

  async buildSupplyTx(params: { registryId: string; poolId: string; accountId: string; coinId: string; amount: bigint }): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing lending.packageId');
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.lending.packageId}::lending::supply`,
      arguments: [
        tx.object(params.registryId),
        tx.object(params.poolId),
        tx.object(params.accountId),
        tx.object(params.coinId),
        tx.pure.u64(params.amount),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  async buildWithdrawTx(params: { registryId: string; poolId: string; accountId: string; amount: bigint; oracleRegistryId: string; oracleConfigId: string; priceSelfAggId: string; symbols: string[]; pricesSetId: string; supplyIdx: bigint[]; borrowIdx: bigint[] }): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing lending.packageId');
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.lending.packageId}::lending::withdraw`,
      arguments: [
        tx.object(params.registryId),
        tx.object(params.poolId),
        tx.object(params.accountId),
        tx.pure.u64(params.amount),
        tx.object(params.oracleRegistryId),
        tx.object(params.oracleConfigId),
        tx.object('0x6'),
        tx.object(params.priceSelfAggId),
        tx.makeMoveVec({ type: '0x1::string::String', elements: params.symbols.map(s => tx.pure.string(s)) }),
        tx.object(params.pricesSetId),
        tx.makeMoveVec({ type: 'u64', elements: params.supplyIdx.map(x => tx.pure.u64(x)) }),
        tx.makeMoveVec({ type: 'u64', elements: params.borrowIdx.map(x => tx.pure.u64(x)) }),
      ],
    });
    return tx;
  }

  async buildBorrowTx(params: { registryId: string; poolId: string; accountId: string; amount: bigint; oracleRegistryId: string; oracleConfigId: string; priceDebtAggId: string; symbols: string[]; pricesSetId: string; supplyIdx: bigint[]; borrowIdx: bigint[] }): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing lending.packageId');
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.lending.packageId}::lending::borrow`,
      arguments: [
        tx.object(params.registryId),
        tx.object(params.poolId),
        tx.object(params.accountId),
        tx.pure.u64(params.amount),
        tx.object(params.oracleRegistryId),
        tx.object(params.oracleConfigId),
        tx.object('0x6'),
        tx.object(params.priceDebtAggId),
        tx.makeMoveVec({ type: '0x1::string::String', elements: params.symbols.map(s => tx.pure.string(s)) }),
        tx.object(params.pricesSetId),
        tx.makeMoveVec({ type: 'u64', elements: params.supplyIdx.map(x => tx.pure.u64(x)) }),
        tx.makeMoveVec({ type: 'u64', elements: params.borrowIdx.map(x => tx.pure.u64(x)) }),
      ],
    });
    return tx;
  }

  async buildRepayTx(params: { registryId: string; poolId: string; accountId: string; paymentCoinId: string }): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing lending.packageId');
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.lending.packageId}::lending::repay`, arguments: [tx.object(params.registryId), tx.object(params.poolId), tx.object(params.accountId), tx.object(params.paymentCoinId), tx.object('0x6')] });
    return tx;
  }

  async buildUpdateRatesTx(params: { registryId: string; poolId: string }): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing lending.packageId');
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.lending.packageId}::lending::update_pool_rates`, arguments: [tx.object(params.registryId), tx.object(params.poolId), tx.object('0x6')] });
    return tx;
  }

  async buildAccruePoolTx(params: { registryId: string; poolId: string }): Promise<Transaction> {
    const cfg = await loadConfig(); if (!cfg?.lending?.packageId) throw new Error('missing lending.packageId');
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.lending.packageId}::lending::accrue_pool_interest`, arguments: [tx.object(params.registryId), tx.object(params.poolId), tx.object('0x6')] });
    return tx;
  }
}


