export type DexSettings = {
  deepbookIndexerUrl: string;
  poolId: string; // human alias or object id, depending on indexer impl
  baseType: string;
  quoteType: string;
  balanceManagerId: string;
  tradeProofId: string;
  feeConfigId: string;
  feeVaultId: string;
};

export type AppSettings = {
  network: 'testnet' | 'mainnet';
  contracts: {
    pkgUnxversal: string;
    pkgDeepbook: string;
  };
  dex: DexSettings;
};

const KEY = 'uxv:app-settings:v1';

const defaultSettings: AppSettings = {
  network: 'testnet',
  contracts: {
    pkgUnxversal: '',
    pkgDeepbook: '',
  },
  dex: {
    deepbookIndexerUrl: 'https://api.naviprotocol.io',
    poolId: 'SUI-USDC',
    baseType: '0x2::sui::SUI',
    quoteType: '0x2::sui::SUI',
    balanceManagerId: '',
    tradeProofId: '',
    feeConfigId: '',
    feeVaultId: '',
  },
};

export function loadSettings(): AppSettings {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return defaultSettings;
    const parsed = JSON.parse(raw) as AppSettings;
    // shallow version merge to keep forward compatibility
    return {
      ...defaultSettings,
      ...parsed,
      contracts: { ...defaultSettings.contracts, ...(parsed as any).contracts },
      dex: { ...defaultSettings.dex, ...parsed.dex },
    };
  } catch {
    return defaultSettings;
  }
}

export function saveSettings(next: AppSettings): void {
  localStorage.setItem(KEY, JSON.stringify(next));
}

export function updateSettings(mutator: (current: AppSettings) => AppSettings): AppSettings {
  const current = loadSettings();
  const next = mutator(current);
  saveSettings(next);
  return next;
}

