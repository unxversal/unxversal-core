# Audit: unxvsynthetics

## Current On-Chain Approach
- **Asset Listing:** Only admin can create new synthetic assets (admin_cap required).
- **Pricing:** Synthetics are minted/burned at oracle price (Pyth), not via orderbook.
- **Trading:** No on-chain orderbook; trading is via mint/burn against collateral.
- **Market Creation:** Permissioned (admin only).

## Proper Permissionless Orderbook Approach
- **Asset Listing:** Only synthetics (admin only) should remain permissioned; all other protocols should allow permissionless market creation.
- **Trading:** Synthetics themselves are not orderbook-traded, but could be paired with DEX pools for orderbook trading.
- **Orderbook:** If desired, allow anyone to create a DeepBook pool for any synthetic asset, enabling orderbook trading.

## Recommended Architectural Changes
- Keep admin-only listing for synthetics (risk management).
- Encourage DEX/DeepBook pools for synthetics to enable orderbook trading.
- Consider adding hooks/events for permissionless pool creation.

## Observations
- Protocol is robust for collateralized synthetics.
- Permissionless trading is possible via DEX, but asset listing is intentionally permissioned for risk control.
- No major architectural flaws for its intended use-case. 