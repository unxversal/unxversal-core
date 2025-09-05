// Switchboard Surge streaming integration in one place.
// Users configure API key and symbols client-side (localStorage); we initialize once and stream updates.

import * as sb from '@switchboard-xyz/on-demand';
import { SWITCHBOARD_CONFIG } from './switchboard.config';

export type SurgeUpdate = { data: { symbol: string; price: number; source_ts_ms?: number } };

// Shared cache of latest prices
let currentPrice: Record<string, { price: number; ts: number }> = {};
let client: sb.Surge | null = null;
let isWired = false;

function getStoredApiKey(): string | null {
  // Prefer explicit config if provided
  if (SWITCHBOARD_CONFIG.apiKey && SWITCHBOARD_CONFIG.apiKey.trim().length > 0) return SWITCHBOARD_CONFIG.apiKey;
  return localStorage.getItem('SURGE_API_KEY');
}

function setStoredApiKey(apiKey: string): void {
  localStorage.setItem('SURGE_API_KEY', apiKey);
}

function getStoredSymbols(): string[] {
  const raw = localStorage.getItem('SURGE_SYMBOLS') ?? SWITCHBOARD_CONFIG.symbols.join(',');
  if (!raw || !raw.trim()) return ['SUI/USD'];
  return raw.split(',').map((s) => s.trim()).filter(Boolean);
}

function setStoredSymbols(symbols: string[]): void {
  localStorage.setItem('SURGE_SYMBOLS', symbols.join(','));
}

export function configureSurge({ apiKey, symbols }: { apiKey: string; symbols: string[] }): void {
  setStoredApiKey(apiKey);
  setStoredSymbols(symbols);
}

export async function initSurgeFromSettings(): Promise<void> {
  const apiKey = getStoredApiKey();
  if (!apiKey) return; // not configured yet
  if (!client) client = new sb.Surge({ apiKey });
  if (!isWired) {
    client.on('update', (u: SurgeUpdate) => applyUpdate(u));
    isWired = true;
  }
  const symbols = getStoredSymbols();
  await client.connectAndSubscribe(symbols.map((s) => ({ symbol: s })));
}

export async function subscribeSymbols(symbols: string[]): Promise<void> {
  setStoredSymbols(symbols);
  if (!client) {
    const apiKey = getStoredApiKey();
    if (!apiKey) return;
    client = new sb.Surge({ apiKey });
    if (!isWired) { client.on('update', (u: SurgeUpdate) => applyUpdate(u)); isWired = true; }
  }
  await client.connectAndSubscribe(symbols.map((s) => ({ symbol: s })));
}

export function getLatestPrice(symbol: string): number | null {
  const r = currentPrice[symbol];
  return r ? r.price : null;
}

export function getLatestTs(symbol: string): number | null {
  const r = currentPrice[symbol];
  return r ? r.ts : null;
}

export function applyUpdate(u: SurgeUpdate): void {
  currentPrice[u.data.symbol] = { price: u.data.price, ts: u.data.source_ts_ms ?? Date.now() };
}


