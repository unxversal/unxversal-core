export type IndexerSettings = {
  // Polling interval between windows in milliseconds
  pollEveryMs: number;
  // Size of each polling window in seconds
  windowSeconds: number;
  // Page size for event queries
  pageLimit: number;
};

const KEY = 'uxv-indexer-settings:v1';

export const defaultIndexerSettings: IndexerSettings = {
  pollEveryMs: 1000,
  windowSeconds: 1,
  pageLimit: 200,
};

export function loadIndexerSettings(): IndexerSettings {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return { ...defaultIndexerSettings };
    const parsed = JSON.parse(raw) as Partial<IndexerSettings>;
    return {
      pollEveryMs: parsed.pollEveryMs ?? defaultIndexerSettings.pollEveryMs,
      windowSeconds: parsed.windowSeconds ?? defaultIndexerSettings.windowSeconds,
      pageLimit: parsed.pageLimit ?? defaultIndexerSettings.pageLimit,
    };
  } catch {
    return { ...defaultIndexerSettings };
  }
}

export function saveIndexerSettings(s: IndexerSettings): void {
  const safe = {
    pollEveryMs: Math.max(100, Math.floor(s.pollEveryMs)),
    windowSeconds: Math.max(1, Math.floor(s.windowSeconds)),
    pageLimit: Math.min(1000, Math.max(1, Math.floor(s.pageLimit))),
  } satisfies IndexerSettings;
  localStorage.setItem(KEY, JSON.stringify(safe));
}


