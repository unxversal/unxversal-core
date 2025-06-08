// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IOptionNFT
 * @author Unxversal Team
 * @notice Interface for the OptionNFT contract - NFT-based options trading
 */
interface IOptionNFT {
    // --- Enums ---
    enum OptionType { Call, Put }
    enum OptionState { Active, Exercised, Expired }

    // --- Structs ---
    struct OptionDetails {
        address underlying;
        address quote;
        uint256 strikePrice;
        uint64 expiry;
        OptionType optionType;
        address writer;
        uint256 premium;
        OptionState state;
        uint256 collateralLocked;
    }

    // --- Events ---
    event OptionWritten(
        uint256 indexed tokenId,
        address indexed writer,
        address indexed underlying,
        address quote,
        uint256 strikePrice,
        uint64 expiry,
        OptionType optionType,
        uint256 premium
    );

    event OptionExercised(
        uint256 indexed tokenId,
        address indexed holder,
        uint256 payout,
        uint256 profit
    );

    event OptionExpired(
        uint256 indexed tokenId,
        address indexed writer,
        uint256 collateralReleased
    );

    // --- User Functions ---
    function writeOption(
        address underlying,
        address quote,
        uint256 strikePrice,
        uint64 expiry,
        OptionType optionType,
        uint256 premium
    ) external returns (uint256 tokenId);

    function exerciseOption(uint256 tokenId) external returns (uint256 payout);
    
    function claimExpiredCollateral(uint256 tokenId) external returns (uint256 collateral);

    // --- View Functions ---
    function getOptionDetails(uint256 tokenId) external view returns (OptionDetails memory);
    
    function isInTheMoney(uint256 tokenId) external view returns (bool);
    
    function getExerciseValue(uint256 tokenId) external view returns (uint256);
    
    function getRequiredCollateral(
        address underlying,
        address quote,
        uint256 strikePrice,
        OptionType optionType
    ) external view returns (uint256);
} 