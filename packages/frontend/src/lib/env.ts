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


