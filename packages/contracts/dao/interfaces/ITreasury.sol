// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITreasury
 * @author Unxversal Team
 * @notice Interface for the Treasury contract that manages protocol assets
 */
interface ITreasury {
    // --- Events ---
    event FeeDeposited(address indexed token, address indexed from, uint256 amount);
    event AssetTransferred(address indexed token, address indexed to, uint256 amount);
    event BuybackExecuted(address indexed token, uint256 amountIn, uint256 unxvOut);
    event RevenueDistributed(address indexed token, uint256 amount, uint256 timestamp);
    event WhitelistUpdated(address indexed token, bool status);

    // --- Core Functions ---
    function depositFee(address token, uint256 amount) external;
    function transferAsset(address token, address to, uint256 amount) external;
    function executeBuyback(address token, uint256 amount, uint256 minUnxvOut) external;
    function distributeRevenue(address token, uint256 amount) external;
    function batchDistributeRevenue(address[] calldata tokens, uint256[] calldata amounts) external;

    // --- Admin Functions ---
    function setTokenWhitelist(address token, bool status) external;
    function emergencyWithdraw(address token, address to, uint256 amount) external;

    // --- View Functions ---
    function getBalance(address token) external view returns (uint256);
    function isWhitelisted(address token) external view returns (bool);
    function getTotalRevenue(address token) external view returns (uint256);
} 