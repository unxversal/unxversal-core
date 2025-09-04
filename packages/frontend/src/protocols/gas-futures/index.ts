import type { IndexerTracker } from '../../lib/indexer';
import { moveModuleFilter } from '../common';
export { GasFuturesClient } from './client';
export * as GasFuturesEvents from './events';
export { createGasFuturesKeeper } from './keeper';

export function gasFuturesEventTracker(pkg: string): IndexerTracker {
  return { id: `gas-futures:${pkg}`, filter: moveModuleFilter(pkg, 'gas_futures'), pageLimit: 200 };
}


