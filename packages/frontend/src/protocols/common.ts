import type { SuiEventFilter } from '@mysten/sui/client';

export function moveModuleFilter(pkg: string, module: string): SuiEventFilter {
  return { MoveModule: { package: pkg, module } } as const;
}


