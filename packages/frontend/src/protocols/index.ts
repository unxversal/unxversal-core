import type { IndexerTracker } from '../lib/indexer';
import { dexEventTracker } from './dex';
import { lendingEventTracker } from './lending';
import { optionsEventTracker } from './options';
import { futuresEventTracker } from './futures';
import { gasFuturesEventTracker } from './gas-futures';

export function allProtocolTrackers(pkg: string): IndexerTracker[] {
  return [
    dexEventTracker(pkg),
    lendingEventTracker(pkg),
    optionsEventTracker(pkg),
    futuresEventTracker(pkg),
    gasFuturesEventTracker(pkg),
  ];
}


