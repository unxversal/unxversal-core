import { SuiClient, getFullnodeUrl, SuiHTTPTransport } from '@mysten/sui/client';

export type NetworkName = 'mainnet' | 'testnet' | 'devnet' | 'localnet';

export type RpcConfig = {
  url: string;
  websocketUrl?: string;
  headers?: Record<string, string>;
  label?: string;
};

export function createSuiClient(rpc: RpcConfig): SuiClient {
  return new SuiClient({
    transport: new SuiHTTPTransport({
      url: rpc.url,
      websocket: rpc.websocketUrl ? { url: rpc.websocketUrl, reconnectTimeout: 1000 } : undefined,
      rpc: { headers: rpc.headers },
    }),
  });
}

export function defaultRpc(network: NetworkName): RpcConfig {
  return { url: getFullnodeUrl(network), label: network };
}


