import Dexie, { Table } from 'dexie';

export type EventRow = {
  key: string;            // txDigest:eventSeq
  txDigest: string;
  eventSeq: number;
  tsMs: number | null;
  type?: string | null;
  module?: string | null;
  packageId?: string | null;
  sender?: string | null;
  parsedJson?: any | null;
};

export type CursorRow = {
  id: string;             // tracker id
  txDigest: string | null;
  eventSeq: number | null;
};

export class UXVDB extends Dexie {
  events!: Table<EventRow, string>;
  cursors!: Table<CursorRow, string>;

  constructor() {
    super('uxv-db');
    this.version(1).stores({
      events: 'key, txDigest, eventSeq, type, module, packageId, sender, tsMs',
      cursors: 'id',
    });
  }
}

export const db = new UXVDB();


