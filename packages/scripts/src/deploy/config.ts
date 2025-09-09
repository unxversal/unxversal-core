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
  oracleFeeds?: Array<{ symbol: string; priceId: string }>;
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
    { symbol: 'SUI/USDC', priceId: '0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744' },
    { symbol: 'DEEP/USDC', priceId: '0x29bdd5248234e33bd93d3b81100b5fa32eaa5997843847e2c2cb16d7c6d9f7ff' },
    { symbol: 'ETH/USDC', priceId: '0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace' },
    { symbol: 'BTC/USDC', priceId: '0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43' },
    { symbol: 'SOL/USDC', priceId: '0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d' },
    { symbol: 'GLMR/USDC', priceId: '0x309d39a65343d45824f63dc6caa75dbf864834f48cfaa6deb122c62239e06474' },
    { symbol: 'MATIC/USDC', priceId: '0xffd11c5a1cfd42f80afb2df4d9f264c15f956d68153335374ec10722edd70472' },
    { symbol: 'APT/USDC', priceId: '0x03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5' },
    { symbol: 'CELO/USDC', priceId: '0x7d669ddcdd23d9ef1fa9a9cc022ba055ec900e91c4cb960f3c20429d4447a411' },
    { symbol: 'IKA/USDC', priceId: '0x2b529621fa6e2c8429f623ba705572aa64175d7768365ef829df6a12c9f365f4' },
    { symbol: 'NS/USDC', priceId: '0xbb5ff26e47a3a6cc7ec2fce1db996c2a145300edc5acaabe43bf9ff7c5dd5d32' },
    { symbol: 'SEND/USDC', priceId: '0x7d19b607c945f7edf3a444289c86f7b58dcd8b18df82deadf925074807c99b59' },
    { symbol: 'WAL/USDC', priceId: '0xeba0732395fae9dec4bae12e52760b35fc1c5671e2da8b449c9af4efe5d54341' },
    { symbol: 'USDT/USDC', priceId: '0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b' },
    { symbol: 'WBNB/USDC', priceId: '0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f' },
  ],
  oracleMaxAgeSec: 30,
  usdu: undefined,
  lendingMarkets: [
    // Blue-chip assets
    {
      symbol: 'SUI/USDC',
      collat: '0x2::sui::SUI',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'DEEP/USDC',
      collat: '0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'suiETH/USDC',
      collat: '0xd0e89b2af5e4910726fbcd8b8dd37bb79b29e5f83f7491bca830e94f7f226d29::eth::ETH',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'suiBTC/USDC',
      collat: '0xaafb102dd0902f5055cadecd687fb5b71ca82ef0e0285d90afde828ec58ca96b::btc::BTC',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WBTC/USDC',
      collat: '0x027792d9fed7f9844eb4839566001bb6f6cb4804f66aa2da6fe1ee242d896881::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WETH/USDC',
      collat: '0xaf8cd5edc19c4512f4259f0bee101a40d41ebed738ade5874359610ef8eeced5::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WAVAX/USDC',
      collat: '0x1e8b532cca6569cab9f9b9ebc73f8c13885012ade714729aa3b450e0339ac766::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WBNB/USDC',
      collat: '0xb848cce11ef3a8f62eccea6eb5b35a12c4c2b1ee1af7755d02d7bd6218e8226f::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WGLMR/USDC',
      collat: '0x66f87084e49c38f76502d17f87d17f943f183bb94117561eb573e075fdc5ff75::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WMATIC/USDC',
      collat: '0xdbe380b13a6d0f5cdedd58de8f04625263f113b3f9db32b3e1983f49e2841676::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WSOL/USDC',
      collat: '0xb7844e289a8410e50fb3ca48d69eb9cf29e27d223ef90353fe1bd8e27ff8f3f8::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'XBTC/USDC',
      collat: '0x876a4b7bce8aeaef60464c11f4026903e9afacab79b9b142686158aa86560b50::xbtc::XBTC',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'APT/USDC',
      collat: '0x3a5143bb1196e3bcdfab6203d1683ae29edd26294fc8bfeafe4aaa9d2704df37::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'CELO/USDC',
      collat: '0xa198f3be41cda8c07b3bf3fee02263526e535d682499806979a111e88a5a8d0f::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'IKA/USDC',
      collat: '0x7262fb2f7a3a14c888c438a3cd9b912469a58cf60f367352c46584262e8299aa::ika::IKA',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'NS/USDC',
      collat: '0x5145494a5f5100e645e4b0aa950fa6b68f614e8c59e17bc5ded3495123a79178::ns::NS',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'SEND/USDC',
      collat: '0x4e9d6f1c3d3f6b8e2c1c3f4e5d6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f::send::SEND',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WAL/USDC',
      collat: '0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59::wal::WAL',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    // Stablecoins
    {
      symbol: 'Wrapped USDT/USDC',
      collat: '0xc060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 800,
      jumpMultiplierBps: 3500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 8500,
      liquidationThresholdBps: 9200,
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
