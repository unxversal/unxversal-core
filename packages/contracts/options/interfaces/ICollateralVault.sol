// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ICollateralVault
 * @author Unxversal Team
 * @notice Interface for the CollateralVault contract - manages option collateral
 */
interface ICollateralVault {
    // --- Events ---
    event CollateralLocked(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 indexed optionId
    );
    
    event CollateralReleased(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 indexed optionId
    );

    // --- Functions ---
    function lockCollateral(
        address user,
        address token,
        uint256 amount,
        uint256 optionId
    ) external;

    function releaseCollateral(
        address user,
        address token,
        uint256 amount,
        uint256 optionId
    ) external;

    function getLockedAmount(
        address user,
        address token,
        uint256 optionId
    ) external view returns (uint256);
} 