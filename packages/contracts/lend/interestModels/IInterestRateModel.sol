// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IInterestRateModel
 * @author Unxversal Team
 * @notice Interface for interest rate models.
 * @dev Defines how borrow and supply rates are calculated for a given market.
 */
interface IInterestRateModel {
    /**
     * @notice Calculates the current borrow interest rate per block.
     * @param underlyingBalance The amount of underlying tokens currently in the uToken contract.
     * @param totalBorrows The total amount of underlying tokens currently borrowed from this market.
     * @param totalReserves The total amount of reserves accumulated for this market (if applicable to rate).
     * @return The borrow interest rate per block (e.g., scaled by 1e18 for a rate like 0.000001% per block).
     */
    function getBorrowRate(
        uint256 underlyingBalance,
        uint256 totalBorrows,
        uint256 totalReserves
    ) external view returns (uint256);

    /**
     * @notice Calculates the current supply interest rate per block.
     * @dev Supply Rate = Borrow Rate * Utilization Rate * (1 - Reserve Factor)
     * @param underlyingBalance The amount of underlying tokens currently in the uToken contract.
     * @param totalBorrows The total amount of underlying tokens currently borrowed.
     * @param totalReserves The total amount of reserves accumulated.
     * @param reserveFactorMantissa The reserve factor for the market (e.g., 0.1 * 1e18 for 10%).
     * @return The supply interest rate per block (e.g., scaled by 1e18).
     */
    function getSupplyRate(
        uint256 underlyingBalance,
        uint256 totalBorrows,
        uint256 totalReserves,
        uint256 reserveFactorMantissa
    ) external view returns (uint256);

    // Some models might expose their parameters
    // function getModelParameters() external view returns (bytes memory);
}