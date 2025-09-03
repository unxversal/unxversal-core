import type { IndexerTracker } from '../../lib/indexer';
import { moveModuleFilter } from '../common';
export { DexClient } from './dex';
export * as DexEvents from './dex-events';

export function dexEventTracker(pkg: string): IndexerTracker {
  return { id: `dex:${pkg}`, filter: moveModuleFilter(pkg, 'dex'), pageLimit: 200 };
}


