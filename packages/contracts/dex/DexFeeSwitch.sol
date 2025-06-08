// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/dex/IDexFeeSwitch.sol";
import "../common/OracleRelayerDst.sol";

/**
 * @title DexFeeSwitch
 * @author Unxversal Team
 * @notice Manages fee collection, tiers, and UNXV staking for fee discounts
 */
contract DexFeeSwitch is IDexFeeSwitch, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* ──────────────── Storage ──────────────── */

    // Core addresses
    address public immutable USDC;
    address public immutable UNXV;
    OracleRelayerDst public immutable oracle;

    // Fee tiers
    mapping(uint256 => FeeTier) public feeTiers;
    uint256 public numTiers;

    // User state
    mapping(address => uint256) public userVolume;    // In USDC terms
    mapping(address => uint256) public unxvStaked;    // Amount of UNXV staked
    mapping(address => uint256) public lastStakeTime; // For unstaking delay

    // Constants
    uint256 public constant MIN_STAKE_DURATION = 7 days;
    uint256 public constant MAX_FEE_BPS = 1000;      // 10%
    uint256 public constant MAX_REBATE_BPS = 800;    // 8%
    uint256 public constant MAX_RELAYER_SHARE = 500; // 5%

    /* ──────────────── Constructor ──────────────── */

    constructor(
        address _usdc,
        address _unxv,
        address _oracle,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_usdc != address(0), "DexFeeSwitch: zero USDC");
        require(_unxv != address(0), "DexFeeSwitch: zero UNXV");
        require(_oracle != address(0), "DexFeeSwitch: zero oracle");

        USDC = _usdc;
        UNXV = _unxv;
        oracle = OracleRelayerDst(_oracle);

        // Initialize default fee tiers
        _setFeeTier(0, 0, 10, 0, 50);           // < $10k: 0.1% fee, no rebate
        _setFeeTier(1, 10_000e6, 8, 2, 50);     // $10k+: 0.08% fee, 0.02% rebate
        _setFeeTier(2, 100_000e6, 6, 3, 50);    // $100k+: 0.06% fee, 0.03% rebate
        _setFeeTier(3, 1_000_000e6, 5, 4, 50);  // $1M+: 0.05% fee, 0.04% rebate
    }

    /* ──────────────── External functions ──────────────── */

    /// @inheritdoc IDexFeeSwitch
    function getUserFeeTier(address user) public view override returns (FeeTier memory) {
        uint256 volume = userVolume[user];
        uint256 stake = unxvStaked[user];

        // Find the highest tier the user qualifies for
        for (uint256 i = numTiers - 1; i >= 0; i--) {
            FeeTier memory tier = feeTiers[i];
            if (volume >= tier.volumeThreshold) {
                // Apply UNXV staking bonus if any
                if (stake > 0) {
                    // Increase rebate by up to 50% based on stake size
                    uint256 bonus = (tier.rebateBps * stake) / (1000e18); // 1000 UNXV = max bonus
                    tier.rebateBps = uint24(Math.min(
                        tier.rebateBps + bonus,
                        MAX_REBATE_BPS
                    ));
                }
                return tier;
            }
        }

        // Default to base tier
        return feeTiers[0];
    }

    /// @inheritdoc IDexFeeSwitch
    function getUserVolume(address user) external view override returns (uint256) {
        return userVolume[user];
    }

    /// @inheritdoc IDexFeeSwitch
    function getUnxvStaked(address user) external view override returns (uint256) {
        return unxvStaked[user];
    }

    /// @inheritdoc IDexFeeSwitch
    function depositFee(
        address token,
        address payer,
        uint256 amount,
        address relayer
    ) external override nonReentrant returns (uint256 usdcAmount) {
        require(amount > 0, "DexFeeSwitch: zero amount");

        // Pull fee token
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Convert to USDC equivalent
        usdcAmount = getUSDCValue(token, amount);
        require(usdcAmount > 0, "DexFeeSwitch: zero USDC value");

        // Update user's volume
        userVolume[payer] += usdcAmount;

        // Handle relayer share if specified
        uint256 relayerShare = 0;
        if (relayer != address(0)) {
            FeeTier memory tier = getUserFeeTier(payer);
            relayerShare = (usdcAmount * tier.relayerShareBps) / 10000;
            if (relayerShare > 0) {
                IERC20(USDC).safeTransfer(relayer, relayerShare);
            }
        }

        // Convert remaining fee to USDC if needed
        if (token != USDC) {
            // TODO: Implement swap to USDC via whitelisted DEX
            // For now, just transfer the token to treasury
            IERC20(token).safeTransfer(owner(), amount);
        } else {
            // Transfer USDC directly to treasury
            IERC20(USDC).safeTransfer(owner(), amount - relayerShare);
        }

        emit FeeDeposited(token, payer, owner(), amount, usdcAmount);
    }

    /// @inheritdoc IDexFeeSwitch
    function stakeUnxv(uint256 amount) external override nonReentrant {
        require(amount > 0, "DexFeeSwitch: zero stake");

        // Pull UNXV tokens
        IERC20(UNXV).safeTransferFrom(msg.sender, address(this), amount);

        // Update state
        unxvStaked[msg.sender] += amount;
        lastStakeTime[msg.sender] = block.timestamp;

        emit UnxvStaked(msg.sender, amount, unxvStaked[msg.sender]);
    }

    /// @inheritdoc IDexFeeSwitch
    function unstakeUnxv(uint256 amount) external override nonReentrant {
        require(amount > 0, "DexFeeSwitch: zero unstake");
        require(amount <= unxvStaked[msg.sender], "DexFeeSwitch: insufficient stake");
        require(
            block.timestamp >= lastStakeTime[msg.sender] + MIN_STAKE_DURATION,
            "DexFeeSwitch: stake locked"
        );

        // Update state
        unxvStaked[msg.sender] -= amount;

        // Return UNXV tokens
        IERC20(UNXV).safeTransfer(msg.sender, amount);

        emit UnxvUnstaked(msg.sender, amount, unxvStaked[msg.sender]);
    }

    /// @inheritdoc IDexFeeSwitch
    function setFeeTier(
        uint256 tierId,
        uint256 volumeThreshold,
        uint24 feeBps,
        uint24 rebateBps,
        uint24 relayerShareBps
    ) external override onlyOwner {
        _setFeeTier(tierId, volumeThreshold, feeBps, rebateBps, relayerShareBps);
    }

    /// @inheritdoc IDexFeeSwitch
    function getUSDCValue(
        address token,
        uint256 amount
    ) public view override returns (uint256) {
        if (token == USDC) return amount;

        try oracle.getPrice(uint256(uint160(token))) returns (uint256 price) {
            // Price is in USDC terms with 18 decimals
            return (amount * price) / 1e18;
        } catch {
            revert("DexFeeSwitch: price not available");
        }
    }

    /* ──────────────── Internal functions ──────────────── */

    function _setFeeTier(
        uint256 tierId,
        uint256 volumeThreshold,
        uint24 feeBps,
        uint24 rebateBps,
        uint24 relayerShareBps
    ) internal {
        require(feeBps <= MAX_FEE_BPS, "DexFeeSwitch: fee too high");
        require(rebateBps <= feeBps, "DexFeeSwitch: rebate > fee");
        require(relayerShareBps <= MAX_RELAYER_SHARE, "DexFeeSwitch: relayer share too high");

        feeTiers[tierId] = FeeTier({
            volumeThreshold: volumeThreshold,
            feeBps: feeBps,
            rebateBps: rebateBps,
            relayerShareBps: relayerShareBps
        });

        if (tierId >= numTiers) {
            numTiers = tierId + 1;
        }

        emit FeeTierUpdated(
            tierId,
            volumeThreshold,
            feeBps,
            rebateBps,
            relayerShareBps
        );
    }
}