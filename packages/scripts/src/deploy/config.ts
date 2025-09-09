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
   * Initialize lending pools (isolated, per asset)
   */
  lending?: Array<{
    poolId?: string;
    asset: TypeTag;
    baseRateBps: number;
    multiplierBps: number;
    jumpMultiplierBps: number;
    kinkUtilBps: number;
    reserveFactorBps: number;
    collateralFactorBps: number;
    liquidationCollateralBps: number;
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
  lending: [
    // Example defaults; replace pkgId at runtime via resolveTypeTag
    {
      asset: 'SUI',
      baseRateBps: 0,
      multiplierBps: 700,
      jumpMultiplierBps: 3000,
      kinkUtilBps: 8000,
      reserveFactorBps: 1000,
      collateralFactorBps: 8000,
      liquidationCollateralBps: 7000,
      liquidationBonusBps: 800,
    },
    {
      asset: '::unxv::UNXV',
      baseRateBps: 0,
      multiplierBps: 600,
      jumpMultiplierBps: 2500,
      kinkUtilBps: 8000,
      reserveFactorBps: 1000,
      collateralFactorBps: 7500,
      liquidationCollateralBps: 7000,
      liquidationBonusBps: 800,
    },
  ],
  options: [],
  futures: [],
  gasFutures: [],
  perpetuals: [],
  dexPools: [],
  vaults: [],
};
