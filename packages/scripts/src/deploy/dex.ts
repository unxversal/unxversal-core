import type { DeployConfig } from './types.js';
import { DERIVATIVE_SYMBOLS, MAINNET_DERIVATIVE_TYPE_TAGS, TESTNET_DERIVATIVE_TYPE_TAGS } from './markets.js';

const EXISTING_DEX_POOL_IDS: Partial<Record<string, string>> = {
  // 'SUI/USDC': '0x...'
};

export function buildMainnetDexPools(): NonNullable<DeployConfig['dexPools']> {
  return DERIVATIVE_SYMBOLS
    .filter((symbol) => !EXISTING_DEX_POOL_IDS[symbol])
    .map((symbol) => {
      const cfg = MAINNET_DERIVATIVE_TYPE_TAGS[symbol];
      if (!cfg) throw new Error(`Missing DERIVATIVE_TYPE_TAGS for ${symbol}`);
      return {
        registryId: '0x7c256edbda983a2cd6f946655f4bf3f00a41043993781f8674a7046e8c0e11d1',
        base: cfg.base,
        quote: cfg.quote,
        tickSize: cfg.tickSize,
        lotSize: cfg.lotSize,
        minSize: cfg.minSize,
      } as const;
    });
}

export function buildTestnetDexPools(): NonNullable<DeployConfig['dexPools']> {
  return DERIVATIVE_SYMBOLS
    .map((symbol) => {
      const cfg = TESTNET_DERIVATIVE_TYPE_TAGS[symbol];
      if (!cfg) throw new Error(`Missing DERIVATIVE_TYPE_TAGS for ${symbol}`);
      return {
        registryId: '0x7c256edbda983a2cd6f946655f4bf3f00a41043993781f8674a7046e8c0e11d1',
        base: cfg.base,
        quote: cfg.quote,
        tickSize: cfg.tickSize,
        lotSize: cfg.lotSize,
        minSize: cfg.minSize,
        deepCreationFeeCoinId: '0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8',
        deepCreationFeeAmount: 600,
      } as const;
    });
}