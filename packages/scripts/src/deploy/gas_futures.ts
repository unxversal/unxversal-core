import type { DeployConfig } from './types.js';
import { generateGasFuturesMarkets } from './series.js';

export function buildMainnetGasFutures(): NonNullable<DeployConfig['gasFutures']> {
  return generateGasFuturesMarkets({
    collat: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    contractSize: 1_000_000,
    initialMarginBps: 1000,
    maintenanceMarginBps: 600,
    liquidationFeeBps: 100,
    keeperIncentiveBps: 2000,
    tickSize: 1,
    lotSize: 1,
    minSize: 1,
    years: 1,
    interval: 'weekly',
    weeklyOn: 5,
    expiryHourUTC: 0,
    maxMarkets: 6,
    liqTargetBufferBps: 100,
  });
}

export function buildTestnetGasFutures(): NonNullable<DeployConfig['gasFutures']> {
  return generateGasFuturesMarkets({
    collat: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    contractSize: 1_000_000,
    initialMarginBps: 1000,
    maintenanceMarginBps: 600,
    liquidationFeeBps: 100,
    keeperIncentiveBps: 2000,
    tickSize: 1,
    lotSize: 1,
    minSize: 1,
    years: 1,
    interval: 'weekly',
    weeklyOn: 5,
    expiryHourUTC: 0,
    maxMarkets: 6,
    liqTargetBufferBps: 100,
  });
}