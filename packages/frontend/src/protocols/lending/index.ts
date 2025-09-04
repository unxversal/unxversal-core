import type { IndexerTracker } from '../../lib/indexer';
import { moveModuleFilter } from '../common';
export { LendingClient } from './client';
export * as LendingEvents from './events';
export { createLendingKeeper } from './keeper';

export function lendingEventTracker(pkg: string): IndexerTracker {
  return { id: `lending:${pkg}`, filter: moveModuleFilter(pkg, 'lending'), pageLimit: 200 };
}


