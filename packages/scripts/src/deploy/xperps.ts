import type { DeployConfig } from './types.js';

// Builders for xperps (synthetic perps) sets. Collateral is typically USDC.

export function buildMainnetXPerps(): NonNullable<DeployConfig['xperps']> {
  // Placeholder empty by default; project can add real specs per market.
  return [];
}

export function buildTestnetXPerps(): NonNullable<DeployConfig['xperps']> {
  // Provide a small sample default: can be extended via config.modular.ts
  return [];
}


