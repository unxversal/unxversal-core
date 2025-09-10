import type { DeployConfig } from './types.js';

export const MAINNET_ORACLE_FEEDS: NonNullable<DeployConfig['oracleFeeds']> = [
  { symbol: 'SUI/USDC', priceId: '0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744' },
  { symbol: 'DEEP/USDC', priceId: '0x29bdd5248234e33bd93d3b81100b5fa32eaa5997843847e2c2cb16d7c6d9f7ff' },
  { symbol: 'ETH/USDC', priceId: '0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace' },
  { symbol: 'BTC/USDC', priceId: '0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43' },
  { symbol: 'SOL/USDC', priceId: '0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d' },
  { symbol: 'GLMR/USDC', priceId: '0x309d39a65343d45824f63dc6caa75dbf864834f48cfaa6deb122c62239e06474' },
  { symbol: 'MATIC/USDC', priceId: '0xffd11c5a1cfd42f80afb2df4d9f264c15f956d68153335374ec10722edd70472' },
  { symbol: 'APT/USDC', priceId: '0x03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5' },
  { symbol: 'CELO/USDC', priceId: '0x7d669ddcdd23d9ef1fa9a9cc022ba055ec900e91c4cb960f3c20429d4447a411' },
  { symbol: 'IKA/USDC', priceId: '0x2b529621fa6e2c8429f623ba705572aa64175d7768365ef829df6a12c9f365f4' },
  { symbol: 'NS/USDC', priceId: '0xbb5ff26e47a3a6cc7ec2fce1db996c2a145300edc5acaabe43bf9ff7c5dd5d32' },
  { symbol: 'SEND/USDC', priceId: '0x7d19b607c945f7edf3a444289c86f7b58dcd8b18df82deadf925074807c99b59' },
  { symbol: 'WAL/USDC', priceId: '0xeba0732395fae9dec4bae12e52760b35fc1c5671e2da8b449c9af4efe5d54341' },
  { symbol: 'USDT/USDC', priceId: '0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b' },
  { symbol: 'WBNB/USDC', priceId: '0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f' },
];

export const TESTNET_ORACLE_FEEDS = MAINNET_ORACLE_FEEDS;

export const ORACLE_MAX_AGE_SEC = 5;


