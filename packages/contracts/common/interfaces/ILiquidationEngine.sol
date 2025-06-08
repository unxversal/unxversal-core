// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILiquidationEngine
 * @author Unxversal Team
 * @notice Interface for contracts that handle the liquidation of undercollateralized
 *         positions or risky accounts within a DeFi protocol.
 * @dev Specific implementations will handle different types of positions (e.g., synth debt,
 *      loans, perpetual futures) and their respective liquidation mechanisms.
 */
interface ILiquidationEngine {
    /**
     * @notice Emitted when a position is successfully liquidated.
     * @param liquidator The address that initiated the liquidation.
     * @param account The address of the account/position that was liquidated.
     * @param collateralSeizedAsset The address of the collateral asset seized by the liquidator.
     * @param collateralSeizedAmount The amount of collateral asset seized.
     * @param debtRepaidAsset The address of the debt asset that was repaid.
     * @param debtRepaidAmount The amount of debt asset repaid.
     */
    event PositionLiquidated(
        address indexed liquidator,
        address indexed account,
        address collateralSeizedAsset,
        uint256 collateralSeizedAmount,
        address debtRepaidAsset,
        uint256 debtRepaidAmount
    );

    // Note: The `liquidate` function signature can vary significantly based on the protocol.
    // For example:
    // - Synth: liquidate(accountToLiquidate, synthToRepay, amountToRepayInSynth)
    // - Lend: liquidate(borrower, collateralToSeize, repayAmount, assetToRepay)
    // - Perps: liquidate(trader, marketId, portionToClose)
    //
    // It's challenging to create a single `liquidate` signature that fits all perfectly
    // without becoming overly generic or complex with structs.
    //
    // Option 1: Keep it very generic (less useful for direct type checking).
    // function liquidate(address account, bytes calldata data) external returns (bool success);
    //
    // Option 2: Define common parameters, and let implementations add specifics.
    // This is still hard because "collateral" and "debt" concepts vary.
    //
    // Option 3: Don't define a specific `liquidate` signature in this common interface.
    // Instead, let each protocol's liquidation engine (e.g., `SynthLiquidationEngine.sol`)
    // define its own `liquidate` function tailored to its needs. This common interface
    // would then primarily serve as a marker or for shared events/view functions if any.
    //
    // Given the diversity, Option 3 is often more practical. Individual liquidation contracts
    // will have their own public `liquidate` functions. This common interface can then
    // be used for common view functions or to group them conceptually.

    /**
     * @notice Checks if a given account or position is eligible for liquidation.
     * @dev The definition of "eligible" is protocol-specific (e.g., health factor < 1, CR < minCR).
     * @param account The address of the account or an identifier for the position.
     * @return isLiquidatable True if the account/position can be liquidated, false otherwise.
     */
    function isLiquidatable(address account) external view returns (bool);

    // Potentially, add other common view functions:
    // function getLiquidationPenalty(address asset) external view returns (uint256 penaltyBps);
    // function getCloseFactor(address asset) external view returns (uint256 closeFactorBps);

    // For now, `isLiquidatable` is a good common candidate.
    // The actual `liquidate` function will be specific to each protocol's engine.
}