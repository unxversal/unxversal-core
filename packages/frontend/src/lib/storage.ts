import Dexie, { type Table } from 'dexie';

export type EventRow = {
  key: string;            // txDigest:eventSeq
  txDigest: string;
  eventSeq: number;
  tsMs: number | null;
  type?: string | null;
  module?: string | null;
  packageId?: string | null;
  sender?: string | null;
  parsedJson?: unknown | null;
};

export type CursorRow = {
  id: string;             // tracker id
  txDigest: string | null;
  eventSeq: number | null;
};

export class UXVDB extends Dexie {
  events!: Table<EventRow, string>;
  cursors!: Table<CursorRow, string>;
  configs!: Table<StrategyConfigRow, string>;
  keepers!: Table<KeeperStateRow, string>;

  constructor() {
    super('uxv-db');
    this.version(1).stores({
      events: 'key, txDigest, eventSeq, type, module, packageId, sender, tsMs',
      cursors: 'id',
    });
    this.version(2).stores({
      events: 'key, txDigest, eventSeq, type, module, packageId, sender, tsMs',
      cursors: 'id',
      configs: 'id, vaultId, version, active',
      keepers: 'id, vaultId, keeperId, status',
    });
    this.version(3).stores({
      events: 'key, txDigest, eventSeq, type, module, packageId, sender, tsMs',
      cursors: 'id',
      configs: 'id, vaultId, version, active',
      keepers: 'id, vaultId, keeperId, status, configVersion',
    });
  }
}

export const db = new UXVDB();

// Strategy config rows
export type StrategyConfigRow = {
  id: string;            // vaultId:version or uuid
  vaultId: string;
  version: number;
  kind: string;
  createdMs: number;
  hash: string;          // hash of JSON config (informational)
  config: unknown;
  active: boolean;
};

export type KeeperStateRow = {
  id: string;            // vaultId:keeperId
  vaultId: string;
  keeperId: string;
  kind: string;
  status: 'running' | 'stopped' | 'error';
  lastError?: string | null;
  updatedMs: number;
  configVersion?: number;
};


