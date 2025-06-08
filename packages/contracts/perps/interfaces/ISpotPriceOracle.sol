// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISpotPriceOracle
 * @author Unxversal Team
 * @notice Interface for a contract that provides a spot price for an asset,
 *         typically used as the "index price" for perpetuals funding rate calculation.
 * @dev The price returned should be a reliable representation of the underlying asset's
 *      current spot market value, potentially a Time-Weighted Average Price (TWAP).
 */
interface ISpotPriceOracle {
    /**
     * @notice Fetches the latest spot price of the asset this oracle represents.
     * @dev The price should be returned scaled by a consistent precision, e.g., 1e18 for USD value.
     *      Implementations should handle any necessary decimal conversions.
     * @return price The spot price of the asset.
     */
    function getPrice() external view returns (uint256 price);

    /**
     * @notice Returns the number of decimals for the price returned by `getPrice()`.
     * @dev For example, if prices are returned scaled to 1e18, this would return 18.
     *      This helps consumers correctly interpret the price.
     *      Alternatively, `getPrice()` can always return a value normalized to a common precision (e.g. 1e18 USD).
     *      If `getPrice` always returns 1e18-scaled USD value, this might not be strictly needed
     *      but can be good for explicitness. Let's assume `getPrice` returns 1e18 scaled.
     * @return decimals The number of decimals for the returned price.
     */
    // function decimals() external view returns (uint8); // Optional, if price is always 1e18 scaled.

    /**
     * @notice Returns the timestamp of the last price update.
     * @dev Useful for checking staleness.
     * @return lastUpdatedAt The Unix timestamp of the last update.
     */
    function lastUpdatedAt() external view returns (uint256); // uint256 for flexibility with different oracle sources

    // Optional: If the oracle is for a specific asset pair
    // function baseAsset() external view returns (address);
    // function quoteAsset() external view returns (address);
}