// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILendRiskController
 * @author Unxversal Team
 * @notice Interface for the lending risk controller that manages collateral factors and liquidation parameters
 */
interface ILendRiskController {
    // --- Structs ---
    struct MarketRiskConfig {
        bool isListed;
        bool canBeCollateral;
        uint256 collateralFactorBps;
        uint256 liquidationThresholdBps;
        uint256 liquidationBonusBps;
        address uTokenAddress;
        uint256 oracleAssetId;
        uint8 underlyingDecimals;
    }

    // --- Events ---
    event MarketListed(address indexed underlyingAsset, address indexed uToken, uint256 cfBps, uint256 ltBps);
    event MarketConfigUpdated(address indexed underlyingAsset, uint256 cfBps, uint256 ltBps, uint256 lqBonusBps);
    event OracleAssetIdSet(address indexed underlyingAsset, uint256 oracleAssetId);
    event CorePoolSet(address indexed corePoolAddress);
    event OracleSet(address indexed oracleAddress);
    event SynthFactorySet(address indexed factoryAddress);

    // --- Admin Functions ---
    function setCorePool(address corePoolAddress) external;
    function setOracle(address oracleAddress) external;
    function setSynthFactory(address factoryAddress) external;
    function listMarket(
        address underlyingAsset,
        address uTokenAddress,
        bool canBeCollateral,
        uint256 cfBps,
        uint256 ltBps,
        uint256 lqBonusBps,
        uint256 oracleAssetId
    ) external;
    function setMarketOracleAssetId(address underlyingAsset, uint256 newOracleAssetId) external;

    // --- Risk Assessment Functions ---
    function getAccountLiquidityValues(address user) external view returns (uint256 totalCollateralValueUsd, uint256 totalBorrowValueUsd);
    function getAccountLiquidity(address user) external view returns (int256 liquidityUsd);
    function getHealthFactor(address user) external view returns (uint256 healthFactor);
    function isAccountLiquidatable(address user) external view returns (bool);

    // --- Pre-action Checks ---
    function preBorrowCheck(address user, address assetToBorrow, uint256 amountToBorrow) external view;
    function preWithdrawCheck(address user, address assetCollateral, uint256 amountCollateralToWithdraw) external view;

    // --- View Functions ---
    function marketRiskConfigs(address underlyingAsset) external view returns (MarketRiskConfig memory);
    function getListedAssetsCount() external view returns (uint256);
    function getListedAssetAtIndex(uint256 index) external view returns (address);

    // --- Constants ---
    function BPS_DENOMINATOR() external pure returns (uint256);
    function PRICE_PRECISION() external pure returns (uint256);
    function HEALTH_FACTOR_PRECISION() external pure returns (uint256);
} 