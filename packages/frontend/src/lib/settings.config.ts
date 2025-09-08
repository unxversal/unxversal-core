export type TokenInfo = {
  symbol: string;
  name: string;
  address?: string; // For external tokens
  typeTag?: string; // For Move-based tokens (e.g., "0x2::sui::SUI")
  packageId?: string; // Package ID for Move-based tokens
  moduleName?: string; // Module name for Move-based tokens
  structName?: string; // Struct name for Move-based tokens
  decimals: number;
  isNative?: boolean; // For SUI
  iconUrl?: string;
};

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
  markets: {
    autostartOnConnect: boolean;
    watchlist: string[]; // pool symbols like "SUI/USDC"
  };
  tokens: TokenInfo[];
  dex: DexSettings;
};

const KEY = 'uxv:app-settings:v1';

export const defaultSettings: AppSettings = {
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
  markets: {
    autostartOnConnect: true,
    watchlist: [
      'UNXV/USDC',
      'AUSD/USDC',
      'BETH/USDC',
      'CELO/USDC',
      'DEEP/USDC',
      'DRF/USDC',
      'IKA/USDC',
      'NS/USDC',
      'SEND/USDC',
      'SUI/USDC',
      'TYPUS/USDC',
      'USDT/USDC',
      'WAL/USDC',
      'WAVAX/USDC',
      'WBNB/USDC',
      'WBTC/USDC',
      'WETH/USDC',
      'WFTM/USDC',
      'WGLMR/USDC',
      'WMATIC/USDC',
      'WSOL/USDC',
      'WUSDC/USDC',
      'WUSDT/USDC',
      'XBTC/USDC',
      'UNXV/DEEP',
      'UNXV/SUI',
      'DEEP/SUI',
      'NS/SUI',
      'DRF/SUI',
      'WAL/SUI',
      'NS/UNXV'
    ],
  },
  tokens: [
    // Native and protocol tokens
    {
      symbol: 'SUI',
      name: 'Sui',
      typeTag: '0x2::sui::SUI',
      packageId: '0x2',
      decimals: 9,
      isNative: true,
      iconUrl: 'https://assets.coingecko.com/coins/images/26375/small/sui_asset.jpeg'
    },
    {
      symbol: 'UNXV',
      name: 'Unxversal Token',
      packageId: '', // To be filled with actual package ID
      moduleName: 'unxversal',
      structName: 'UNXV',
      isNative: true,
      decimals: 6,
      iconUrl: 'https://unxversal.com/assets/unxv-token.png'
    },
    {
      symbol: 'DEEP',
      name: 'DeepBook Token',
      typeTag: '0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP',
      packageId: '0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270', // To be filled with actual package ID
      moduleName: 'deep',
      isNative: true,
      structName: 'DEEP',
      decimals: 6,
      iconUrl: 'https://images.deepbook.tech/icon.svg'
    },

    // Sui Bridge Assets
    {
      symbol: 'suiETH',
      name: 'Sui Bridge Ethereum',
      typeTag: '0xd0e89b2af5e4910726fbcd8b8dd37bb79b29e5f83f7491bca830e94f7f226d29::eth::ETH',
      packageId: '0xd0e89b2af5e4910726fbcd8b8dd37bb79b29e5f83f7491bca830e94f7f226d29', // To be filled with actual package ID
      moduleName: 'eth',
      structName: 'ETH',
      decimals: 8,
      iconUrl: 'https://bridge-assets.sui.io/eth.png'
    },
    {
      symbol: 'suiBTC',
      name: 'Sui Bridge Bitcoin',
      typeTag: '0xaafb102dd0902f5055cadecd687fb5b71ca82ef0e0285d90afde828ec58ca96b::btc::BTC', // To be filled with actual type tag
      packageId: '0xaafb102dd0902f5055cadecd687fb5b71ca82ef0e0285d90afde828ec58ca96b', // To be filled with actual package ID
      moduleName: 'btc',
      structName: 'BTC',
      decimals: 8,
      iconUrl: 'https://bridge-assets.sui.io/suiWBTC.png'
    },
    {
      symbol: 'suiUSDT',
      name: 'Sui Bridge Tether USD',
      typeTag: '0x375f70cf2ae4c00bf37117d0c85a2c71545e6ee05c4a5c7d282cd66a4504b068::usdt::USDT', // To be filled with actual type tag
      packageId: '0x375f70cf2ae4c00bf37117d0c85a2c71545e6ee05c4a5c7d282cd66a4504b068', // To be filled with actual package ID
      moduleName: 'usdt',
      structName: 'USDT',
      decimals: 6,
      iconUrl: 'https://bridge-assets.sui.io/usdt.png'
    },

    // Stablecoins
    {
      symbol: 'USDC',
      name: 'USD Coin',
      typeTag: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      address: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7', // Sui USDC
      decimals: 6,
      iconUrl: 'https://strapi-dev.scand.app/uploads/usdc_03b37ed889.png'
    },
    {
      symbol: 'WUSDC',
      name: 'Wrapped USDC',
      typeTag: '0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN',
      address: '0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf', 
      decimals: 6,
      iconUrl: 'https://strapi-dev.scand.app/uploads/usdc_019d7ef24b.png'
    },
    {
      symbol: 'WUSDT',
      name: 'Wrapped USDT',
      typeTag: '0xc060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c::coin::COIN',
      address: '0xc060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c', 
      decimals: 6,
      iconUrl: 'https://strapi-dev.scand.app/uploads/usdt_15663b1a77.png'
    },
    {
      symbol: 'USDCsol',
      name: 'Solana USDC',
      typeTag: '0xb231fcda8bbddb31f2ef02e6161444aec64a514e2c89279584ac9806ce9cf037::coin::COIN',
      address: '0xb231fcda8bbddb31f2ef02e6161444aec64a514e2c89279584ac9806ce9cf037', 
      decimals: 6,
      iconUrl: 'https://strapi-dev.scand.app/uploads/usdc_019d7ef24b.png'
    },

    // Wrapped assets
    {
      symbol: 'WBTC',
      name: 'Wrapped Bitcoin',
      typeTag: '0x027792d9fed7f9844eb4839566001bb6f6cb4804f66aa2da6fe1ee242d896881::coin::COIN',
      address: '0x027792d9fed7f9844eb4839566001bb6f6cb4804f66aa2da6fe1ee242d896881', 
      decimals: 8,
      iconUrl: 'https://strapi-dev.scand.app/uploads/Bitcoin_svg_3d3d928a26.png'
    },
    {
      symbol: 'WETH',
      name: 'Wrapped Ethereum',
      typeTag: '0xaf8cd5edc19c4512f4259f0bee101a40d41ebed738ade5874359610ef8eeced5::coin::COIN',
      address: '0xaf8cd5edc19c4512f4259f0bee101a40d41ebed738ade5874359610ef8eeced5', 
      decimals: 8,
      iconUrl: 'https://strapi-dev.scand.app/uploads/Eth_Logo_6732c75cc7.png'
    },
    {
      symbol: 'WAVAX',
      name: 'Wrapped Avalanche',
      typeTag: '0x1e8b532cca6569cab9f9b9ebc73f8c13885012ade714729aa3b450e0339ac766::coin::COIN',
      address: '0x1e8b532cca6569cab9f9b9ebc73f8c13885012ade714729aa3b450e0339ac766', 
      decimals: 8,
      iconUrl: 'https://strapi-dev.scand.app/uploads/avalanche_avax_logo_f31f02e4a3.png'
    },
    {
      symbol: 'WBNB',
      name: 'Wrapped BNB',
      typeTag: '0xb848cce11ef3a8f62eccea6eb5b35a12c4c2b1ee1af7755d02d7bd6218e8226f::coin::COIN',
      address: '0xb848cce11ef3a8f62eccea6eb5b35a12c4c2b1ee1af7755d02d7bd6218e8226f', 
      decimals: 8,
      iconUrl: 'https://strapi-dev.scand.app/uploads/bnb_bnb_logo_b38d2154bb.png'
    },
    {
      symbol: 'WFTM',
      name: 'Wrapped Fantom',
      typeTag: '0x6081300950a4f1e2081580e919c210436a1bed49080502834950d31ee55a2396::coin::COIN',
      address: '0x6081300950a4f1e2081580e919c210436a1bed49080502834950d31ee55a2396', 
      decimals: 8,
      iconUrl: 'https://strapi-dev.scand.app/uploads/WFTM_Logo_b1dfb8380a.jpeg'
    },
    {
      symbol: 'WGLMR',
      name: 'Wrapped Moonbeam',
      typeTag: '0x66f87084e49c38f76502d17f87d17f943f183bb94117561eb573e075fdc5ff75::coin::COIN',
      address: '0x66f87084e49c38f76502d17f87d17f943f183bb94117561eb573e075fdc5ff75', 
      decimals: 8,
      iconUrl: 'https://strapi-dev.scand.app/uploads/WGLMR_Logo_0916d3b538.jpeg'
    },
    {
      symbol: 'WMATIC',
      name: 'Wrapped Polygon',
      typeTag: '0xdbe380b13a6d0f5cdedd58de8f04625263f113b3f9db32b3e1983f49e2841676::coin::COIN',
      address: '0xdbe380b13a6d0f5cdedd58de8f04625263f113b3f9db32b3e1983f49e2841676', 
      decimals: 8,
      iconUrl: 'https://strapi-dev.scand.app/uploads/WMATIC_Logo_9a2f989611.jpg'
    },
    {
      symbol: 'WSOL',
      name: 'Wrapped Solana',
      typeTag: '0xb7844e289a8410e50fb3ca48d69eb9cf29e27d223ef90353fe1bd8e27ff8f3f8::coin::COIN',
      address: '0xb7844e289a8410e50fb3ca48d69eb9cf29e27d223ef90353fe1bd8e27ff8f3f8', 
      decimals: 8,
      iconUrl: 'https://strapi-dev.scand.app/uploads/Bez_nazvaniya_a03b9b6fbb.jpeg'
    },


    // Other tokens
    {
      symbol: 'xBTC',
      name: 'OKX Wrapped BTC',
      typeTag: '0x876a4b7bce8aeaef60464c11f4026903e9afacab79b9b142686158aa86560b50::xbtc::XBTC',
      address: '0x876a4b7bce8aeaef60464c11f4026903e9afacab79b9b142686158aa86560b50', 
      decimals: 8,
      iconUrl: 'https://static.coinall.ltd/cdn/oksupport/common/20250512-095503.72e1f41d9b9a06.png'
    },
    {
      symbol: 'APT',
      name: 'Aptos',
      typeTag: '0x3a5143bb1196e3bcdfab6203d1683ae29edd26294fc8bfeafe4aaa9d2704df37::coin::COIN',
      address: '0x3a5143bb1196e3bcdfab6203d1683ae29edd26294fc8bfeafe4aaa9d2704df37', 
      decimals: 8,
      iconUrl: 'https://strapi-dev.scand.app/uploads/Aptos_Coin_Logo_30be6df869.png'
    },
    {
      symbol: 'CELO',
      name: 'Celo',
      typeTag: '0xa198f3be41cda8c07b3bf3fee02263526e535d682499806979a111e88a5a8d0f::coin::COIN',
      address: '0xa198f3be41cda8c07b3bf3fee02263526e535d682499806979a111e88a5a8d0f', 
      decimals: 8,
      iconUrl: 'https://strapi-dev.scand.app/uploads/Celo_CELO_Logo_Vector_730x730_6847fa5497.webp'
    },
    {
      symbol: 'DRF',
      name: 'DRF',
      typeTag: '0x294de7579d55c110a00a7c4946e09a1b5cbeca2592fbb83fd7bfacba3cfeaf0e::drf::DRF',
      address: '0x294de7579d55c110a00a7c4946e09a1b5cbeca2592fbb83fd7bfacba3cfeaf0e', 
      isNative: true,
      decimals: 6,
      iconUrl: 'https://firebasestorage.googleapis.com/v0/b/drife-dubai-prod.appspot.com/o/drife_logo_round.png?alt=media&token=cb96bd23-5a08-4015-b1d2-e89114434d4f'
    },
    {
      symbol: 'IKA',
      name: 'IKA',
      typeTag: '0x7262fb2f7a3a14c888c438a3cd9b912469a58cf60f367352c46584262e8299aa::ika::IKA',
      isNative: true,
      address: '0x7262fb2f7a3a14c888c438a3cd9b912469a58cf60f367352c46584262e8299aa', 
      decimals: 9,
      iconUrl: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxMDAwIiBoZWlnaHQ9IjEwMDAiIHZpZXdCb3g9IjAgMCAxMDAwIDEwMDAiIGZpbGw9Im5vbmUiPiA8cmVjdCB3aWR0aD0iMTAwMCIgaGVpZ2h0PSIxMDAwIiBmaWxsPSIjRUUyQjVCIi8+IDxwYXRoIGQ9Ik02NzguNzQyIDU4OC45MzRWNDEwLjQ2N0M2NzguNzQyIDMxMS45MDIgNTk4Ljg0IDIzMiA1MDAuMjc1IDIzMlYyMzJDNDAxLjcxIDIzMiAzMjEuODA4IDMxMS45MDIgMzIxLjgwOCA0MTAuNDY3VjU4OC45MzQiIHN0cm9rZT0id2hpdGUiIHN0cm9rZS13aWR0aD0iNTcuMzIyOCIvPiA8cGF0aCBkPSJNNjc4Ljc0OCA1MjkuNDQxTDY3OC43NDggNTk4Ljg0NUM2NzguNzQ4IDYzNy4xNzYgNzA5LjgyMiA2NjguMjQ5IDc0OC4xNTIgNjY4LjI0OVY2NjguMjQ5Qzc4Ni40ODMgNjY4LjI0OSA4MTcuNTU2IDYzNy4xNzYgODE3LjU1NiA1OTguODQ1TDgxNy41NTYgNTI5LjQ0MSIgc3Ryb2tlPSJ3aGl0ZSIgc3Ryb2tlLXdpZHRoPSI1Ny4zMjI4Ii8+IDxwYXRoIGQ9Ik01NzMuNDkxIDc2OC45MThMNTczLjQ5MSA2NjMuMTU5QzU3My40OTEgNjIyLjcyMyA1NDAuNzExIDU4OS45NDIgNTAwLjI3NCA1ODkuOTQyVjU4OS45NDJDNDU5LjgzNyA1ODkuOTQyIDQyNy4wNTYgNjIyLjcyMyA0MjcuMDU2IDY2My4xNTlMNDI3LjA1NiA3NjguOTE4IiBzdHJva2U9IndoaXRlIiBzdHJva2Utd2lkdGg9IjU3LjMyMjgiLz4gPHBhdGggZD0iTTE4MyA1MjkuNDQxTDE4MyA1OTguODQ1QzE4MyA2MzcuMTc2IDIxNC4wNzMgNjY4LjI0OSAyNTIuNDA0IDY2OC4yNDlWNjY4LjI0OUMyOTAuNzM1IDY2OC4yNDkgMzIxLjgwOCA2MzcuMTc2IDMyMS44MDggNTk4Ljg0NUwzMjEuODA4IDUyOS40NDEiIHN0cm9rZT0id2hpdGUiIHN0cm9rZS13aWR0aD0iNTcuMzIyOCIvPiA8cGF0aCBkPSJNNTAwLjI3MiAzNzAuNzk4QzUzMy4xMjcgMzcwLjc5OCA1NTkuNzYxIDM5Ny40MzMgNTU5Ljc2MSA0MzAuMjg4QzU1OS43NjEgNDYzLjE0MiA1MzMuMTI3IDQ4OS43NzcgNTAwLjI3MiA0ODkuNzc3QzQ5NC4xNzQgNDg5Ljc3NyA0ODguMjkgNDg4Ljg1OCA0ODIuNzUxIDQ4Ny4xNTNDNDkzLjA4MiA0ODIuNDkgNTAwLjI3MiA0NzIuMSA1MDAuMjcyIDQ2MC4wMjlDNTAwLjI3MiA0NDMuNjAyIDQ4Ni45NTUgNDMwLjI4NSA0NzAuNTI4IDQzMC4yODVDNDU4LjQ1OCA0MzAuMjg1IDQ0OC4wNjcgNDM3LjQ3MyA0NDMuNDA0IDQ0Ny44MDJDNDQxLjcwMSA0NDIuMjY1IDQ0MC43ODMgNDM2LjM4MyA0NDAuNzgzIDQzMC4yODhDNDQwLjc4MyAzOTcuNDMzIDQ2Ny40MTcgMzcwLjc5OCA1MDAuMjcyIDM3MC43OThaIiBmaWxsPSJ3aGl0ZSIvPiA8L3N2Zz4='
    },
    {
      symbol: 'NS',
      name: 'NS',
      typeTag: '0x5145494a5f5100e645e4b0aa950fa6b68f614e8c59e17bc5ded3495123a79178::ns::NS',
      address: '0x5145494a5f5100e645e4b0aa950fa6b68f614e8c59e17bc5ded3495123a79178', 
      isNative: true,
      decimals: 6,
      iconUrl: 'https://token-image.suins.io/icon.svg'
    },
    {
      symbol: 'SEND',
      name: 'SEND',
      typeTag: '0x4e9d6f1c3d3f6b8e2c1c3f4e5d6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f::send::SEND',
      address: '0x4e9d6f1c3d3f6b8e2c1c3f4e5d6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f', 
      isNative: true,
      decimals: 6,
      iconUrl: 'https://suilend-assets.s3.us-east-2.amazonaws.com/SEND/SEND.svg'
    },
    {
      symbol: 'TYPUS',
      name: 'TYPUS',
      typeTag: '0xf82dc05634970553615eef6112a1ac4fb7bf10272bf6cbe0f80ef44a6c489385::typus::TYPUS',
      address: '0xf82dc05634970553615eef6112a1ac4fb7bf10272bf6cbe0f80ef44a6c489385', 
      isNative: true,
      decimals: 9,
      iconUrl: 'data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMTAyNCIgaGVpZ2h0PSIxMDI0IiB2aWV3Qm94PSIwIDAgMTAyNCAxMDI0IiBmaWxsPSJub25lIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPgo8Y2lyY2xlIGN4PSI1MTIiIGN5PSI1MTIiIHI9IjUxMiIgZmlsbD0iYmxhY2siLz4KPHBhdGggZD0iTTU0My4wNTIgMTc3LjA5M0M1NjYuMTA2IDE5Mi41NjcgNTg3LjI1NiAyMTUuNzc4IDYwMC41IDIzMS40NTZDNjI0Ljk2MSAyNjAuMjQ1IDY1Mi4xOTUgMjkxLjg0NSA2NjUuNzMgMzI3LjMxM0M2NzUuNDU2IDM1Mi44ODYgNjc2LjU3NCAzODIuOTc5IDY2MS45NjMgNDA2LjIzMUM2NDkuMzQgNDI2LjM0NyA2MjcuMTE0IDQzOC40NDEgNjA1Ljg4MSA0NDkuNjhDNTcyLjM1NiA0NjcuNDM1IDUzOC44MyA0ODUuMTg5IDUwNS4yMjIgNTAyLjk0NEM1MDMuODk4IDUwMy42MzYgNTAyLjQ5MSA1MDQuNDUgNTAxLjk5NCA1MDUuNzk0QzUwMS40MTUgNTA3LjIxOSA1MDIuMDc3IDUwOC43NjcgNTAyLjYxNSA1MTAuMTkyQzUwNi43NTQgNTIwLjM3MiA1MTEuMzA3IDUyOS4yNSA1MTMuNzA3IDUzOC42MTVDNTE2LjY4NyA1NTAuMTggNTE1LjU3IDU0MC44OTYgNTE3LjAxOCA1NjAuNDgzQzUxNy42MzkgNTY4Ljg3MSA1MTUuODU5IDU3OC40ODEgNTExLjY3OSA1ODYuMzgxQzUxMC4xNDggNTg5LjIzMiA1MDguNTc1IDU5My43MTEgNTA1LjUxMiA1OTQuNjg4QzQ5OS41OTQgNTk2LjU2MiA0NzUuNTQ2IDU2Ny42OSA0NjYuNzMgNTYyLjE1MkM0NDcuMDI5IDU0OS44MTQgNDM1LjMxNiA1NDMuNTgzIDQyNi41NDIgNTQ1Ljc4MkM0MjUuNDY1IDU0Ni4wMjcgNDA1LjM5MiA1NTcuMTg0IDM5Ni44MjQgNTY4LjI2QzM5MS40NDMgNTc1LjI2NCAzODYuMDIxIDU4My4xMjQgMzgxLjcxNyA1ODkuNzJDMzY1LjY5OSA2MTQuMTUzIDM3MS43MDEgNjM4Ljk1MiAzNzMuNzcgNjQ3LjQyMkMzODAuMTg2IDY3My45MzIgNDA3LjU0NCA2NzQuMjU4IDQzMC44ODcgNjczLjQ4NEM0NzUuNjcgNjcxLjk3NyA1MjIuNTIzIDY3NC42MjQgNTYxLjU5NSA2OTYuMjQ3QzU2OC43MTMgNzAwLjE5NyA1NzYuNDUzIDcwNy4zNjQgNTczLjU5NyA3MTQuODU3QzU3MS45ODMgNzE5LjAxIDU2Ny42MzcgNzIxLjQxMyA1NjMuNTQgNzIzLjI4NkM1NDUuMTIxIDczMS44MzcgNTI1LjU0NSA3MzguMDI3IDUwNS41MTIgNzQxLjU3QzQ4OS45NSA3NDQuMzM5IDQ3My42ODQgNzQ1LjY4MyA0NTkuODE4IDc1My4xMzVDNDQ0LjYyOCA3NjEuMjc5IDQzMy45OTEgNzc2LjAyIDQyNy4yMDQgNzkxLjY5OEM0MjEuNzQgODA0LjM2MiA0MTMuMjU2IDg2OS4xOSAzODkuMzc0IDg1Ny42MjVDMzg1LjE5NCA4NTUuNjMgMzgyLjI1NSA4NTEuODAyIDM3OS44NTQgODQ3Ljg5M0MzNjkuNzk3IDgzMS40NDEgMzY3LjcyNyA4MTEuOTc3IDM2MC4wMjkgNzk0LjU4OUMzNTEuMzc5IDc3NS4wMDIgMzM1LjUyNyA3NjUuMTg4IDMxOC40MzMgNzUzLjE3NUMyODMuMzc2IDcyOC41OCAyNTMuMTIxIDY5MS40NDIgMjQyLjMxOCA2NDkuOTg4QzIyNy43OSA1OTQuMzYzIDIzMS4yNjcgNTI0LjQ4NSAyNjAuOTAyIDQ3My43NDdDMjU0Ljk4MyA0NjcuNzIgMjUyLjAwMyA0NjcuMjMxIDIxOC40MzYgNDY5Ljc1NkMyMTMuNTUyIDQ3MC4xMjIgMTg2LjMxOCA0NzYuODQxIDE4My44MzUgNDcyLjYwNkMxODEuODQ4IDQ2OS4xODYgMTgzLjcxMSA0NjEuOTM3IDE4Ni4yMzYgNDU2LjAzM0MxODcuMDY0IDQ1NC4xNiAxODguMDU3IDQ1Mi4wMDEgMTg4LjcxOSA0NTAuNDU0QzE5Mi42NTEgNDQwLjUxOCAyMDAuMzkxIDQzMy42NzcgMjA4LjcxIDQyNi45OTlDMjMxLjgwNSA0MDguNDMgMjU2Ljg4NyAzOTIuOTE1IDI4NS4xMTUgMzgyLjgxNkMyOTMuNTE3IDM3OS44NDQgMjk3LjE1OSAzNzQuNjMxIDMwMC43MTggMzY2LjE2MUMzMzIuMjE1IDI5MS4zNTYgNDAzLjQwNSAxNjUuMDM5IDQ5Ny40ODMgMTYxLjA0OUM1MTIuMzgzIDE2MC4zNTYgNTI4LjE1MiAxNjcuMTE2IDU0My4wNTIgMTc3LjA5M1oiIGZpbGw9IndoaXRlIi8+CjxwYXRoIGQ9Ik04NDEgNTk5LjQyMUM3NzguNzQ5IDY0MC4xMDUgNzQyLjY2MSA2NzguOTY3IDc0NC4zMzcgNzAzQzc0NC4yNzIgNzAyLjkzNiA3NDQuMjcyIDcwMi44NzIgNzQ0LjI3MiA3MDIuODA4Qzc0MS4wNSA2NDcuNjE1IDcwOS4yOCA2MDQuMzExIDY3MC41NSA2MDQuMzExQzY2MS4yMDYgNjA0LjMxMSA2NTIuMjQ5IDYwNi44MzYgNjQ0IDYxMS40MzhDNzA0LjQ0NyA1NzEuODQxIDc0MC4wMTkgNTM0LjA2NSA3NDAuMTQ4IDUxMEM3NDMuOTUgNTY0LjQyNiA3NzUuNTI3IDYwNi44OTkgODEzLjg3IDYwNi44OTlDODIzLjQ3MiA2MDYuODk5IDgzMi42MjMgNjA0LjI0NyA4NDEgNTk5LjQyMVoiIGZpbGw9IndoaXRlIi8+Cjwvc3ZnPgo='
    },
    {
      symbol: 'WAL',
      name: 'WAL',
      typeTag: '0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59::wal::WAL',
      address: '0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59', 
      isNative: true,
      decimals: 9,
      iconUrl: 'https://www.walrus.xyz/wal-icon.svg'
    }
  ],
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
      tokens: parsed.tokens || defaultSettings.tokens, // Use parsed tokens or fallback to defaults
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

// Token utility functions
export function getTokenBySymbol(symbol: string, settings?: AppSettings): TokenInfo | undefined {
  const config = settings || loadSettings();
  return config.tokens.find(token => token.symbol === symbol);
}

export function getTokenInfo(symbol: string): TokenInfo | undefined {
  return getTokenBySymbol(symbol);
}

export function getTokenByAddress(address: string, settings?: AppSettings): TokenInfo | undefined {
  const config = settings || loadSettings();
  return config.tokens.find(token => token.address === address);
}

export function getTokenByTypeTag(typeTag: string, settings?: AppSettings): TokenInfo | undefined {
  const config = settings || loadSettings();
  return config.tokens.find(token => token.typeTag === typeTag);
}

export function getTokensByType(type: 'native' | 'stablecoin' | 'wrapped' | 'other', settings?: AppSettings): TokenInfo[] {
  const config = settings || loadSettings();

  switch (type) {
    case 'native':
      return config.tokens.filter(token => token.isNative);
    case 'stablecoin':
      return config.tokens.filter(token =>
        ['USDC', 'USDT', 'AUSD', 'WUSDC', 'WUSDT'].includes(token.symbol)
      );
    case 'wrapped':
      return config.tokens.filter(token =>
        token.symbol.startsWith('W') && !['WUSDC', 'WUSDT'].includes(token.symbol)
      );
    case 'other':
      return config.tokens.filter(token =>
        !token.isNative &&
        !['USDC', 'USDT', 'AUSD', 'WUSDC', 'WUSDT'].includes(token.symbol) &&
        !token.symbol.startsWith('W')
      );
    default:
      return [];
  }
}

export function getAllTokenSymbols(settings?: AppSettings): string[] {
  const config = settings || loadSettings();
  return config.tokens.map(token => token.symbol);
}

export function getTokenTypeTag(token: TokenInfo): string {
  if (token.typeTag) {
    return token.typeTag;
  }
  if (token.packageId && token.moduleName && token.structName) {
    return `${token.packageId}::${token.moduleName}::${token.structName}`;
  }
  return '';
}

// Convenience functions for common token lookups
export function getDefaultQuoteToken(): TokenInfo | undefined {
  return getTokenBySymbol('USDC');
}

export function getNativeToken(): TokenInfo | undefined {
  return getTokenBySymbol('SUI');
}

export function getStablecoins(): TokenInfo[] {
  return getTokensByType('stablecoin');
}

