import type { NetworkName } from '../config.js';

export type TypeTag = string;

export type DeployConfig = {
  network: NetworkName;
  pkgId: string;
  adminRegistryId: string;
  feeConfigId: string;
  feeVaultId: string;
  stakingPoolId: string;
  usduFaucetId?: string;
  oracleRegistryId?: string;
  additionalAdmins?: string[];
  feeParams?: {
    dexFeeBps: number;
    unxvDiscountBps: number;
    preferDeepBackend: boolean;
    stakersShareBps: number;
    treasuryShareBps: number;
    burnShareBps: number;
    treasury: string;
  };
  /** Optional: configure staking tiers (thresholds/discount bps) */
  feeTiers?: {
    t1: number; b1: number;
    t2: number; b2: number;
    t3: number; b3: number;
    t4: number; b4: number;
    t5: number; b5: number;
    t6: number; b6: number;
  };
  /** Optional: set lending fee and collateral bonus caps */
  lendingParams?: { borrowFeeBps: number; collateralBonusMaxBps: number };
  /** Optional: set UNXV amount charged for permissionless pool creation */
  poolCreationFeeUnxv?: number;
  tradeFees?: {
    dex?: { takerBps: number; makerBps: number };
    futures?: { takerBps: number; makerBps: number };
    gasFutures?: { takerBps: number; makerBps: number };
  };
  oracleFeeds?: Array<{ symbol: string; aggregatorId: string }>;
  oracleMaxAgeSec?: number;
  usdu?: { perAddressLimit?: number; paused?: boolean };
  /**
   * Initialize dual-asset lending markets (Collateral → Debt)
   */
  lendingMarkets?: Array<{
    marketId?: string;
    collat: TypeTag;
    debt: TypeTag;
    symbol: string;
    baseRateBps: number;
    multiplierBps: number;
    jumpMultiplierBps: number;
    kinkUtilBps: number;
    reserveFactorBps: number;
    collateralFactorBps: number;
    liquidationThresholdBps: number;
    liquidationBonusBps: number;
  }>;
  options?: Array<{
    marketId?: string;
    base: TypeTag;
    quote: TypeTag;
    tickSize: number;
    lotSize: number;
    minSize: number;
    series: Array<{ expiryMs: number; strike1e6: number; isCall: boolean; symbol: string }>;
  }>;
  futures?: Array<{
    marketId?: string;
    collat: TypeTag;
    symbol: string;
    contractSize: number;
    initialMarginBps: number;
    maintenanceMarginBps: number;
    liquidationFeeBps: number;
    keeperIncentiveBps?: number;
    // New risk controls
    accountMaxNotional1e6?: string; // use string to avoid JS precision issues
    marketMaxNotional1e6?: string;
    accountShareOfOiBps?: number;
    // Tiered IM
    tierThresholds1e6?: number[];
    tierImBps?: number[];
  }>;
  gasFutures?: Array<{
    marketId?: string;
    collat: TypeTag;
    expiryMs: number;
    contractSize: number;
    initialMarginBps: number;
    maintenanceMarginBps: number;
    liquidationFeeBps: number;
    keeperIncentiveBps?: number;
    // New risk controls
    accountMaxNotional1e6?: string;
    marketMaxNotional1e6?: string;
    accountShareOfOiBps?: number;
    tierThresholds1e6?: number[];
    tierImBps?: number[];
  }>;
  perpetuals?: Array<{
    marketId?: string;
    collat: TypeTag;
    symbol: string;
    contractSize: number;
    fundingIntervalMs: number;
    initialMarginBps: number;
    maintenanceMarginBps: number;
    liquidationFeeBps: number;
    keeperIncentiveBps?: number;
    // New risk controls (optional future parity)
    accountMaxNotional1e6?: string;
    marketMaxNotional1e6?: string;
    accountShareOfOiBps?: number;
    tierThresholds1e6?: number[];
    tierImBps?: number[];
  }>;
  dexPools?: Array<{
    registryId: string;
    base: TypeTag;
    quote: TypeTag;
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    unxvFeeCoinId: string;
    tickSize: number; lotSize: number; minSize: number;
  }>;
  vaults?: Array<{
    asset: TypeTag;
    caps?: { maxOrderSizeBase?: number; maxInventoryTiltBps?: number; minDistanceBps?: number; paused?: boolean };
  }>;
};

