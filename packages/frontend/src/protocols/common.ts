import type { SuiClient, SuiEventFilter } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';

export function moveModuleFilter(pkg: string, module: string): SuiEventFilter {
  return { MoveModule: { package: pkg, module } } as const;
}

export type TxExecutor = (tx: Transaction) => Promise<void>;

export type Keeper = {
  start: () => void;
  stop: () => void;
  isRunning: () => boolean;
};

export function makeLoop(fn: () => Promise<void>, intervalMs: number): Keeper {
  let timer: ReturnType<typeof setInterval> | null = null;
  return {
    start() {
      if (timer) return;
      // run once immediately, then on interval
      void fn();
      timer = setInterval(() => void fn(), Math.max(200, intervalMs));
    },
    stop() { if (timer) { clearInterval(timer); timer = null; } },
    isRunning() { return Boolean(timer); },
  };
}

export async function devInspectOk(client: SuiClient, sender: string, tx: Transaction): Promise<boolean> {
  try {
    const res = await client.devInspectTransactionBlock({ sender, transactionBlock: tx });
    const status = res.effects?.status?.status ?? 'success';
    return status === 'success';
  } catch {
    return false;
  }
}

export async function devInspectBool(client: SuiClient, sender: string, tx: Transaction): Promise<boolean | null> {
  try {
    const res = await client.devInspectTransactionBlock({ sender, transactionBlock: tx });
    const rv = (res.results?.[res.results.length - 1]?.returnValues?.[0]?.[0] ?? null) as unknown as string | null;
    if (!rv) return null;
    const bytes = Buffer.from(rv, 'base64');
    return bytes.length > 0 ? bytes[0] !== 0 : null;
  } catch {
    return null;
  }
}


