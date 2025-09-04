import type { IndexerTracker } from '../../lib/indexer';
import { moveModuleFilter } from '../common';
export * as StakingEvents from './events';
export { StakingClient } from './client';
export { createStakingKeeper } from './keeper';

export function stakingEventTracker(pkg: string): IndexerTracker {
  return { id: `staking:${pkg}`, filter: moveModuleFilter(pkg, 'staking'), pageLimit: 200 };
}