export const deployConfig: DeployConfig = {
  network: 'testnet',
  pkgId: '',
  adminRegistryId: '',
  feeConfigId: '',
  feeVaultId: '',
  stakingPoolId: '',
  usduFaucetId: '',
  oracleRegistryId: '',
  additionalAdmins: [
    "0x24945081376e008971b437092ebd3de139bb478fc9501c1101fed02f3a2f4fb0",
    "0x283d357de0dd9478563cf440227100f381cea0bbc8d84110c6d2a55483b509a2"
  ],
  feeParams: undefined,
  feeTiers: undefined,
  lendingParams: undefined,
  poolCreationFeeUnxv: undefined,
  tradeFees: undefined,
  oracleFeeds: [
    { symbol: 'SUI/USDC', aggregatorId: '0x1' },
    { symbol: 'DEEP/USDC', aggregatorId: '0x2' },
    { symbol: 'ETH/USDC', aggregatorId: '0x3' },
    { symbol: 'BTC/USDC', aggregatorId: '0x4' },
    { symbol: 'SOL/USDC', aggregatorId: '0x5' },
    { symbol: 'FTM/USDC', aggregatorId: '0x8' },
    { symbol: 'GLMR/USDC', aggregatorId: '0x9' },
    { symbol: 'MATIC/USDC', aggregatorId: '0x10' },
    { symbol: 'APT/USDC', aggregatorId: '0x11' },
    { symbol: 'CELO/USDC', aggregatorId: '0x12' },
    { symbol: 'DRF/USDC', aggregatorId: '0x13' },
    { symbol: 'IKA/USDC', aggregatorId: '0x14' },
    { symbol: 'NS/USDC', aggregatorId: '0x15' },
    { symbol: 'SEND/USDC', aggregatorId: '0x16' },
    { symbol: 'TYPUS/USDC', aggregatorId: '0x17' },
    { symbol: 'WAL/USDC', aggregatorId: '0x18' },
  ],
  oracleMaxAgeSec: 30,
  usdu: undefined,
  lendingMarkets: [
    {
      collat: '::unxv::UNXV',
      debt: '::usdu::USDU',
      symbol: 'UNXV/USDC',
      baseRateBps: 50,
      multiplierBps: 800,
      jumpMultiplierBps: 3500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8000,
      liquidationBonusBps: 1000,
    },
  ],
  lendingMarkets: [
    // Blue-chip assets
    {
      name: 'SUI',
      asset: '0x2::sui::SUI',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationCollateralBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      name: 'DEEP',
      asset: '0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationCollateralBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      name: 'suiETH',
      asset: '0xd0e89b2af5e4910726fbcd8b8dd37bb79b29e5f83f7491bca830e94f7f226d29::eth::ETH',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationCollateralBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      name: 'suiBTC',
      asset: '0xaafb102dd0902f5055cadecd687fb5b71ca82ef0e0285d90afde828ec58ca96b::btc::BTC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationCollateralBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      name: 'suiUSDT',
      asset: '0x375f70cf2ae4c00bf37117d0c85a2c71545e6ee05c4a5c7d282cd66a4504b068::usdt::USDT',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationCollateralBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      name: 'WBTC',
      asset: '0x027792d9fed7f9844eb4839566001bb6f6cb4804f66aa2da6fe1ee242d896881::coin::COIN',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationCollateralBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      name: 'WETH',
      asset: '0xaf8cd5edc19c4512f4259f0bee101a40d41ebed738ade5874359610ef8eeced5::coin::COIN',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationCollateralBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      name: 'WAVAX',
      asset: '0x1e8b532cca6569cab9f9b9ebc73f8c13885012ade714729aa3b450e0339ac766::coin::COIN',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationCollateralBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      name: 'WBNB',
      asset: '0xb848cce11ef3a8f62eccea6eb5b35a12c4c2b1ee1af7755d02d7bd6218e8226f::coin::COIN',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationCollateralBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      name: 'WAVAX',
      asset: '0x1e8b532cca6569cab9f9b9ebc73f8c13885012ade714729aa3b450e0339ac766::coin::COIN',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationCollateralBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      name: 'WFTM',
      asset: '0x6081300950a4f1e2081580e919c210436a1bed49080502834950d31ee55a2396::coin::COIN',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationCollateralBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      name: 'WGLMR',
      asset: '0x66f87084e49c38f76502d17f87d17f943f183bb94117561eb573e075fdc5ff75::coin::COIN',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationCollateralBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      name: 'WAVAX',
      asset: '0x1e8b532cca6569cab9f9b9ebc73f8c13885012ade714729aa3b450e0339ac766::coin::COIN',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationCollateralBps: 8500,
      liquidationBonusBps: 4000,
    },
    // Stablecoins
    {
      name: 'Native USDC', // native sui usdc
      asset: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 800,
      jumpMultiplierBps: 3500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 8500,
      liquidationCollateralBps: 9200,
      liquidationBonusBps: 4000,
    },
    {
      name: 'Wrapped USDC',
      asset: '0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN',
      baseRateBps: 50,
      multiplierBps: 800,
      jumpMultiplierBps: 3500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 8500,
      liquidationCollateralBps: 9200,
      liquidationBonusBps: 4000,
    },
    {
      name: 'Wrapped USDT',
      asset: '0xc060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c::coin::COIN',
      baseRateBps: 50,
      multiplierBps: 800,
      jumpMultiplierBps: 3500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 8500,
      liquidationCollateralBps: 9200,
      liquidationBonusBps: 4000,
    },
    {
      name: 'Solana USDC',
      asset: '0xb231fcda8bbddb31f2ef02e6161444aec64a514e2c89279584ac9806ce9cf037::coin::COIN',
      baseRateBps: 50,
      multiplierBps: 800,
      jumpMultiplierBps: 3500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 8500,
      liquidationCollateralBps: 9200,
      liquidationBonusBps: 4000,
    },
    // Other
    {
      name: 'Solana USDC',
      asset: '0xb231fcda8bbddb31f2ef02e6161444aec64a514e2c89279584ac9806ce9cf037::coin::COIN',
      baseRateBps: 50,
      multiplierBps: 800,
      jumpMultiplierBps: 3500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 8500,
      liquidationCollateralBps: 9200,
      liquidationBonusBps: 4000,
    },
  ],
  options: [],
  futures: [],
  gasFutures: [],
  perpetuals: [],
  dexPools: [],
  vaults: [],
};
