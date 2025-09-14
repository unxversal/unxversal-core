import type { OptionsComponentProps, OptionChainRow, OptionsSummary, OpenInterestByExpiry, PositionRow, UserOrderRow, TradeFill, OrderHistoryRow } from './types';
import { getTokenBySymbol, loadSettings } from '../../lib/settings.config';

export function makeMockOptionsData(args?: {
  symbol?: string;
  quote?: string;
  expiries?: number[];
}): OptionsComponentProps {
  const settings = loadSettings();
  const symbol = args?.symbol ?? 'SUI/USDC';
  const quote = args?.quote ?? 'USDC';
  const expiries = args?.expiries ?? [Date.now() + 3*86400000, Date.now() + 7*86400000, Date.now() + 14*86400000];

  const baseSym = symbol.split('/')[0] ?? 'SUI';
  const baseIcon = getTokenBySymbol(baseSym, settings)?.iconUrl ?? '';

  const summary: OptionsSummary = {
    last: 1.02,
    vol24h: 125000,
    high24h: 1.12,
    low24h: 0.91,
    change24h: 2.15,
    openInterest: 4800,
    iv30: 0.54,
    nextExpiry: expiries[0],
  };

  const strikes = [0.8, 0.9, 1.0, 1.1, 1.2];
  const chainRows: OptionChainRow[] = strikes.map((s, i) => ({
    strike: s,
    callBid: i % 2 === 0 ? Number((0.05 + Math.random()*0.02).toFixed(6)) : null,
    callAsk: Number((0.06 + Math.random()*0.02).toFixed(6)),
    putBid: i % 2 === 1 ? Number((0.05 + Math.random()*0.02).toFixed(6)) : null,
    putAsk: Number((0.06 + Math.random()*0.02).toFixed(6)),
    openInterest: Math.floor(50 + Math.random()*150),
    volume: Math.floor(10 + Math.random()*50),
    changePercent: Number((Math.random()*4 - 2).toFixed(2)),
  }));

  const oiByExpiry: OpenInterestByExpiry[] = expiries.map((e, i) => ({ expiryMs: e, oiUnits: 1000 + i*250 }));

  const positions: PositionRow[] = [
    {
      positionId: 'pos-1',
      seriesKey: 'k1',
      amountUnits: 3,
      expiryMs: expiries[0],
      isCall: true,
      strike1e6: 1100000,
      entryPriceQuote: 0.06,
      markPriceQuote: 0.08,
      pnlQuote: 0.06,
    },
    {
      positionId: 'pos-2',
      seriesKey: 'k2',
      amountUnits: -2,
      expiryMs: expiries[1],
      isCall: false,
      strike1e6: 950000,
      entryPriceQuote: 0.04,
      markPriceQuote: 0.02,
      pnlQuote: 0.04,
    },
    {
      positionId: 'pos-3',
      seriesKey: 'k3',
      amountUnits: 5,
      expiryMs: expiries[2],
      isCall: true,
      strike1e6: 1200000,
      entryPriceQuote: 0.03,
      markPriceQuote: 0.05,
      pnlQuote: 0.10,
    },
  ];

  const openOrders: UserOrderRow[] = [
    { orderId: 'o1', seriesKey: 'k1', isBid: true, priceQuote: 0.07, qtyRemaining: 2, expiryMs: expiries[0], status: 'open' },
    { orderId: 'o2', seriesKey: 'k2', isBid: false, priceQuote: 0.05, qtyRemaining: 1, expiryMs: expiries[1], status: 'open' },
    { orderId: 'o3', seriesKey: 'k3', isBid: true, priceQuote: 0.04, qtyRemaining: 3, expiryMs: expiries[2], status: 'pending' },
  ];

  const tradeHistory: TradeFill[] = [
    { maker: '0x1abc', taker: '0x2def', priceQuote: 0.07, baseQty: 1, tsMs: Date.now() - 60000 },
    { maker: '0x3ghi', taker: '0x2def', priceQuote: 0.08, baseQty: 2, tsMs: Date.now() - 120000 },
    { maker: '0x4jkl', taker: '0x5mno', priceQuote: 0.06, baseQty: 3, tsMs: Date.now() - 180000 },
    { maker: '0x6pqr', taker: '0x7stu', priceQuote: 0.09, baseQty: 1, tsMs: Date.now() - 240000 },
    { maker: '0x8vwx', taker: '0x9yza', priceQuote: 0.05, baseQty: 4, tsMs: Date.now() - 300000 },
  ];

  const orderHistory: OrderHistoryRow[] = [
    { kind: 'placed', orderId: 'o1', seriesKey: 'k1', tsMs: Date.now() - 180000 },
    { kind: 'filled', orderId: 'o1', seriesKey: 'k1', tsMs: Date.now() - 60000, delta: { qty: 1 } },
    { kind: 'placed', orderId: 'o2', seriesKey: 'k2', tsMs: Date.now() - 240000 },
    { kind: 'cancelled', orderId: 'o4', seriesKey: 'k4', tsMs: Date.now() - 300000 },
    { kind: 'filled', orderId: 'o5', seriesKey: 'k5', tsMs: Date.now() - 360000, delta: { qty: 2 } },
  ];

  const props: OptionsComponentProps = {
    selectedSymbol: symbol,
    allSymbols: [symbol, 'UNXV/USDC', 'WETH/USDC'],
    onSelectSymbol: () => {},
    symbolIconMap: { [symbol]: baseIcon },
    selectedExpiryMs: expiries[0],
    availableExpiriesMs: expiries,
    onSelectExpiry: () => {},

    marketId: '0xMARKET',
    feeConfigId: '0xFEE_CFG',
    feeVaultId: '0xFEE_VAULT',
    stakingPoolId: '0xPOOL',
    rewardsId: '0xREWARDS',
    pythSymbol: symbol,

    summary,
    oiByExpiry,

    chainRows,
    underlyingPrice: summary.last,

    positions,
    openOrders,
    tradeHistory,
    orderHistory,
    portfolioSummary: { premiumPaidQuote: '0.00', premiumReceivedQuote: '0.00' },
    leaderboardRank: null,
    leaderboardPoints: null,

    onPlaceBuyOrder: async () => {},
    onPlaceSellOrder: async () => {},
    onCancelOrder: async () => {},
    onExercise: async () => {},
    onSettleAfterExpiry: async () => {},
  };

  return props;
}
