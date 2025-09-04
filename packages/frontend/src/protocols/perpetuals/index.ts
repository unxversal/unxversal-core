import type { IndexerTracker } from '../../lib/indexer';
import { moveModuleFilter } from '../common';
export { PerpetualsClient } from './client';
export * as PerpetualsEvents from './events';

export function perpsEventTracker(pkg: string): IndexerTracker {
  return { id: `perpetuals:${pkg}`, filter: moveModuleFilter(pkg, 'perpetuals'), pageLimit: 200 };
}


