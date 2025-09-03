import type { EventFilter } from '../lib/indexer';

export function moveModuleFilter(pkg: string, module: string): EventFilter {
  return { MoveModule: { package: pkg, module } } as const;
}


