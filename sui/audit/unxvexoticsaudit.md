# Audit: unxvexotics

## Current On-Chain Approach
- **Product Listing:** Only admin can add new exotic payoff structures and products (admin_cap required).
- **Trading:** Exotics are traded via custom logic, with DeepBook integration for liquidity.
- **Orderbook:** DeepBook is permissionless, but registry is permissioned for product listing.

## Proper Permissionless Orderbook Approach
- **Product Listing:** Allow anyone to propose or create new exotic products/markets (with risk parameters set by template or market).
- **Orderbook:** DeepBook is already permissionless; registry could be made permissionless or auto-index all DeepBook pools.

## Recommended Architectural Changes
- Make registry permissionless or auto-index all DeepBook pools.
- Remove admin_cap requirement for product addition, or add a permissionless listing flow.

## Observations
- Trading is already permissionless at the DeepBook layer.
- Registry is a convenience layer; making it permissionless would align with DeFi best practices. 