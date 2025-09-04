import type { IndexerTracker } from '../../lib/indexer';
import { moveModuleFilter } from '../common';
export * as StakingEvents from './events';
export { StakingClient } from './client';

export function stakingEventTracker(pkg: string): IndexerTracker {
  return { id: `staking:${pkg}`, filter: moveModuleFilter(pkg, 'staking'), pageLimit: 200 };
}


