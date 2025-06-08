// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IOracleRelayer
 * @notice Interface for contracts that provide oracle price data.
 * @dev This interface is implemented by OracleRelayerDst on the Peaq network.
 */
interface IOracleRelayer {
    /**
     * @notice Fetches the latest price for a given asset.
     * @dev Reverts if the price is stale (older than `staleToleranceSec`) or not available.
     * @param assetId The unique identifier for the asset.
     * @return price The price of the asset, typically in a fixed-point format (e.g., 18 decimals USD).
     */
    function getPrice(uint256 assetId) external view returns (uint256 price);

    /**
     * @notice Fetches the latest price data including its last update time.
     * @dev Reverts if the price is not available for the given assetId.
     * @dev It is the responsibility of the caller to check `lastUpdatedAt` against `staleToleranceSec`
     *      or current block.timestamp if staleness is a concern for their specific use case.
     * @param assetId The unique identifier for the asset.
     * @return price The price of the asset.
     * @return lastUpdatedAt The Unix timestamp of when the price was last updated by the oracle source (e.g., Chainlink).
     */
    function getPriceData(uint256 assetId) external view returns (uint256 price, uint32 lastUpdatedAt);

    /**
     * @notice Checks if a price for a given asset is considered stale based on the configured tolerance.
     * @param assetId The unique identifier for the asset.
     * @return isStale True if the price is stale or not available, false otherwise.
     */
    function isPriceStale(uint256 assetId) external view returns (bool);

    /**
     * @notice Retrieves the configured stale tolerance for price data.
     * @return The stale tolerance in seconds.
     */
    function staleToleranceSec() external view returns (uint32);
}