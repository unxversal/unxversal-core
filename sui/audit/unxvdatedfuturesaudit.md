# Audit: unxvdatedfutures

## Current On-Chain Approach
- **Contract Listing:** Only admin can create new futures contracts (admin_cap required).
- **Trading:** Futures are traded via DeepBook pools, with on-chain margining and settlement.
- **Orderbook:** DeepBook is permissionless, but Futures registry is permissioned.

## Proper Permissionless Orderbook Approach
- **Contract Listing:** Allow anyone to create new futures contracts (with risk parameters set by template or market).
- **Orderbook:** DeepBook is already permissionless; registry could be made permissionless or auto-index all DeepBook pools.

## Recommended Architectural Changes
- Make Futures registry permissionless or auto-index all DeepBook pools.
- Remove admin_cap requirement for contract addition, or add a permissionless listing flow.

## Observations
- Trading is already permissionless at the DeepBook layer.
- Registry is a convenience layer; making it permissionless would align with DeFi best practices. 