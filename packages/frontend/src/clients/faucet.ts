import { Transaction } from '@mysten/sui/transactions';

export type FaucetClientConfig = {
  // Package id for core Unxversal modules (e.g., `unxversal::usdu`)
  pkgUnxversal: string;
  // Package id for the `testtokens` package containing faucet modules like `ueth`, `ubtc`, etc
  pkgTesttokens: string;
};

/**
 * FaucetClient builds transactions for interacting with the USDU faucet and test token faucets.
 * - USDU faucet: claim, pause, set per-address limit
 * - Test token faucets: buy_with_usdu, pause, withdraw_usdu (admin)
 *
 * Note: All calls are built as programmable transaction blocks (PTBs) and returned for the
 * caller to sign/execute using their wallet provider. Methods accept precise object ids required
 * by the Move entry functions (faucet ids, registries, clock, etc.); the clock is always `0x6`.
 */
export class FaucetClient {
  private readonly pkgUnxversal: string;
  private readonly pkgTesttokens: string;

  constructor(cfg: FaucetClientConfig) {
    this.pkgUnxversal = cfg.pkgUnxversal;
    this.pkgTesttokens = cfg.pkgTesttokens;
  }

  // =========================
  // USDU Faucet (unxversal::usdu)
  // =========================

  /**
   * Claim USDU from the faucet up to your remaining limit.
   * amount is in base units (6 decimals), e.g. 10 USDU -> 10_000_000.
   */
  claimUsdu(args: { faucetId: string; amount: bigint | number }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkgUnxversal}::usdu::claim`,
      arguments: [
        tx.object(args.faucetId),
        tx.pure.u64(args.amount as bigint),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  /** Admin: set or update the per-address faucet claim limit (base units). */
  setUsduPerAddressLimit(args: { adminRegistryId: string; faucetId: string; newLimit: bigint | number }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkgUnxversal}::usdu::set_per_address_limit`,
      arguments: [
        tx.object(args.adminRegistryId),
        tx.object(args.faucetId),
        tx.pure.u64(args.newLimit as bigint),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  /** Admin: pause or unpause the USDU faucet. */
  setUsduPaused(args: { adminRegistryId: string; faucetId: string; paused: boolean }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkgUnxversal}::usdu::set_paused`,
      arguments: [
        tx.object(args.adminRegistryId),
        tx.object(args.faucetId),
        tx.pure.bool(args.paused),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  // ======================================
  // Test Token Faucets (testtokens::<token>)
  // ======================================

  /**
   * Buy a test token with USDU at the on-chain oracle price.
   * - tokenModule: the module name inside `testtokens` (e.g., 'ueth', 'ubtc', 'usui', ...)
   * - usduAmount: base units (6 decimals). We split the provided USDU coin to exact spend.
   * - minOut: optional slippage protection (default 0).
   * - priceInfoObjectId: Pyth `pyth::price_info::PriceInfoObject` id for the feed expected by the faucet.
   */
  buyWithUsdu(args: {
    tokenModule: string;
    faucetId: string;
    oracleRegistryId: string;
    priceInfoObjectId: string;
    usduPaymentCoinId: string;
    usduAmount: bigint | number;
    minOut?: bigint | number;
  }) {
    const tx = new Transaction();
    const spend = BigInt(args.usduAmount as bigint);
    const minOut = BigInt((args.minOut ?? 0) as bigint);

    const [usduIn] = tx.splitCoins(tx.object(args.usduPaymentCoinId), [tx.pure.u64(spend)]);

    tx.moveCall({
      target: `${this.pkgTesttokens}::${args.tokenModule}::buy_with_usdu`,
      arguments: [
        tx.object(args.oracleRegistryId),
        tx.object(args.faucetId),
        tx.object(args.priceInfoObjectId),
        usduIn,
        tx.pure.u64(minOut),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  /** Admin: pause or unpause a specific test token faucet. */
  setTokenFaucetPaused(args: { tokenModule: string; adminRegistryId: string; faucetId: string; paused: boolean }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkgTesttokens}::${args.tokenModule}::set_paused`,
      arguments: [
        tx.object(args.adminRegistryId),
        tx.object(args.faucetId),
        tx.pure.bool(args.paused),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  /** Admin: withdraw collected USDU from a token faucet to the caller (admin). */
  withdrawTokenFaucetUsdu(args: { tokenModule: string; adminRegistryId: string; faucetId: string; amount: bigint | number }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkgTesttokens}::${args.tokenModule}::withdraw_usdu`,
      arguments: [
        tx.object(args.adminRegistryId),
        tx.object(args.faucetId),
        tx.pure.u64(args.amount as bigint),
      ],
    });
    return tx;
  }
}


