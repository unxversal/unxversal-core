// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IVeUNXV.sol";

/**
 * @title GaugeController
 * @notice Controls gauge weights and token emissions for different protocol components
 */
contract GaugeController is Ownable {
    using SafeERC20 for IERC20;

    struct Gauge {
        address addr;        // Gauge address
        uint256 weight;      // Gauge weight
        uint256 typeWeight;  // Type weight
        uint256 gaugeType;   // Gauge type
    }

    // Constants
    uint256 public constant WEEK = 7 days;
    uint256 public constant MULTIPLIER = 10**18;

    // Protocol token
    IERC20 public immutable token;
    IVeUNXV public immutable veToken;

    // Gauge info
    mapping(address => Gauge) public gauges;
    mapping(uint256 => uint256) public typeWeights;    // type -> weight
    mapping(uint256 => uint256) public totalTypeWeight; // type -> sum(gauge.weight)
    uint256 public totalWeight;

    // Time-weighted values
    mapping(address => mapping(uint256 => uint256)) public gaugePointsWeight;  // gauge -> time -> weight
    mapping(uint256 => mapping(uint256 => uint256)) public typePointsWeight;   // type -> time -> weight
    mapping(uint256 => uint256) public timePointsWeight;  // time -> total weight
    mapping(uint256 => uint256) public timePointsSum;     // time -> total weight * time

    // Voting
    mapping(address => mapping(address => uint256)) public voteUserPower;  // user -> gauge -> power
    mapping(address => uint256) public voteUserTotal;     // user -> total voting power used
    mapping(address => uint256) public lastUserVote;      // user -> last vote time

    event NewGauge(address indexed gauge, uint256 gaugeType, uint256 weight);
    event GaugeWeightUpdated(address indexed gauge, uint256 weight);
    event TypeWeightUpdated(uint256 indexed gaugeType, uint256 weight);
    event VoteForGauge(address indexed user, address indexed gauge, uint256 weight);

    constructor(address _token, address _veToken, address _owner) Ownable(_owner) {
        token = IERC20(_token);
        veToken = IVeUNXV(_veToken);
    }

    /**
     * @notice Add a new gauge
     * @param addr Gauge address
     * @param gaugeType Type of gauge
     * @param weight Initial gauge weight
     */
    function addGauge(address addr, uint256 gaugeType, uint256 weight) external onlyOwner {
        require(gauges[addr].addr == address(0), "Gauge already exists");
        require(addr != address(0), "Cannot add zero address");

        gauges[addr] = Gauge({
            addr: addr,
            weight: weight,
            typeWeight: typeWeights[gaugeType],
            gaugeType: gaugeType
        });

        totalTypeWeight[gaugeType] += weight;
        totalWeight += weight * typeWeights[gaugeType] / MULTIPLIER;

        emit NewGauge(addr, gaugeType, weight);
    }

    /**
     * @notice Change type weight
     * @param gaugeType Gauge type
     * @param weight New type weight
     */
    function changeTypeWeight(uint256 gaugeType, uint256 weight) external onlyOwner {
        uint256 oldWeight = typeWeights[gaugeType];
        typeWeights[gaugeType] = weight;

        // Update all gauges of this type
        uint256 typeTotal = totalTypeWeight[gaugeType];
        totalWeight = totalWeight + typeTotal * (weight - oldWeight) / MULTIPLIER;

        emit TypeWeightUpdated(gaugeType, weight);
    }

    /**
     * @notice Vote for a gauge
     * @param gaugeAddr Gauge address
     * @param userWeight Weight of vote
     */
    function voteForGauge(address gaugeAddr, uint256 userWeight) external {
        require(gauges[gaugeAddr].addr != address(0), "Gauge not added");
        require(block.timestamp >= lastUserVote[msg.sender] + WEEK, "Can only vote once per week");

        // Get user's voting power
        uint256 power = veToken.getVotes(msg.sender);
        require(power > 0, "No voting power");
        
        // Check if lock has expired
        IVeUNXV.LockedBalance memory lockData = veToken.locked(msg.sender);
        require(lockData.end > block.timestamp, "Lock expired");

        // Remove old vote
        uint256 oldWeight = voteUserPower[msg.sender][gaugeAddr];
        voteUserTotal[msg.sender] -= oldWeight;

        // Add new vote
        voteUserPower[msg.sender][gaugeAddr] = userWeight;
        voteUserTotal[msg.sender] += userWeight;
        require(voteUserTotal[msg.sender] <= power, "Used too much power");

        // Update gauge weight
        uint256 newGaugeWeight = gauges[gaugeAddr].weight + userWeight - oldWeight;
        gauges[gaugeAddr].weight = newGaugeWeight;

        uint256 gaugeType = gauges[gaugeAddr].gaugeType;
        totalTypeWeight[gaugeType] = totalTypeWeight[gaugeType] + userWeight - oldWeight;
        totalWeight = totalWeight + (userWeight - oldWeight) * typeWeights[gaugeType] / MULTIPLIER;

        lastUserVote[msg.sender] = block.timestamp;
        emit VoteForGauge(msg.sender, gaugeAddr, userWeight);
    }

    /**
     * @notice Get gauge relative weight (normalized to 1e18)
     * @param addr Gauge address
     * @return Relative weight
     */
    function getGaugeRelativeWeight(address addr) external view returns (uint256) {
        Gauge memory gauge = gauges[addr];
        if (gauge.addr == address(0)) return 0;
        
        return gauge.weight * gauge.typeWeight * MULTIPLIER / (totalWeight * MULTIPLIER);
    }

    /**
     * @notice Get gauge type relative weight
     * @param gaugeType Type of gauge
     * @return Relative weight
     */
    function getTypeRelativeWeight(uint256 gaugeType) external view returns (uint256) {
        return totalTypeWeight[gaugeType] * typeWeights[gaugeType] * MULTIPLIER / (totalWeight * MULTIPLIER);
    }
}
