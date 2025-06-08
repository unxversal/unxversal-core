// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IGaugeController
 * @author Unxversal Team
 * @notice Interface for the GaugeController that manages emissions distribution
 */
interface IGaugeController {
    struct Gauge {
        address addr;
        uint256 weight;
        uint256 gaugeType;
        bool isActive;
    }

    // --- Events ---
    event GaugeAdded(address indexed gauge, uint256 indexed gaugeType, uint256 weight);
    event GaugeKilled(address indexed gauge);
    event GaugeUnkilled(address indexed gauge);
    event VoteForGauge(address indexed user, address indexed gauge, uint256 weight);
    event TypeWeightChanged(uint256 indexed gaugeType, uint256 weight);

    // --- Core Functions ---
    function addGauge(address gauge, uint256 gaugeType, uint256 weight) external;
    function killGauge(address gauge) external;
    function unkillGauge(address gauge) external;
    function voteForGaugeWeights(address gauge, uint256 weight) external;
    function setTypeWeight(uint256 gaugeType, uint256 weight) external;

    // --- View Functions ---
    function getGaugeWeight(address gauge) external view returns (uint256);
    function getTypeWeight(uint256 gaugeType) external view returns (uint256);
    function getTotalWeight() external view returns (uint256);
    function getGaugeRelativeWeight(address gauge) external view returns (uint256);
    function getVoteUserPower(address user, address gauge) external view returns (uint256);
    function getGaugeInfo(address gauge) external view returns (Gauge memory);
    function isValidGauge(address gauge) external view returns (bool);
    function getUserVotingPower(address user) external view returns (uint256);
} 