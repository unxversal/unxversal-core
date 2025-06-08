// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ICorePoolLens
 * @author Unxversal Team
 * @notice Minimal interface for LendRiskController to query user balances from CorePool.
 */
interface ICorePoolLens {
    /**
     * @notice Gets a user's supply balance (in uTokens) and borrow balance (in underlying) for a specific asset.
     * @param user The user's address.
     * @param underlyingAsset The address of the underlying asset for the market.
     * @return uTokenSupplyBalance The amount of uTokens the user holds for this market.
     * @return underlyingBorrowBalance The amount of underlying asset the user has borrowed from this market.
     */
    function getUserSupplyAndBorrowBalance(address user, address underlyingAsset)
        external view returns (uint256 uTokenSupplyBalance, uint256 underlyingBorrowBalance);

    /**
     * @notice Gets all assets a user has supplied uTokens for.
     * @param user The user's address.
     * @return An array of underlying asset addresses.
     */
    function getAssetsUserSupplied(address user) external view returns (address[] memory);

    /**
     * @notice Gets all assets a user has borrowed.
     * @param user The user's address.
     * @return An array of underlying asset addresses.
     */
    function getAssetsUserBorrowed(address user) external view returns (address[] memory);

    // Potentially other views LendRiskController might need from CorePool:
    // function getMarketInfo(address underlyingAsset) external view returns (...);
    // function uTokenAddress(address underlyingAsset) external view returns (address);
}