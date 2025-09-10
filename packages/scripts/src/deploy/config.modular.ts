import type { DeployConfig } from './types.js';
import { buildOptions } from './options.js';
import { buildFuturesSet } from './futures.js';
import { buildGasFutures } from './gas_futures.js';
import { buildPerpetuals } from './perpetuals.js';
import { buildLendingMarketsMainnet, buildLendingMarketsTestnet } from './lending.js';
import { MAINNET_ORACLE_FEEDS, TESTNET_ORACLE_FEEDS, ORACLE_MAX_AGE_SEC } from './oracle.js';
import { buildDexPools } from './dex.js';
import { buildVaults } from './vaults.js';

export const deployConfig: DeployConfig = {
  network: 'mainnet',
  pkgId: '',
  adminRegistryId: '',
  feeConfigId: '',
  feeVaultId: '',
  stakingPoolId: '',
  usduFaucetId: '',
  oracleRegistryId: '',
  additionalAdmins: [
    process.env.UNXV_TWO ?? "",
    process.env.UNXV_THREE ?? ""
  ],
  feeParams: undefined,
  feeTiers: undefined,
  lendingParams: undefined,
  poolCreationFeeUnxv: undefined,
  tradeFees: undefined,
  oracleFeeds: MAINNET_ORACLE_FEEDS,
  oracleMaxAgeSec: ORACLE_MAX_AGE_SEC,
  usdu: undefined,
  lendingMarkets: buildLendingMarketsMainnet(),
  options: await buildOptions(),
  futures: buildFuturesSet(),
  gasFutures: buildGasFutures(),
  perpetuals: buildPerpetuals(),
  dexPools: buildDexPools(),
  vaults: buildVaults(),
};

export const testnetDeployConfig: DeployConfig = {
  network: 'testnet',
  pkgId: '',
  adminRegistryId: '',
  feeConfigId: '',
  feeVaultId: '',
  stakingPoolId: '',
  usduFaucetId: '',
  oracleRegistryId: '',
  additionalAdmins: [
    process.env.UNXV_TWO ?? "",
    process.env.UNXV_THREE ?? ""
  ],
  feeParams: undefined,
  feeTiers: undefined,
  lendingParams: undefined,
  poolCreationFeeUnxv: undefined,
  tradeFees: undefined,
  oracleFeeds: TESTNET_ORACLE_FEEDS,
  oracleMaxAgeSec: ORACLE_MAX_AGE_SEC,
  usdu: undefined,
  lendingMarkets: buildLendingMarketsTestnet(),
  options: await buildOptions(),
  futures: buildFuturesSet(),
  gasFutures: buildGasFutures(),
  perpetuals: buildPerpetuals(),
  dexPools: buildDexPools(),
  vaults: buildVaults(),
};


