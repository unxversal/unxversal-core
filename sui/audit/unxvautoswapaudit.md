# Audit: unxvautoswap

## Current On-Chain Approach
- **Asset Listing:** Only admin can add supported assets and configure pools (admin_cap required).
- **Swaps:** All swaps are executed via DeepBook pools (permissionless at DeepBook layer).
- **Orderbook:** DeepBook is permissionless, but AutoSwap registry is permissioned.

## Proper Permissionless Orderbook Approach
- **Asset Listing:** Allow anyone to add asset pairs to the registry, or auto-index all DeepBook pools.
- **Orderbook:** DeepBook is already permissionless; registry could be made permissionless or simply index all pools.

## Recommended Architectural Changes
- Make AutoSwap registry permissionless or auto-index all DeepBook pools.
- Remove admin_cap requirement for asset addition, or add a permissionless listing flow.

## Observations
- Swapping is already permissionless at the DeepBook layer.
- Registry is a convenience layer; making it permissionless would align with DeFi best practices. 