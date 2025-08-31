import React, {useEffect, useState} from 'react';
import {Text, Box, useInput} from 'ink';
import {DOLPHIN_ANSI, UNXVERSAL_PROTOCOL} from './lib/dolphins.js';
import {loadConfig} from './lib/config.js';
import {SyntheticsIndexer} from './synthetics/indexer.js';

type Props = {
	name: string | undefined;
};

export default function App({name = 'Stranger'}: Props) {
  const [menu, setMenu] = useState(0);
  const [hasConfig, setHasConfig] = useState<boolean | null>(null);
  const [indexerStatus, setIndexerStatus] = useState<'stopped'|'starting'|'running'>('stopped');
  const [lastWrite, setLastWrite] = useState<number | null>(null);
  const [indexer, setIndexer] = useState<SyntheticsIndexer | null>(null);

  useEffect(() => {
    (async () => {
      const cfg = await loadConfig();
      setHasConfig(!!cfg);
    })();
  }, []);

  useInput((input, key) => {
    if (key.upArrow) setMenu(m => (m > 0 ? m - 1 : m));
    if (key.downArrow) setMenu(m => (m < 3 ? m + 1 : m));
    if (input === 'q') process.exit(0);
    if (key.return) {
      void onSelect(menu);
    }
  });

  const items = [
    indexerStatus === 'running' ? 'Stop indexer' : 'Start indexer (backfill then follow)',
    'Settings / Onboarding',
    'Synthetics dashboard',
    'Exit',
  ];

  async function onSelect(idx: number) {
    if (idx === 0) {
      if (indexerStatus === 'running') {
        indexer?.stop();
        setIndexerStatus('stopped');
        return;
      }
      const cfg = await loadConfig();
      if (!cfg?.synthetics.packageId || !cfg.wallet?.address || !cfg.wallet?.privateKey) {
        setHasConfig(false);
        return;
      }
      setIndexerStatus('starting');
      const ix = await SyntheticsIndexer.fromConfig();
      await ix.init();
      setIndexer(ix);
      setIndexerStatus('running');
      // Fire and forget tail; backfill start controlled by settings
      const sinceMs = cfg.indexer.backfillSinceMs ?? Date.now();
      const types = cfg.indexer.types;
      void ix.backfillThenFollow(cfg.synthetics.packageId!, sinceMs, types, cfg.indexer.windowDays);
      // Poll health for UI
      const t = setInterval(() => {
        const h = ix.health();
        setLastWrite(h.lastWriteMs ?? null);
        if (!h.running) { setIndexerStatus('stopped'); clearInterval(t); }
      }, 1000);
    } else if (idx === 1) {
      process.argv.push('--settings');
      process.exit(0);
    } else if (idx === 3) {
      process.exit(0);
    }
  }

  return (
    <Box flexDirection="column">
      <Box>
        <Box width={40}>
          <Text>{DOLPHIN_ANSI}</Text>
        </Box>
        <Box flexGrow={1} paddingLeft={2}>
          <Text>{UNXVERSAL_PROTOCOL}</Text>
        </Box>
      </Box>
      <Box marginTop={1} flexDirection="column">
        <Text color="gray">Welcome {name}. Use ↑/↓ to navigate, Enter to select, q to quit.</Text>
        {hasConfig === false && (
          <Text color="yellow">No config found. Run Settings to onboard.</Text>
        )}
        <StatusLine />
        <Box flexDirection="column" marginTop={1}>
          {items.map((label, idx) => (
            <Text key={label} color={idx === menu ? 'green' : undefined}>
              {idx === menu ? '› ' : '  '}{label}
            </Text>
          ))}
          {indexerStatus !== 'stopped' && (
            <Box marginTop={1} flexDirection="column">
              <Text color="cyan">Indexer: {indexerStatus}{lastWrite ? ` • last write ${new Date(lastWrite).toLocaleTimeString()}` : ''}</Text>
            </Box>
          )}
        </Box>
      </Box>
    </Box>
  );
}

function StatusLine() {
  const [walletOk, setWalletOk] = React.useState<boolean>(false);
  const [cursor, setCursor] = React.useState<string | null>(null);
  const [age, setAge] = React.useState<number | null>(null);

  React.useEffect(() => {
    (async () => {
      const cfg = await loadConfig();
      setWalletOk(!!cfg?.wallet?.address && !!cfg?.wallet?.privateKey);
    })();
  }, []);

  React.useEffect(() => {
    const id = setInterval(() => {
      // best-effort: try to read health from the running in-process indexer instance via window var
      const anyGlobal: any = globalThis as any;
      if (anyGlobal.__unxv_indexer) {
        const h = anyGlobal.__unxv_indexer.health?.();
        if (h) {
          setCursor(h.cursor ? `${h.cursor.txDigest}:${h.cursor.eventSeq}` : null);
          setAge(h.lastWriteMs ? (Date.now() - h.lastWriteMs) : null);
        }
      }
    }, 1000);
    return () => clearInterval(id);
  }, []);

  return (
    <Box marginTop={1}>
      <Text color={walletOk ? 'green' : 'red'}>
        {walletOk ? 'Wallet: OK' : 'Wallet: Missing'}
      </Text>
      <Text>  •  </Text>
      <Text color={age != null ? (age < 5000 ? 'green' : 'yellow') : 'gray'}>
        {age != null ? `Indexer cursor age: ${Math.floor(age/1000)}s${cursor ? ` (${cursor})` : ''}` : 'Indexer idle'}
      </Text>
    </Box>
  );
}
