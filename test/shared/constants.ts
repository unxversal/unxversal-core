export const TEST_CONSTANTS = {
  // Token amounts (using 18 decimals unless specified)
  TOKENS: {
    INITIAL_SUPPLY: "1000000000000000000000000000", // 1B tokens
    USDC_DECIMALS: 6,
    USDC_UNIT: "1000000", // 1 USDC
    ETH_UNIT: "1000000000000000000", // 1 ETH
    BTC_UNIT: "100000000", // 1 BTC (8 decimals)
  },

  // Time constants
  TIME: {
    WEEK: 7 * 24 * 60 * 60,
    MONTH: 30 * 24 * 60 * 60,
    YEAR: 365 * 24 * 60 * 60,
    HOUR: 60 * 60,
    DAY: 24 * 60 * 60,
  },

  // Lending parameters
  LENDING: {
    INITIAL_EXCHANGE_RATE: "20000000000000000", // 0.02 (2%)
    DEFAULT_COLLATERAL_FACTOR: 7500, // 75%
    DEFAULT_LIQUIDATION_THRESHOLD: 8000, // 80%
    DEFAULT_LIQUIDATION_BONUS: 500, // 5%
    DEFAULT_RESERVE_FACTOR: 1000, // 10%
    CLOSE_FACTOR: 5000, // 50%
  },

  // Options parameters
  OPTIONS: {
    DEFAULT_STRIKE_PRICE: "2000000000000000000000", // $2000
    DEFAULT_PREMIUM: "100000000000000000000", // $100
    DEFAULT_EXPIRY_DAYS: 30,
    MIN_EXERCISE_VALUE: "1000000", // $1 USDC
  },

  // Perps parameters
  PERPS: {
    DEFAULT_MAX_LEVERAGE: 2000, // 20x
    DEFAULT_IMR: 500, // 5%
    DEFAULT_MMR: 250, // 2.5%
    DEFAULT_LIQUIDATION_FEE: 100, // 1%
    DEFAULT_TAKER_FEE: 30, // 0.3%
    DEFAULT_MAKER_FEE: 10, // 0.1%
    FUNDING_INTERVAL: 3600, // 1 hour
    MAX_FUNDING_RATE: 75, // 0.75%
  },

  // Governance parameters
  GOVERNANCE: {
    VOTING_PERIOD: 50400, // ~1 week in blocks
    VOTING_DELAY: 1, // 1 block
    PROPOSAL_THRESHOLD: 100, // 1% of supply
    QUORUM: 400, // 4% of supply
    TIMELOCK_DELAY: 48 * 60 * 60, // 48 hours
    MIN_LOCK_TIME: 7 * 24 * 60 * 60, // 1 week
    MAX_LOCK_TIME: 4 * 365 * 24 * 60 * 60, // 4 years
  },

  // Gauge parameters
  GAUGE: {
    EPOCH_DURATION: 7 * 24 * 60 * 60, // 1 week
    MIN_GAUGE_WEIGHT: 100, // 1%
    MAX_GAUGE_WEIGHT: 5000, // 50%
  },

  // VeUNXV parameters
  VEUNXV: {
    MAX_LOCK_TIME: 4 * 365 * 24 * 60 * 60, // 4 years
    MIN_LOCK_TIME: 7 * 24 * 60 * 60, // 1 week
    WEEK: 7 * 24 * 60 * 60,
  },

  // Fee parameters
  FEES: {
    BPS_DENOMINATOR: 10000,
    TREASURY_FEE: 7000, // 70%
    INSURANCE_FEE: 2000, // 20%
    PROTOCOL_FEE: 1000, // 10%
  },

  // Oracle prices (18 decimals USD)
  PRICES: {
    ETH: "2000000000000000000000", // $2000
    BTC: "40000000000000000000000", // $40000
    USDC: "1000000000000000000", // $1
    LINK: "15000000000000000000", // $15
  },

  // Addresses (placeholder addresses for testing)
  ADDRESSES: {
    ZERO: "0x0000000000000000000000000000000000000000",
    DEAD: "0x000000000000000000000000000000000000dEaD",
    USDC_MAINNET: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    WETH_MAINNET: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  },

  // Test user roles
  ROLES: {
    ADMIN: 0,
    USER: 1,
    LIQUIDATOR: 2,
    TREASURY: 3,
    GUARDIAN: 4,
    MINTER: 5,
    BURNER: 6,
  },
};

// Helper functions for calculations
export const calculateWithBPS = (amount: bigint, bps: number): bigint => {
  return (amount * BigInt(bps)) / BigInt(TEST_CONSTANTS.FEES.BPS_DENOMINATOR);
};

export const toUsdc = (amount: string): string => {
  return (BigInt(amount) * BigInt(TEST_CONSTANTS.TOKENS.USDC_UNIT)).toString();
};

export const toEth = (amount: string): string => {
  return (BigInt(amount) * BigInt(TEST_CONSTANTS.TOKENS.ETH_UNIT)).toString();
};

export const addTime = (timeInSeconds: number): number => {
  return Math.floor(Date.now() / 1000) + timeInSeconds;
}; 