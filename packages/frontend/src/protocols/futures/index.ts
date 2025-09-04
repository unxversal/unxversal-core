import type { IndexerTracker } from '../../lib/indexer';
import { moveModuleFilter } from '../common';
export { FuturesClient } from './client';
export * as FuturesEvents from './events';
export { createFuturesKeeper } from './keeper';

export function futuresEventTracker(pkg: string): IndexerTracker {
  return { id: `futures:${pkg}`, filter: moveModuleFilter(pkg, 'futures'), pageLimit: 200 };
}