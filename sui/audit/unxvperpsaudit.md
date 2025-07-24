# Audit: unxvperps

## Current On-Chain Approach
- **Market Listing:** Only admin can add new perpetual markets (admin_cap required).
- **Trading:** Perpetuals are traded via DeepBook pools, with on-chain margining and funding.
- **Orderbook:** DeepBook is permissionless, but Perpetuals registry is permissioned.

## Proper Permissionless Orderbook Approach
- **Market Listing:** Allow anyone to create new perpetual markets (with risk parameters set by template or market).
- **Orderbook:** DeepBook is already permissionless; registry could be made permissionless or auto-index all DeepBook pools.

## Recommended Architectural Changes
- Make Perpetuals registry permissionless or auto-index all DeepBook pools.
- Remove admin_cap requirement for market addition, or add a permissionless listing flow.

## Observations
- Trading is already permissionless at the DeepBook layer.
- Registry is a convenience layer; making it permissionless would align with DeFi best practices. 