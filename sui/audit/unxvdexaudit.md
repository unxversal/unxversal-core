# Audit: unxvdex

## Current On-Chain Approach
- **Pool Listing:** Only admin can add supported pools (admin_cap required).
- **Trading:** All trades are executed via DeepBook orderbook (permissionless at DeepBook layer).
- **Orderbook:** DeepBook is fully permissionless for pool creation, but DEX registry is permissioned.

## Proper Permissionless Orderbook Approach
- **Pool Listing:** Allow anyone to add pools to the DEX registry, or make registry a permissionless aggregator of DeepBook pools.
- **Orderbook:** DeepBook itself is permissionless; DEX registry could be made permissionless or simply index all DeepBook pools.

## Recommended Architectural Changes
- Make DEX registry permissionless or auto-index all DeepBook pools.
- Remove admin_cap requirement for pool addition, or add a permissionless listing flow with optional curation.

## Observations
- Trading is already permissionless at the DeepBook layer.
- DEX registry is a convenience layer; making it permissionless would align with DeFi best practices. 