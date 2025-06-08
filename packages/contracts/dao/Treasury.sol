// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Treasury
 * @notice Manages protocol fees and assets, controlled by governance
 */
contract Treasury is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Events
    event AssetSwept(address indexed token, address indexed to, uint256 amount);
    event NativeSwept(address indexed to, uint256 amount);
    event FeeDeposited(address indexed token, uint256 amount);
    event WhitelistUpdated(address indexed token, bool status);

    // State
    mapping(address => bool) public whitelistedTokens;
    mapping(address => uint256) public feeAccrued;

    constructor() Ownable(msg.sender) {
        // USDC is always whitelisted
        whitelistedTokens[0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = true;
    }

    /**
     * @notice Deposit protocol fees
     * @param token Token address
     * @param amount Amount to deposit
     */
    function depositFee(address token, uint256 amount) external nonReentrant {
        require(whitelistedTokens[token], "Token not whitelisted");
        require(amount > 0, "Cannot deposit 0");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        feeAccrued[token] += amount;

        emit FeeDeposited(token, amount);
    }

    /**
     * @notice Sweep tokens to a destination (governance only)
     * @param token Token to sweep
     * @param to Destination address
     * @param amount Amount to sweep
     */
    function sweepToken(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(to != address(0), "Cannot sweep to zero address");
        require(amount > 0, "Cannot sweep 0");
        require(amount <= IERC20(token).balanceOf(address(this)), "Insufficient balance");

        IERC20(token).safeTransfer(to, amount);
        emit AssetSwept(token, to, amount);
    }

    /**
     * @notice Sweep native tokens (governance only)
     * @param to Destination address
     * @param amount Amount to sweep
     */
    function sweepNative(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Cannot sweep to zero address");
        require(amount > 0, "Cannot sweep 0");
        require(amount <= address(this).balance, "Insufficient balance");

        (bool success,) = to.call{value: amount}("");
        require(success, "Native transfer failed");
        emit NativeSwept(to, amount);
    }

    /**
     * @notice Update token whitelist status (governance only)
     * @param token Token address
     * @param status New whitelist status
     */
    function setTokenWhitelist(address token, bool status) external onlyOwner {
        whitelistedTokens[token] = status;
        emit WhitelistUpdated(token, status);
    }

    /**
     * @notice Get accrued fees for a token
     * @param token Token address
     * @return Amount of fees accrued
     */
    function getAccruedFees(address token) external view returns (uint256) {
        return feeAccrued[token];
    }

    // Allow receiving native token
    receive() external payable {}
}
