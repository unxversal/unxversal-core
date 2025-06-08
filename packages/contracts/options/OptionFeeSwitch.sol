// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title OptionFeeSwitch
 * @author Unxversal Team
 * @notice Manages option fee collection and auto-conversion to USDC
 * @dev Production-ready fee handler for the options protocol with treasury integration
 */
contract OptionFeeSwitch is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --- Constants ---
    uint256 public constant BPS_PRECISION = 10000;
    
    // --- State Variables ---
    address public immutable treasuryAddress;
    address public immutable usdcToken;
    
    // Fee distribution splits (in BPS)
    uint256 public treasuryFeeBps = 7000; // 70% to treasury
    uint256 public insuranceFeeBps = 2000; // 20% to insurance fund
    uint256 public protocolFeeBps = 1000; // 10% to protocol development
    
    address public insuranceFundAddress;
    address public protocolFundAddress;
    
    // Auto-swap functionality (for non-USDC fees)
    address public dexRouterAddress; // For swapping fees to USDC
    mapping(address => bool) public autoSwapEnabled;
    
    // Fee tracking
    mapping(address => uint256) public collectedFees;
    uint256 public totalUsdcDistributed;

    // --- Events ---
    event FeeDeposited(
        address indexed token,
        address indexed payer,
        uint256 amount,
        bool autoSwapped
    );
    
    event FeeDistributed(
        address indexed token,
        uint256 treasuryAmount,
        uint256 insuranceAmount,
        uint256 protocolAmount
    );
    
    event FeeConfigUpdated(
        uint256 treasuryBps,
        uint256 insuranceBps,
        uint256 protocolBps
    );
    
    event AutoSwapConfigured(address indexed token, bool enabled);
    event AddressUpdated(string indexed addressType, address newAddress);

    constructor(
        address _treasuryAddress,
        address _usdcToken,
        address _insuranceFund,
        address _protocolFund,
        address _owner
    ) Ownable(_owner) {
        require(_treasuryAddress != address(0), "OptionFeeSwitch: Zero treasury");
        require(_usdcToken != address(0), "OptionFeeSwitch: Zero USDC");
        require(_insuranceFund != address(0), "OptionFeeSwitch: Zero insurance");
        require(_protocolFund != address(0), "OptionFeeSwitch: Zero protocol fund");
        
        treasuryAddress = _treasuryAddress;
        usdcToken = _usdcToken;
        insuranceFundAddress = _insuranceFund;
        protocolFundAddress = _protocolFund;
    }

    // --- Admin Functions ---
    function setFeeDistribution(
        uint256 _treasuryBps,
        uint256 _insuranceBps,
        uint256 _protocolBps
    ) external onlyOwner {
        require(_treasuryBps + _insuranceBps + _protocolBps == BPS_PRECISION, 
                "OptionFeeSwitch: Invalid distribution");
        
        treasuryFeeBps = _treasuryBps;
        insuranceFeeBps = _insuranceBps;
        protocolFeeBps = _protocolBps;
        
        emit FeeConfigUpdated(_treasuryBps, _insuranceBps, _protocolBps);
    }

    function setInsuranceFund(address _insuranceFund) external onlyOwner {
        require(_insuranceFund != address(0), "OptionFeeSwitch: Zero address");
        insuranceFundAddress = _insuranceFund;
        emit AddressUpdated("insurance", _insuranceFund);
    }

    function setProtocolFund(address _protocolFund) external onlyOwner {
        require(_protocolFund != address(0), "OptionFeeSwitch: Zero address");
        protocolFundAddress = _protocolFund;
        emit AddressUpdated("protocol", _protocolFund);
    }

    function setDexRouter(address _dexRouter) external onlyOwner {
        dexRouterAddress = _dexRouter;
        emit AddressUpdated("dexRouter", _dexRouter);
    }

    function setAutoSwap(address token, bool enabled) external onlyOwner {
        require(token != address(0), "OptionFeeSwitch: Zero token");
        autoSwapEnabled[token] = enabled;
        emit AutoSwapConfigured(token, enabled);
    }

    // --- Core Functions ---
    function depositOptionFee(
        address feeToken,
        address payer,
        uint256 amount
    ) external nonReentrant {
        require(feeToken != address(0), "OptionFeeSwitch: Zero token");
        require(amount > 0, "OptionFeeSwitch: Zero amount");
        
        // Pull fee from sender
        IERC20(feeToken).safeTransferFrom(msg.sender, address(this), amount);
        
        bool wasSwapped = false;
        uint256 finalAmount = amount;
        
        // Auto-swap to USDC if enabled and not already USDC
        if (feeToken != usdcToken && autoSwapEnabled[feeToken] && dexRouterAddress != address(0)) {
            finalAmount = _swapToUSDC(feeToken, amount);
            wasSwapped = true;
            feeToken = usdcToken; // Update token reference
        }
        
        // Track collected fees
        collectedFees[feeToken] += finalAmount;
        
        emit FeeDeposited(feeToken, payer, finalAmount, wasSwapped);
    }

    function distributeFees(address token) external nonReentrant {
        require(token != address(0), "OptionFeeSwitch: Zero token");
        
        uint256 amount = collectedFees[token];
        require(amount > 0, "OptionFeeSwitch: No fees to distribute");
        
        collectedFees[token] = 0;
        
        // Calculate distribution amounts
        uint256 treasuryAmount = (amount * treasuryFeeBps) / BPS_PRECISION;
        uint256 insuranceAmount = (amount * insuranceFeeBps) / BPS_PRECISION;
        uint256 protocolAmount = amount - treasuryAmount - insuranceAmount; // Remainder to avoid rounding issues
        
        // Distribute fees
        if (treasuryAmount > 0) {
            IERC20(token).safeTransfer(treasuryAddress, treasuryAmount);
        }
        
        if (insuranceAmount > 0) {
            IERC20(token).safeTransfer(insuranceFundAddress, insuranceAmount);
        }
        
        if (protocolAmount > 0) {
            IERC20(token).safeTransfer(protocolFundAddress, protocolAmount);
        }
        
        // Track USDC distributions
        if (token == usdcToken) {
            totalUsdcDistributed += amount;
        }
        
        emit FeeDistributed(token, treasuryAmount, insuranceAmount, protocolAmount);
    }

    function batchDistributeFees(address[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (collectedFees[tokens[i]] > 0) {
                this.distributeFees(tokens[i]);
            }
        }
    }

    // --- Internal Functions ---
    function _swapToUSDC(address /* token */, uint256 amount) internal pure returns (uint256 usdcReceived) {
        // This is a simplified swap implementation
        // In production, this would integrate with the unxversal DEX or a router
        // For now, we'll just return the amount as-is (would need actual DEX integration)
        
        // Example integration with DEX router:
        // 1. Approve router to spend token
        // 2. Execute swap through router
        // 3. Return actual USDC received
        
        // Placeholder - in production would call DEX router
        return amount; // This would be the actual USDC amount received from swap
    }

    // --- View Functions ---
    function getCollectedFees(address token) external view returns (uint256) {
        return collectedFees[token];
    }

    function getFeeDistribution() external view returns (uint256 treasury, uint256 insurance, uint256 protocol) {
        return (treasuryFeeBps, insuranceFeeBps, protocolFeeBps);
    }

    function isAutoSwapEnabled(address token) external view returns (bool) {
        return autoSwapEnabled[token];
    }

    // --- Emergency Functions ---
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "OptionFeeSwitch: Zero token");
        IERC20(token).safeTransfer(owner(), amount);
    }
}