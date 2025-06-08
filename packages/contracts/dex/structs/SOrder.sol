// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// @dev Note: This struct defines the logical data of an order.
// The OrderNFT contract will manage how these fields are stored per tokenId,
// aiming for gas efficiency (e.g., packing some fields, storing others directly).
struct OrderLayout {
    address maker;
    uint32 expiry;
    uint24 feeBps; // Fee for this specific order, can be set by maker or a default
    uint8 sellDecimals; // To help interpret the price field consistently
    uint256 amountRemaining;
    address sellToken;
    address buyToken;
    uint256 price; // Price of 1 unit of sellToken in terms of buyToken, scaled by 1e18
}