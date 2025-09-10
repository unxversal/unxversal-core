import type { SuiTypeTag, Tier, RiskParams } from './types.js';
import type { Policy } from '../utils/series.js';

export const DERIVATIVE_SYMBOLS: string[] = [
  'BTC/USDC',
  'ETH/USDC',
  'SOL/USDC',
  'WBNB/USDC',
  'SUI/USDC',
  'MATIC/USDC',
  'APT/USDC',
  'CELO/USDC',
  'GLMR/USDC',
  'DEEP/USDC',
  'IKA/USDC',
  'NS/USDC',
  'SEND/USDC',
  'WAL/USDC',
];

export const POLICIES: Record<string, Policy> = {
  // Majors
  'BTC/USDC':  { bandLow: 0.5, bandHigh: 2.0, stepAbs: 500, cadence: 'weekly', years: 2 },
  'ETH/USDC':  { bandLow: 0.5, bandHigh: 2.0, stepAbs: 25,  cadence: 'weekly', years: 2 },

  // L1s / high caps
  'SOL/USDC':  { bandLow: 0.5, bandHigh: 2.0, stepAbs: 0.5, cadence: 'weekly', years: 2 },
  'WBNB/USDC': { bandLow: 0.6, bandHigh: 1.8, stepAbs: 1,   cadence: 'weekly', years: 2 },
  'SUI/USDC':  { bandLow: 0.5, bandHigh: 2.0, stepAbs: 0.01, cadence: 'weekly', years: 2 },
  'MATIC/USDC':{ bandLow: 0.5, bandHigh: 2.0, stepAbs: 0.02, cadence: 'weekly', years: 2 },
  'APT/USDC':  { bandLow: 0.5, bandHigh: 2.0, stepAbs: 0.05, cadence: 'weekly', years: 2 },
  'CELO/USDC': { bandLow: 0.5, bandHigh: 2.0, stepAbs: 0.02, cadence: 'weekly', years: 2 },
  'GLMR/USDC': { bandLow: 0.5, bandHigh: 2.0, stepAbs: 0.02, cadence: 'weekly', years: 2 },

  // Long tail / ecosystem
  'DEEP/USDC': { bandLow: 0.4, bandHigh: 2.5, stepPct: 0.02, cadence: 'weekly', years: 2 },
  'IKA/USDC':  { bandLow: 0.4, bandHigh: 2.5, stepPct: 0.02, cadence: 'weekly', years: 2 },
  'NS/USDC':   { bandLow: 0.4, bandHigh: 2.5, stepPct: 0.02, cadence: 'weekly', years: 2 },
  'SEND/USDC': { bandLow: 0.4, bandHigh: 2.5, stepPct: 0.02, cadence: 'weekly', years: 2 },
  'WAL/USDC':  { bandLow: 0.4, bandHigh: 2.5, stepPct: 0.02, cadence: 'weekly', years: 2 },
};

