import type { DeployConfig } from './types.js';
import { buildMainnetOptions, buildTestnetOptions } from './options.js';
import { buildMainnetFuturesSet, buildTestnetFuturesSet } from './futures.js';
import { buildMainnetGasFutures, buildTestnetGasFutures } from './gas_futures.js';
import { buildMainnetPerpetuals, buildTestnetPerpetuals } from './perpetuals.js';
import { buildLendingMarketsMainnet, buildLendingMarketsTestnet } from './lending.js';
import { MAINNET_ORACLE_FEEDS, TESTNET_ORACLE_FEEDS, ORACLE_MAX_AGE_SEC } from './oracle.js';
import { buildMainnetDexPools, buildTestnetDexPools } from './dex.js';
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
  options: await buildMainnetOptions(),
  futures: buildMainnetFuturesSet(),
  gasFutures: buildMainnetGasFutures(),
  perpetuals: buildMainnetPerpetuals(),
  dexPools: buildMainnetDexPools(),
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
  options: await buildTestnetOptions(),
  futures: buildTestnetFuturesSet(),
  gasFutures: buildTestnetGasFutures(),
  perpetuals: buildTestnetPerpetuals(),
  dexPools: buildTestnetDexPools(),
  vaults: buildVaults(),
};


