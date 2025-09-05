export type ContractsEnv = {
  pkgUnxversal: string;   // 0x... package id
  pkgDeepbook: string;    // deepbook package id (for client-side references if needed)
};

export function getContracts(): ContractsEnv {
  // For now read from Vite envs; users can adjust in .env
  return {
    pkgUnxversal: import.meta.env.VITE_UNXV_PKG ?? '',
    pkgDeepbook: import.meta.env.VITE_DEEPBOOK_PKG ?? '',
  };
}

export type SwitchboardSettings = {
  symbols: string[];
};

export function loadSwitchboardSettings(): SwitchboardSettings {
  const s = String(import.meta.env.VITE_SURGE_SYMBOLS ?? 'SUI/USD');
  const symbols = s.split(',').map((x) => x.trim()).filter(Boolean);
  return { symbols };
}


