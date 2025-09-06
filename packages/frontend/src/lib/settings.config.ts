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
  staking?: {
    poolId: string; // UNXV staking pool id
  };
  indexers: {
    dex: boolean;
    lending: boolean;
    options: boolean;
    futures: boolean;
    gasFutures: boolean;
    perps: boolean;
    staking: boolean;
    prices: boolean; // start price feeds
  };
  keepers: {
    autoResume: boolean;
  };
  markets: {
    autostartOnConnect: boolean;
    watchlist: string[]; // pool symbols like "SUI/USDC"
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
  staking: { poolId: '' },
  indexers: {
    dex: false,
    lending: false,
    options: false,
    futures: false,
    gasFutures: false,
    perps: false,
    staking: false,
    prices: false,
  },
  keepers: {
    autoResume: false,
  },
  markets: {
    autostartOnConnect: true,
    watchlist: [
      'UNXV/USDC','AUSD/USDC','BETH/USDC','CELO/USDC','DEEP/USDC','DRF/USDC','IKA/USDC','NS/USDC','SEND/USDC','SUI/USDC','TYPUS/USDC','USDT/USDC','WAL/USDC','WAVAX/USDC','WBNB/USDC','WBTC/USDC','WETH/USDC','WFTM/USDC','WGLMR/USDC','WMATIC/USDC','WSOL/USDC','WUSDC/USDC','WUSDT/USDC','XBTC/USDC',
      'UNXV/USDT','AUSD/USDT','BETH/USDT','CELO/USDT','DEEP/USDT','DRF/USDT','IKA/USDT','NS/USDT','SEND/USDT','SUI/USDT','TYPUS/USDT','USDC/USDT','WAL/USDT','WAVAX/USDT','WBNB/USDT','WBTC/USDT','WETH/USDT','WFTM/USDT','WGLMR/USDT','WMATIC/USDT','WSOL/USDT','WUSDC/USDT','WUSDT/USDT','XBTC/USDT',
      'AUSD/UNXV','BETH/UNXV','CELO/UNXV','DEEP/UNXV','DRF/UNXV','IKA/UNXV','NS/UNXV','SEND/UNXV','SUI/UNXV','TYPUS/UNXV','USDC/UNXV','WAL/UNXV','WAVAX/UNXV','WBNB/UNXV','WBTC/UNXV','WETH/UNXV','WFTM/UNXV','WGLMR/UNXV','WMATIC/UNXV','WSOL/UNXV','WUSDC/UNXV','WUSDT/UNXV','XBTC/UNXV',
      'AUSD/SUI','BETH/SUI','CELO/SUI','DEEP/SUI','DRF/SUI','IKA/SUI','NS/SUI','SEND/SUI','SUI/SUI','TYPUS/SUI','USDC/SUI','WAL/SUI','WAVAX/SUI','WBNB/SUI','WBTC/SUI','WETH/SUI','WFTM/SUI','WGLMR/SUI','WMATIC/SUI','WSOL/SUI','WUSDC/SUI','WUSDT/SUI','XBTC/SUI',
      'AUSD/USDC','AUSD/USDT','AUSD/WUSDC','AUSD/WUSDT','USDC/USDT','USDC/WUSDC','USDC/WUSDT','USDT/WUSDC','USDT/WUSDT','WUSDC/USDC','WUSDT/USDC','WUSDC/WUSDT'
    ],
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
      staking: { ...defaultSettings.staking, ...(parsed as any).staking },
      markets: { ...defaultSettings.markets, ...(parsed as any).markets },
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

