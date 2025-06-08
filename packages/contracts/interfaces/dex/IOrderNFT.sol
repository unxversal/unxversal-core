// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../dex/structs/SOrder.sol";

interface IOrderNFT {
    /// @notice Parameters for filling orders with safety checks
    struct FillParams {
        uint256 minAmountOut;     // Minimum amount of buy token to receive
        uint256 maxGasPrice;      // Maximum gas price for execution
        uint256 deadline;         // Expiration timestamp for this fill
        uint256 minFillAmount;    // Minimum amount to fill per order
        address relayer;          // Optional relayer to receive fee share
    }

    /// @notice Parameters for TWAP orders
    struct TWAPOrder {
        uint256 totalAmount;      // Total amount to sell
        uint256 amountPerPeriod;  // Amount to sell per period
        uint256 period;           // Time between executions (e.g. 1 hour)
        uint256 lastExecutionTime;// Last time the TWAP was executed
        uint256 executedAmount;   // Total amount executed so far
        uint256 minPrice;         // Minimum price to execute at
    }

    /// @notice Emitted when a new limit order is created
    event OrderCreated(
        uint256 indexed tokenId,
        address indexed maker,
        address indexed sellToken,
        address buyToken,
        uint256 price,
        uint256 amountInitial,
        uint32  expiry,
        uint8   sellDecimals,
        uint24  feeBps
    );

    /// @notice Emitted when an order is filled
    event OrderFilled(
        uint256 indexed tokenId,
        address indexed taker,
        address indexed maker,
        uint256 amountSold,
        uint256 amountBoughtNet,
        uint256 feeAmount,
        uint256 amountRemainingInOrder
    );

    /// @notice Emitted when an order is cancelled
    event OrderCancelled(
        uint256 indexed tokenId,
        address indexed maker,
        uint256 amountReturned
    );

    /// @notice Emitted when a TWAP order is created
    event TWAPOrderCreated(
        uint256 indexed tokenId,
        address indexed maker,
        uint256 totalAmount,
        uint256 amountPerPeriod,
        uint256 period,
        uint256 minPrice
    );

    /// @notice Emitted when a TWAP order is executed
    event TWAPOrderExecuted(
        uint256 indexed tokenId,
        uint256 executedAmount,
        uint256 receivedAmount,
        uint256 remainingAmount
    );

    /// @notice Creates a new limit order
    function createOrder(
        address sellToken,
        address buyToken,
        uint256 price,
        uint256 amount,
        uint32 expiry,
        uint8 sellDecimals,
        uint24 feeBps
    ) external returns (uint256 tokenId);

    /// @notice Creates a new TWAP order
    function createTWAPOrder(
        address sellToken,
        address buyToken,
        uint256 totalAmount,
        uint256 amountPerPeriod,
        uint256 period,
        uint256 minPrice
    ) external returns (uint256 tokenId);

    /// @notice Fills multiple orders with safety checks
    function fillOrders(
        uint256[] calldata tokenIds,
        uint256[] calldata fillAmounts,
        FillParams calldata params
    ) external returns (uint256[] memory amountsBought);

    /// @notice Executes a TWAP order
    function executeTWAPOrder(uint256 tokenId) external returns (uint256 executedAmount);

    /// @notice Cancels multiple orders
    function cancelOrders(uint256[] calldata tokenIds) external;

    /// @notice Gets the current state of an order
    function getOrder(uint256 tokenId) external view returns (OrderLayout memory);

    /// @notice Gets the current state of a TWAP order
    function getTWAPOrder(uint256 tokenId) external view returns (TWAPOrder memory);
} 