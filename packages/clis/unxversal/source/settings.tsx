import React, {useEffect, useMemo, useState} from 'react';
import {Box, Text, useInput} from 'ink';
import {ConfigSchema, loadConfig, mergeConfig, saveConfig, type AppConfig} from './lib/config.js';

type Field = 'rpcUrl' | 'postgresUrl' | 'network' | 'autoStart' | 'synthetics.packageId' | 'wallet.address' | 'wallet.privateKey';

export default function Settings() {
  const [cfg, setCfg] = useState<AppConfig | null>(null);
  const [idx, setIdx] = useState<number>(0);
  const [editing, setEditing] = useState<boolean>(false);
  const [buffer, setBuffer] = useState<string>('');

  useEffect(() => {
    (async () => {
      const current = (await loadConfig()) ?? ConfigSchema.parse({});
      setCfg(current);
    })();
  }, []);

  const fields: Field[] = useMemo(() => {
    // Base fields for all users
    const base: Field[] = ['rpcUrl', 'postgresUrl', 'network', 'autoStart', 'synthetics.packageId', 'wallet.address', 'wallet.privateKey'];
    if (!cfg) return base;
    // If first run and wallet fields are missing, move them to the top to explicitly prompt
    const needsWallet = !cfg.wallet?.address || !cfg.wallet?.privateKey;
    if (!needsWallet) return base;
    const reordered: Field[] = ['wallet.address', 'wallet.privateKey', ...base.filter(f => f !== 'wallet.address' && f !== 'wallet.privateKey')];
    return reordered;
  }, [cfg]);

  useInput((input, key) => {
    if (!cfg) return;
    if (!editing) {
      if (key.upArrow) setIdx(i => (i > 0 ? i - 1 : i));
      if (key.downArrow) setIdx(i => (i < fields.length - 1 ? i + 1 : i));
      if (key.return) {
        setEditing(true);
        setBuffer(currentValue(cfg, fields[idx]!));
      }
      if (input === 's') {
        (async () => { await saveConfig(cfg); process.exit(0); })();
      }
      if (input === 'q') process.exit(0);
    } else {
      if (key.return) {
        const updated = applyValue(cfg, fields[idx]!, buffer);
        setCfg(updated);
        setEditing(false);
        setBuffer('');
      } else if (key.escape) {
        setEditing(false);
        setBuffer('');
      } else if (key.backspace || key.delete) {
        setBuffer(s => s.slice(0, -1));
      } else {
        setBuffer(s => s + input);
      }
    }
  });

  if (!cfg) return <Text>Loading settings...</Text>;

  return (
    <Box flexDirection="column">
      <Text>Settings / Onboarding</Text>
      <Text color="gray">Use ↑/↓ to select, Enter to edit, s to save, q to quit</Text>
      {(!cfg.wallet?.address || !cfg.wallet?.privateKey) && (
        <Box marginTop={1}><Text color="yellow">Wallet details required: please enter wallet.address and wallet.privateKey (base64 ed25519 secret).</Text></Box>
      )}
      <Box flexDirection="column" marginTop={1}>
        {fields.map((f, i) => (
          <Text key={f} color={i === idx ? 'green' : undefined}>
            {i === idx ? '› ' : '  '}{f}: {currentValue(cfg, f)}
          </Text>
        ))}
      </Box>
      {editing && (
        <Box marginTop={1}><Text color="yellow">New value: {buffer}</Text></Box>
      )}
    </Box>
  );
}

function currentValue(cfg: AppConfig, field: Field): string {
  switch (field) {
    case 'rpcUrl': return cfg.rpcUrl;
    case 'postgresUrl': return cfg.postgresUrl;
    case 'network': return cfg.network;
    case 'autoStart': return String(cfg.autoStart);
    case 'synthetics.packageId': return cfg.synthetics.packageId ?? '';
    case 'wallet.address': return cfg.wallet.address ?? '';
    case 'wallet.privateKey': return cfg.wallet.privateKey ? obfuscate(cfg.wallet.privateKey) : '';
  }
}

function applyValue(cfg: AppConfig, field: Field, value: string): AppConfig {
  switch (field) {
    case 'rpcUrl': return mergeConfig(cfg, {rpcUrl: value});
    case 'postgresUrl': return mergeConfig(cfg, {postgresUrl: value});
    case 'network': return mergeConfig(cfg, {network: value as any});
    case 'autoStart': return mergeConfig(cfg, {autoStart: value === 'true'});
    case 'synthetics.packageId': return mergeConfig(cfg, {synthetics: { ...cfg.synthetics, packageId: value }});
    case 'wallet.address': return mergeConfig(cfg, {wallet: { address: value }} as any);
    case 'wallet.privateKey': return mergeConfig(cfg, {wallet: { privateKey: value }} as any);
  }
}

function obfuscate(secret: string): string {
  if (!secret) return '';
  if (secret.length <= 8) return '********';
  return secret.slice(0, 4) + '****' + secret.slice(-4);
}


