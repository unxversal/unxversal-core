// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockOracle
 * @dev Simple oracle for testing
 */
contract MockOracle {
    mapping(uint256 => uint256) public prices;

    function setPrice(uint256 assetId, uint256 price) external {
        prices[assetId] = price;
    }

    function getPrice(uint256 assetId) external view returns (uint256) {
        return prices[assetId];
    }
} 