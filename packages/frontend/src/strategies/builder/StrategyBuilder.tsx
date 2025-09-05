import React, { useMemo, useState } from 'react';
import type { BuilderBlocks } from './types';
import { compileBlocksToConfig } from './compiler';
import type { StrategyConfig } from '../config';

// NOTE: This component is not mounted anywhere yet. Hook it up later in the app.
export function StrategyBuilder({ base }: { base: Omit<StrategyConfig, 'kind' | 'staticRange'> & { kind?: StrategyConfig['kind'] } }) {
  const [blocks, setBlocks] = useState<BuilderBlocks>({
    price: { type: 'price', source: 'mid', twapSecs: 30 },
    ladder: { type: 'ladder', bandPolicy: { kind: 'fixed', bps: 500 }, levelsPerSide: 3, stepBps: 80, sizePolicy: { kind: 'equal_notional', perLevelQuote: 2000 } },
    exec: { type: 'exec', refreshSecs: 10, postOnly: true, cooldownMs: 300 },
  });

  const compiled = useMemo(() => compileBlocksToConfig(blocks, base), [blocks, base]);

  // TODO UI: add form controls for each block and live JSON preview
  return (
    <div style={{ padding: 16 }}>
      <h3>Strategy Builder (preview)</h3>
      <pre>{JSON.stringify(compiled, null, 2)}</pre>
      <small>Note: hook this page into the app later.</small>
    </div>
  );
}


