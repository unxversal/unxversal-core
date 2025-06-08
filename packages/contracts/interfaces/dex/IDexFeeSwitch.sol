// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDexFeeSwitch {
    /// @notice Fee tier information
    struct FeeTier {
        uint256 volumeThreshold;  // Volume threshold in USDC for this tier
        uint24 feeBps;           // Base fee in bps for this tier
        uint24 rebateBps;        // Rebate in bps for this tier
        uint24 relayerShareBps;  // Share of fee given to relayer
    }

    /// @notice Emitted when a fee tier is updated
    event FeeTierUpdated(
        uint256 indexed tierId,
        uint256 volumeThreshold,
        uint24 feeBps,
        uint24 rebateBps,
        uint24 relayerShareBps
    );

    /// @notice Emitted when fees are deposited
    event FeeDeposited(
        address indexed token,
        address indexed payer,
        address indexed recipient,
        uint256 amount,
        uint256 usdcEquivalent
    );

    /// @notice Emitted when UNXV is staked for fee discounts
    event UnxvStaked(
        address indexed user,
        uint256 amount,
        uint256 newTotalStaked
    );

    /// @notice Emitted when UNXV is unstaked
    event UnxvUnstaked(
        address indexed user,
        uint256 amount,
        uint256 newTotalStaked
    );

    /// @notice Gets the fee tier for a given user based on their volume and UNXV stake
    function getUserFeeTier(address user) external view returns (FeeTier memory);

    /// @notice Gets the current trading volume for a user
    function getUserVolume(address user) external view returns (uint256);

    /// @notice Gets the amount of UNXV staked by a user
    function getUnxvStaked(address user) external view returns (uint256);

    /// @notice Deposits trading fees, converting to USDC if necessary
    /// @param token The token the fee is paid in
    /// @param payer The address paying the fee
    /// @param amount The amount of the fee
    /// @param relayer Optional relayer address to receive share of fee
    function depositFee(
        address token,
        address payer,
        uint256 amount,
        address relayer
    ) external returns (uint256 usdcAmount);

    /// @notice Stakes UNXV for fee discounts
    function stakeUnxv(uint256 amount) external;

    /// @notice Unstakes UNXV
    function unstakeUnxv(uint256 amount) external;

    /// @notice Updates fee tiers (only owner)
    function setFeeTier(
        uint256 tierId,
        uint256 volumeThreshold,
        uint24 feeBps,
        uint24 rebateBps,
        uint24 relayerShareBps
    ) external;

    /// @notice Gets the USDC equivalent value of a token amount
    function getUSDCValue(
        address token,
        uint256 amount
    ) external view returns (uint256);
} 