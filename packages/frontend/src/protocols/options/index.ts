import type { IndexerTracker } from '../../lib/indexer';
import { moveModuleFilter } from '../common';
export { OptionsClient } from './client';
export * as OptionsEvents from './events';

export function optionsEventTracker(pkg: string): IndexerTracker {
  return { id: `options:${pkg}`, filter: moveModuleFilter(pkg, 'options'), pageLimit: 200 };
}


