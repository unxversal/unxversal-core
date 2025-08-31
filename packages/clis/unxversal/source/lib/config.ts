import {promises as fs} from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {z} from 'zod';
import dotenv from 'dotenv';

dotenv.config();

export const CONFIG_DIR = path.join(os.homedir(), '.unxversal');
export const CONFIG_FILE = path.join(CONFIG_DIR, 'config.json');

export const SyntheticsSchema = z.object({
  packageId: z.string().min(2).optional(),
  module: z.string().default('synthetics'),
  registryId: z.string().optional(),
  treasuryId: z.string().optional(),
  oracleConfigId: z.string().optional(),
  botPointsId: z.string().optional(),
  collateralType: z.string().optional(),
  collateralCfgId: z.string().optional(),
  unxvAggregatorId: z.string().optional(),
  markets: z.record(z.string(), z.object({
    marketId: z.string(),
    escrowId: z.string(),
  })).default({}),
  aggregators: z.record(z.string(), z.string()).default({}),
  vaultIds: z.array(z.string()).default([]),
  eventFilters: z.array(z.string()).optional(),
  admin: z.object({
    adminRegistryId: z.string().optional(),
    publisherId: z.string().optional(),
  }).default({}),
});

export const LendingSchema = z.object({
  packageId: z.string().min(2).optional(),
  module: z.string().default('lending'),
  registryId: z.string().optional(),
  oracleRegistryId: z.string().optional(),
  oracleConfigId: z.string().optional(),
  pools: z.record(z.string(), z.object({
    poolId: z.string(),
    asset: z.string(),
  })).default({}),
}).default({ module: 'lending', pools: {} });

export const ConfigSchema = z.object({
  rpcUrl: z.string().min(3).default(process.env['SUI_RPC_URL'] || 'https://fullnode.testnet.sui.io:443'),
  network: z.enum(['localnet', 'devnet', 'testnet', 'mainnet']).default('testnet'),
  postgresUrl: z.string().min(3).default(process.env['DATABASE_URL'] || 'postgres://localhost:5432/unxversal'),
  autoStart: z.boolean().default(true),
  wallet: z.object({
    privateKey: z.string().optional(), // base64 secret key (ed25519)
    address: z.string().optional(),
  }).default({}),
  synthetics: SyntheticsSchema.default({ module: 'synthetics', markets: {}, aggregators: {}, vaultIds: [], admin: {} }),
  lending: LendingSchema,
  indexer: z.object({
    backfillSinceMs: z.number().optional(),
    windowDays: z.number().default(7),
    types: z.array(z.string()).optional(),
    log: z.boolean().default(true),
    metrics: z.boolean().default(true),
  }).default({ windowDays: 7, log: true, metrics: true }),
  keeper: z.object({
    matchMaxSteps: z.number().default(3),
    priceBandBps: z.number().default(5000),
    gcMaxRemovals: z.number().default(1000),
    intervalsMs: z.object({
      match: z.number().default(3000),
      gc: z.number().default(5000),
      accrue: z.number().default(60000),
      liq: z.number().default(5000),
    }).default({ match:3000, gc:5000, accrue:60000, liq:5000 }),
  }).default({ matchMaxSteps:3, priceBandBps:5000, gcMaxRemovals:1000, intervalsMs:{ match:3000, gc:5000, accrue:60000, liq:5000 } }),
});

export type AppConfig = z.infer<typeof ConfigSchema>;

export async function ensureConfigDir(): Promise<void> {
  await fs.mkdir(CONFIG_DIR, {recursive: true});
}

export async function loadConfig(): Promise<AppConfig | null> {
  try {
    const raw = await fs.readFile(CONFIG_FILE, 'utf8');
    const parsed = JSON.parse(raw);
    const cfg = ConfigSchema.parse(parsed);
    return cfg;
  } catch {
    return null;
  }
}

export async function saveConfig(cfg: AppConfig): Promise<void> {
  await ensureConfigDir();
  const json = JSON.stringify(cfg, null, 2);
  await fs.writeFile(CONFIG_FILE, json, 'utf8');
}

export function mergeConfig(a: Partial<AppConfig>, b: Partial<AppConfig>): AppConfig {
  return ConfigSchema.parse({
    ...a,
    ...b,
    synthetics: {
      ...(a.synthetics || {}),
      ...(b.synthetics || {}),
    },
    lending: {
      ...(a as any).lending || {},
      ...(b as any).lending || {},
    },
  });
}