export const MAINNET_DERIVATIVE_TYPE_TAGS: Record<string, {
  base: SuiTypeTag;
  quote: SuiTypeTag;
  tickSize: number;
  lotSize: number;
  minSize: number;
  baseDecimals: number;
  quoteDecimals: number;
}> = {
  // Majors
  'BTC/USDC': {
    base: '0xaafb102dd0902f5055cadecd687fb5b71ca82ef0e0285d90afde828ec58ca96b::btc::BTC',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 10_000_000,
    minSize: 10_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'ETH/USDC': {
    base: '0xd0e89b2af5e4910726fbcd8b8dd37bb79b29e5f83f7491bca830e94f7f226d29::eth::ETH',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 200_000_000,
    minSize: 200_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },

  // L1s / High Caps
  'SOL/USDC': {
    base: '0xb7844e289a8410e50fb3ca48d69eb9cf29e27d223ef90353fe1bd8e27ff8f3f8::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 4_000_000_000,
    minSize: 4_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'WBNB/USDC': {
    base: '0xb848cce11ef3a8f62eccea6eb5b35a12c4c2b1ee1af7755d02d7bd6218e8226f::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 1_000_000_000,
    minSize: 1_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'SUI/USDC': {
    base: '0x2::sui::SUI',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 2_000_000_000_000,
    minSize: 2_000_000_000_000,
    baseDecimals: 9,
    quoteDecimals: 6,
  },
  'MATIC/USDC': {
    base: '0xdbe380b13a6d0f5cdedd58de8f04625263f113b3f9db32b3e1983f49e2841676::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 3_000_000_000_000,
    minSize: 3_000_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'APT/USDC': {
    base: '0x3a5143bb1196e3bcdfab6203d1683ae29edd26294fc8bfeafe4aaa9d2704df37::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 2_000_000_000_000,
    minSize: 2_000_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'CELO/USDC': {
    base: '0xa198f3be41cda8c07b3bf3fee02263526e535d682499806979a111e88a5a8d0f::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 3_000_000_000_000,
    minSize: 3_000_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'GLMR/USDC': {
    base: '0x66f87084e49c38f76502d17f87d17f943f183bb94117561eb573e075fdc5ff75::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 14_000_000_000_000,
    minSize: 14_000_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },

  // Long-Tail / Ecosystem
  'DEEP/USDC': {
    base: '0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 10_000_000_000,
    minSize: 10_000_000_000,
    baseDecimals: 6,
    quoteDecimals: 6,
  },
  'IKA/USDC': {
    base: '0x7262fb2f7a3a14c888c438a3cd9b912469a58cf60f367352c46584262e8299aa::ika::IKA',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 20_000_000_000_000,
    minSize: 20_000_000_000_000,
    baseDecimals: 9,
    quoteDecimals: 6,
  },
  'NS/USDC': {
    base: '0x5145494a5f5100e645e4b0aa950fa6b68f614e8c59e17bc5ded3495123a79178::ns::NS',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 10_000_000_000,
    minSize: 10_000_000_000,
    baseDecimals: 6,
    quoteDecimals: 6,
  },
  'SEND/USDC': {
    base: '0x4e9d6f1c3d3f6b8e2c1c3f4e5d6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f::send::SEND',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 10_000_000_000,
    minSize: 10_000_000_000,
    baseDecimals: 6,
    quoteDecimals: 6,
  },
  'WAL/USDC': {
    base: '0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59::wal::WAL',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 10_000_000_000_000,
    minSize: 10_000_000_000_000,
    baseDecimals: 9,
    quoteDecimals: 6,
  },
};

export const TESTNET_DERIVATIVE_TYPE_TAGS: Record<string, {
  base: SuiTypeTag;
  quote: SuiTypeTag;
  tickSize: number;
  lotSize: number;
  minSize: number;
  baseDecimals: number;
  quoteDecimals: number;
}> = {
  // Majors
  'BTC/USDC': {
    base: '0xaafb102dd0902f5055cadecd687fb5b71ca82ef0e0285d90afde828ec58ca96b::btc::BTC',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 10_000_000,
    minSize: 10_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'ETH/USDC': {
    base: '0xd0e89b2af5e4910726fbcd8b8dd37bb79b29e5f83f7491bca830e94f7f226d29::eth::ETH',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 200_000_000,
    minSize: 200_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },

  // L1s / High Caps
  'SOL/USDC': {
    base: '0xb7844e289a8410e50fb3ca48d69eb9cf29e27d223ef90353fe1bd8e27ff8f3f8::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 4_000_000_000,
    minSize: 4_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'WBNB/USDC': {
    base: '0xb848cce11ef3a8f62eccea6eb5b35a12c4c2b1ee1af7755d02d7bd6218e8226f::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 1_000_000_000,
    minSize: 1_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'SUI/USDC': {
    base: '0x2::sui::SUI',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 2_000_000_000_000,
    minSize: 2_000_000_000_000,
    baseDecimals: 9,
    quoteDecimals: 6,
  },
  'MATIC/USDC': {
    base: '0xdbe380b13a6d0f5cdedd58de8f04625263f113b3f9db32b3e1983f49e2841676::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 3_000_000_000_000,
    minSize: 3_000_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'APT/USDC': {
    base: '0x3a5143bb1196e3bcdfab6203d1683ae29edd26294fc8bfeafe4aaa9d2704df37::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 2_000_000_000_000,
    minSize: 2_000_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'CELO/USDC': {
    base: '0xa198f3be41cda8c07b3bf3fee02263526e535d682499806979a111e88a5a8d0f::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 3_000_000_000_000,
    minSize: 3_000_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'GLMR/USDC': {
    base: '0x66f87084e49c38f76502d17f87d17f943f183bb94117561eb573e075fdc5ff75::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 14_000_000_000_000,
    minSize: 14_000_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },

  // Long-Tail / Ecosystem
  'DEEP/USDC': {
    base: '0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 10_000_000_000,
    minSize: 10_000_000_000,
    baseDecimals: 6,
    quoteDecimals: 6,
  },
  'IKA/USDC': {
    base: '0x7262fb2f7a3a14c888c438a3cd9b912469a58cf60f367352c46584262e8299aa::ika::IKA',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 20_000_000_000_000,
    minSize: 20_000_000_000_000,
    baseDecimals: 9,
    quoteDecimals: 6,
  },
  'NS/USDC': {
    base: '0x5145494a5f5100e645e4b0aa950fa6b68f614e8c59e17bc5ded3495123a79178::ns::NS',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 10_000_000_000,
    minSize: 10_000_000_000,
    baseDecimals: 6,
    quoteDecimals: 6,
  },
  'SEND/USDC': {
    base: '0x4e9d6f1c3d3f6b8e2c1c3f4e5d6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f::send::SEND',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 10_000_000_000,
    minSize: 10_000_000_000,
    baseDecimals: 6,
    quoteDecimals: 6,
  },
  'WAL/USDC': {
    base: '0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59::wal::WAL',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 10_000_000_000_000,
    minSize: 10_000_000_000_000,
    baseDecimals: 9,
    quoteDecimals: 6,
  },
};

export const FUTURES_TIERS: Record<string, Tier> = {
  'BTC/USDC': 'A',
  'ETH/USDC': 'A',
  'SOL/USDC': 'A',
  'WBNB/USDC': 'A',
  'SUI/USDC': 'A',
  'MATIC/USDC': 'A',
  'APT/USDC': 'B',
  'CELO/USDC': 'C',
  'GLMR/USDC': 'C',
  'DEEP/USDC': 'C',
  'IKA/USDC': 'C',
  'NS/USDC': 'C',
  'SEND/USDC': 'C',
  'WAL/USDC': 'C',
};

export const TIER_PARAMS: Record<Tier, RiskParams> = {
  A: {
    initialMarginBps: 500,
    maintenanceMarginBps: 300,
    liquidationFeeBps: 50,
    keeperIncentiveBps: 5000,
    accountMaxNotional1e6: '50_000_000_000_000',
    marketMaxNotional1e6: '5_000_000_000_000_000',
    accountShareOfOiBps: 500,
    liqTargetBufferBps: 500,
  },
  B: {
    initialMarginBps: 600,
    maintenanceMarginBps: 400,
    liquidationFeeBps: 50,
    keeperIncentiveBps: 5000,
    accountMaxNotional1e6: '20_000_000_000_000',
    marketMaxNotional1e6: '1_000_000_000_000_000',
    accountShareOfOiBps: 600,
    liqTargetBufferBps: 500,
  },
  C: {
    initialMarginBps: 800,
    maintenanceMarginBps: 500,
    liquidationFeeBps: 100,
    keeperIncentiveBps: 5000,
    accountMaxNotional1e6: '5_000_000_000_000',
    marketMaxNotional1e6: '500_000_000_000_000',
    accountShareOfOiBps: 800,
    liqTargetBufferBps: 500,
  },
  D: {
    initialMarginBps: 1200,
    maintenanceMarginBps: 800,
    liquidationFeeBps: 100,
    keeperIncentiveBps: 5000,
    accountMaxNotional1e6: '1_000_000_000_000',
    marketMaxNotional1e6: '10_000_000_000_000',
    accountShareOfOiBps: 1000,
    liqTargetBufferBps: 500,
  },
};


