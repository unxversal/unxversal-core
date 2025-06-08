// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/ICollateralVault.sol";

/**
 * @title CollateralVault
 * @author Unxversal Team
 * @notice Securely manages collateral for options contracts
 * @dev Simplified and production-ready implementation with proper access control
 */
contract CollateralVault is Ownable, ReentrancyGuard, Pausable, ICollateralVault {
    using SafeERC20 for IERC20;

    // --- State Variables ---
    address public optionNFTContract;
    
    // Tracks locked collateral: user => token => optionId => amount
    mapping(address => mapping(address => mapping(uint256 => uint256))) public lockedCollateral;
    
    // Total locked per user and token
    mapping(address => mapping(address => uint256)) public totalLocked;

    // --- Events ---
    event OptionNFTSet(address indexed optionNFT);

    // --- Modifiers ---
    modifier onlyOptionNFT() {
        require(msg.sender == optionNFTContract, "CollateralVault: Not authorized");
        _;
    }

    constructor(address _owner, address _optionNFT) Ownable(_owner) {
        require(_optionNFT != address(0), "CollateralVault: Zero option NFT");
        optionNFTContract = _optionNFT;
        emit OptionNFTSet(_optionNFT);
    }

    // --- Admin Functions ---
    function setOptionNFTContract(address _optionNFT) external onlyOwner {
        require(_optionNFT != address(0), "CollateralVault: Zero address");
        optionNFTContract = _optionNFT;
        emit OptionNFTSet(_optionNFT);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --- Core Functions ---
    function lockCollateral(
        address user,
        address token,
        uint256 amount,
        uint256 optionId
    ) external nonReentrant whenNotPaused onlyOptionNFT {
        require(user != address(0), "CollateralVault: Zero user");
        require(token != address(0), "CollateralVault: Zero token");
        require(amount > 0, "CollateralVault: Zero amount");

        lockedCollateral[user][token][optionId] = amount;
        totalLocked[user][token] += amount;

        emit CollateralLocked(user, token, amount, optionId);
    }

    function releaseCollateral(
        address user,
        address token,
        uint256 amount,
        uint256 optionId
    ) external nonReentrant whenNotPaused onlyOptionNFT {
        require(user != address(0), "CollateralVault: Zero user");
        require(token != address(0), "CollateralVault: Zero token");
        require(amount > 0, "CollateralVault: Zero amount");

        uint256 locked = lockedCollateral[user][token][optionId];
        require(locked >= amount, "CollateralVault: Insufficient locked");

        lockedCollateral[user][token][optionId] = locked - amount;
        totalLocked[user][token] -= amount;

        // Transfer tokens to OptionNFT for distribution
        IERC20(token).safeTransfer(optionNFTContract, amount);

        emit CollateralReleased(user, token, amount, optionId);
    }

    // --- View Functions ---
    function getLockedAmount(
        address user,
        address token,
        uint256 optionId
    ) external view returns (uint256) {
        return lockedCollateral[user][token][optionId];
    }

    function getTotalLocked(address user, address token) external view returns (uint256) {
        return totalLocked[user][token];
    }

    // --- Emergency Functions ---
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "CollateralVault: Zero token");
        IERC20(token).safeTransfer(owner(), amount);
    }
}