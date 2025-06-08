// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IFlashLoanReceiver
 * @author Unxversal Team
 * @notice Interface for contracts that can receive flash loans from CorePool
 */
interface IFlashLoanReceiver {
    /**
     * @notice Called by CorePool during a flash loan
     * @param asset The address of the underlying asset being flash loaned
     * @param amount The amount of underlying asset being flash loaned
     * @param fee The fee that must be paid on top of the amount
     * @param initiator The address that initiated the flash loan
     * @param data Arbitrary data passed from the flash loan caller
     * @return Must return true for the flash loan to succeed
     */
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 fee,
        address initiator,
        bytes calldata data
    ) external returns (bool);
} 