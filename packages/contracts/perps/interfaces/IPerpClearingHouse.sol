// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPerpClearingHouse  
 * @author Unxversal Team
 * @notice Interface for the PerpClearingHouse contract - central perpetual futures hub
 */
interface IPerpClearingHouse {
    // --- Events are defined in the implementation ---

    // --- User Functions ---
    function depositMargin(uint256 amountUsdc) external;
    function withdrawMargin(uint256 amountUsdc) external;
    
    struct MatchedOrderFillData {
        bytes32 marketId;
        address maker;
        int256 sizeNotionalUsd;
        uint256 price1e18;
    }
    
    function fillMatchedOrder(MatchedOrderFillData calldata fill) external;
    function settleMarketFunding(bytes32 marketId) external;
    
    // --- Liquidation Hook ---
    function processLiquidation(
        address trader,
        bytes32 marketId,
        int256 sizeToCloseNotionalUsd,
        uint256 closePrice1e18,
        uint256 totalLiquidationFeeUsdc
    ) external returns (int256 realizedPnlOnCloseUsdc);

    // --- View Functions ---
    function getTraderCollateralBalance(address trader) external view returns (uint256 usdcBalance);
    
    function getAccountSummary(address trader) external view returns (
        uint256 usdcCollateral,
        int256 totalUnrealizedPnlUsdc,
        uint256 totalMarginBalanceUsdc,
        uint256 totalMaintenanceMarginReqUsdc,
        uint256 totalInitialMarginReqUsdc,
        bool isCurrentlyLiquidatable
    );
    
    function getTraderPosition(address trader, bytes32 marketId) external view returns (
        int256 sizeUsdc,
        uint256 entryPrice,
        int256 unrealizedPnl,
        uint256 marginRequired
    );
    
    function getListedMarketIds() external view returns (bytes32[] memory);
    function isMarketActuallyListed(bytes32 marketId) external view returns (bool);
} 