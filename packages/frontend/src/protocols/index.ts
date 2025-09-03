import type { IndexerTracker } from '../lib/indexer';
import { dexEventTracker } from './dex';
import { lendingEventTracker } from './lending';
import { optionsEventTracker } from './options';
import { futuresEventTracker } from './futures/index.ts';
// temporarily drop gas futures tracker until folderized
const gasFuturesEventTracker = (_pkg: string) => ({ id: 'gas-futures:disabled', filter: { Any: [] } as any, pageLimit: 200 });

export function allProtocolTrackers(pkg: string): IndexerTracker[] {
  return [
    dexEventTracker(pkg),
    lendingEventTracker(pkg),
    optionsEventTracker(pkg),
    futuresEventTracker(pkg),
    gasFuturesEventTracker(pkg),
  ];
}


