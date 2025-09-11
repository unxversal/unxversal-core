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

export const TESTNET_ORACLE_FEEDS: NonNullable<DeployConfig['oracleFeeds']> = [
  { symbol: 'SUI/USDC', priceId: '0x50c67b3fd225db8912a424dd4baed60ffdde625ed2feaaf283724f9608fea266' },
  { symbol: 'DEEP/USDC', priceId: '0xe18bf5fa857d5ca8af1f6a458b26e853ecdc78fc2f3dc17f4821374ad94d8327' },
  { symbol: 'ETH/USDC', priceId: '0xca80ba6dc32e08d06f1aa886011eed1d77c77be9eb761cc10d72b7d0a2fd57a6' },
  { symbol: 'BTC/USDC', priceId: '0xf9c0172ba10dfa4d19088d94f5bf61d3b54d5bd7483a322a982e1373ee8ea31b' },
  { symbol: 'SOL/USDC', priceId: '0xfe650f0367d4a7ef9815a593ea15d36593f0643aaaf0149bb04be67ab851decd' },
  { symbol: 'GLMR/USDC', priceId: '0x38f4cd70ed68b449613c0a13dd101141c2bc61a72e284595feb452f6e7e6b0c5' },
  { symbol: 'MATIC/USDC', priceId: '0xb70baf5be4a7509e962468325ddb952aca04e549bbd8e7744214fde88857ac29' },
  { symbol: 'APT/USDC', priceId: '0x44a93dddd8effa54ea51076c4e851b6cbbfd938e82eb90197de38fe8876bb66e' },
  { symbol: 'CELO/USDC', priceId: '0xe75bf4f2cf9e9f6a91d3c3cfc00136e3ba7eaeb162084fdad818c68133dc8a24' },
  { symbol: 'IKA/USDC', priceId: '0x2816b8747907b457a8480aa29c9049eb3bd7529120c96c1b9a402a9faed04dab' },
  { symbol: 'NS/USDC', priceId: '0x65aca56071505735c09091deb8733fdeba265bd9723dd4fb326b5ffd6843b3a3' },
  { symbol: 'SEND/USDC', priceId: '0xa10095ccc2eda27177e6b731fb5d72c876949315cae8075247843f5c1d09be38' },
  { symbol: 'WAL/USDC', priceId: '0xa6ba0195b5364be116059e401fb71484ed3400d4d9bfbdf46bd11eab4f9b7cea' },
  { symbol: 'USDT/USDC', priceId: '0x1fc18861232290221461220bd4e2acd1dcdfbc89c84092c93c18bdc7756c1588' },
  { symbol: 'WBNB/USDC', priceId: '0xecf553770d9b10965f8fb64771e93f5690a182edc32be4a3236e0caaa6e0581a' },
];

export const ORACLE_MAX_AGE_SEC = 5;


