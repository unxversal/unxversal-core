import type { DeployConfig } from './types.js';
import { buildMainnetOptions, buildTestnetOptions } from './options.js';
import { buildMainnetFuturesSet, buildTestnetFuturesSet } from './futures.js';
import { buildMainnetGasFutures, buildTestnetGasFutures } from './gas_futures.js';
import { buildMainnetPerpetuals, buildTestnetPerpetuals } from './perpetuals.js';
import { buildLendingMarketsMainnet, buildLendingMarketsTestnet } from './lending.js';
import { MAINNET_ORACLE_FEEDS, TESTNET_ORACLE_FEEDS, ORACLE_MAX_AGE_SEC } from './oracle.js';
import { buildMainnetDexPools, buildTestnetDexPools } from './dex.js';
import { buildVaults } from './vaults.js';
import { TIER_PARAMS, TESTNET_DERIVATIVE_PERP_FUT_SPECS } from './markets.js';
import type { SuiTypeTag } from './types.js';
import { generateExpiriesMs } from '../utils/series.js';

// Additional derivatives to enable ONLY for perps/futures (keep Options unaffected)
// Do NOT add these to DERIVATIVE_SYMBOLS to avoid impacting options deploy
const EXTRA_DERIVATIVE_SYMBOLS_TESTNET = [
  'HYPE/USDC', 'PUMP/USDC', 'ENA/USDC', 'WLD/USDC', 'DOGE/USDC', 'WLFI/USDC',
  'XRP/USDC', 'LINK/USDC', 'LTC/USDC', 'LAUNCHCOIN/USDC', 'AAVE/USDC', 'ARB/USDC',
  'KAITO/USDC', 'IP/USDC', 'MNT/USDC', 'UNI/USDC', 'PYTH/USDC', 'TIA/USDC',
  'TAO/USDC', 'NEAR/USDC', 'TRX/USDC', 'XLM/USDC', 'DOT/USDC', 'XMR/USDC',
  'ICP/USDC', 'FIL/USDC', 'OP/USDC', 'INJ/USDC', 'PAXG/USDC', 'LDO/USDC',
  'CAKE/USDC', 'RENDER/USDC', 'XAUt/USDC', 'IMX/USDC', 'PI/USDC',
];

// Testnet USDC type tag used for derivatives collateral
const USDC_TESTNET_TYPE: SuiTypeTag = '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC';
const EXTRA_PERPS_TESTNET = EXTRA_DERIVATIVE_SYMBOLS_TESTNET.map((symbol) => {
  const risk = TIER_PARAMS['C'];
  const spec = TESTNET_DERIVATIVE_PERP_FUT_SPECS[symbol] ?? { contractSize: 1_000_000, tickSize: 10_000, lotSize: 1, minSize: 1 };
  return {
    collat: USDC_TESTNET_TYPE,
    symbol,
    contractSize: spec.contractSize,
    fundingIntervalMs: 3_600_000,
    initialMarginBps: risk.initialMarginBps,
    maintenanceMarginBps: risk.maintenanceMarginBps,
    liquidationFeeBps: risk.liquidationFeeBps,
    keeperIncentiveBps: risk.keeperIncentiveBps,
    tickSize: spec.tickSize,
    lotSize: spec.lotSize,
    minSize: spec.minSize,
    accountMaxNotional1e6: risk.accountMaxNotional1e6,
    marketMaxNotional1e6: risk.marketMaxNotional1e6,
    accountShareOfOiBps: risk.accountShareOfOiBps,
  } as const;
});

// Generate 12 monthly expiries (1 year) at 00:00 UTC on day 1 for extra futures
const EXTRA_FUTURES_TESTNET: NonNullable<DeployConfig['futures']> = (() => {
  const expiries = generateExpiriesMs({ cadence: 'monthly', years: 1, expiryHourUtc: 0, monthlyDay: 1 });
  const risk = TIER_PARAMS['C'];
  const out: NonNullable<DeployConfig['futures']> = [];
  for (const symbol of EXTRA_DERIVATIVE_SYMBOLS_TESTNET) {
    const spec = TESTNET_DERIVATIVE_PERP_FUT_SPECS[symbol] ?? { contractSize: 1_000_000, tickSize: 10_000, lotSize: 1, minSize: 1 };
    for (const expiryMs of expiries) {
      out.push({
        collat: USDC_TESTNET_TYPE,
        symbol,
        expiryMs,
        contractSize: spec.contractSize,
        initialMarginBps: risk.initialMarginBps,
        maintenanceMarginBps: risk.maintenanceMarginBps,
        liquidationFeeBps: risk.liquidationFeeBps,
        keeperIncentiveBps: risk.keeperIncentiveBps,
        tickSize: spec.tickSize,
        lotSize: spec.lotSize,
        minSize: spec.minSize,
        accountMaxNotional1e6: risk.accountMaxNotional1e6,
        marketMaxNotional1e6: risk.marketMaxNotional1e6,
        accountShareOfOiBps: risk.accountShareOfOiBps,
        liqTargetBufferBps: risk.liqTargetBufferBps,
      } as const);
    }
  }
  return out;
})();

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
  futures: [
    ...buildTestnetFuturesSet(),
    ...EXTRA_FUTURES_TESTNET,
  ],
  gasFutures: buildTestnetGasFutures(),
  perpetuals: [
    ...buildTestnetPerpetuals(),
    ...EXTRA_PERPS_TESTNET,
  ],
  dexPools: buildTestnetDexPools(),
  vaults: buildVaults(),
};


