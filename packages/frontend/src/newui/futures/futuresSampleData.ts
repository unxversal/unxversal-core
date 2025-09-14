import type { FuturesComponentProps } from './types';

export const futuresSampleProps: FuturesComponentProps = {
  // selection/meta
  selectedSymbol: 'SUI/USDC',
  allSymbols: ['SUI/USDC', 'WETH/USDC', 'WBTC/USDC'],
  onSelectSymbol: () => {},
  symbolIconMap: {},
  selectedExpiryMs: Date.now() + 7 * 24 * 3600 * 1000,
  availableExpiriesMs: [Date.now() + 7 * 24 * 3600 * 1000, Date.now() + 30 * 24 * 3600 * 1000],
  onSelectExpiry: () => {},

  marketId: '0xMARKET',
  feeConfigId: '0xFEE_CFG',
  feeVaultId: '0xFEE_VAULT',
  stakingPoolId: '0xSTAKING',
  rewardsId: '0xREWARDS',

  summary: { last: 1.2345, change24h: 2.34, vol24h: 1234567, openInterest: 98765, expiryMs: Date.now() + 7 * 24 * 3600 * 1000, timeToExpiryMs: 7 * 24 * 3600 * 1000, twap5m: 1.2333 },
  orderBook: { bids: Array.from({ length: 12 }, (_, i) => ({ price: 1.234 - i * 0.001, qty: 1000 * (i + 1) })), asks: Array.from({ length: 12 }, (_, i) => ({ price: 1.235 + i * 0.001, qty: 1000 * (i + 1) })) },
  recentTrades: Array.from({ length: 20 }, (_, i) => ({ maker: '0xMAKER', taker: '0xTAKER', priceQuote: 1.234 + (i % 3) * 0.0002, baseQty: 10 + i, tsMs: Date.now() - i * 60000 })),

  initialMarginBps: 500,
  maintenanceMarginBps: 300,
  maxLeverage: 20,

  positions: [
    { marketId: '0xMARKET', symbol: 'SUI/USDC', expiryMs: Date.now() + 7 * 24 * 3600 * 1000, contractSize: 1, longQty: 5, shortQty: 0, avgLong1e6: 1_200_000, avgShort1e6: 0, markPrice1e6: 1_235_000, pnlQuote: 1.75, health: { equityQuote: 100, imRequiredQuote: 10, mmRequiredQuote: 6, healthRatio: 2.3, leverage: 3.2 } },
  ],
  openOrders: [
    { orderId: '123', marketId: '0xMARKET', isBid: true, priceQuote: 1.2301, qtyRemaining: 12, expireTs: Date.now() + 3600 * 1000, status: 'open' },
  ],
  tradeHistory: Array.from({ length: 12 }, (_, i) => ({ maker: '0xMAKER', taker: '0xTAKER', priceQuote: 1.234 + (i % 3) * 0.0002, baseQty: 10 + i, tsMs: Date.now() - i * 360000 })),
  orderHistory: [
    { kind: 'placed', orderId: '123', marketId: '0xMARKET', tsMs: Date.now() - 60000 },
  ],
  leaderboardRank: 42,
  leaderboardPoints: 12345,
  walletStakingSummary: { staked: '1,234 UNXV', aprPct: 18.5 },

  // actions
  onOpenLong: async () => {},
  onOpenShort: async () => {},
  onCloseLong: async () => {},
  onCloseShort: async () => {},
  onCancelOrder: async () => {},
  onDepositCollateral: async () => {},
  onWithdrawCollateral: async () => {},
};


