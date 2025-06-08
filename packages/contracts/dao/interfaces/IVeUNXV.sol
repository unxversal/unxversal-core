// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVeUNXV
 * @author Unxversal Team
 * @notice Interface for the voting escrow UNXV contract
 */
interface IVeUNXV {
    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }

    // --- Events ---
    event Deposit(address indexed provider, uint256 value, uint256 locktime, uint256 depositType, uint256 ts);
    event Withdraw(address indexed provider, uint256 value, uint256 ts);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    // --- Core Functions ---
    function createLock(uint256 value, uint256 unlockTime) external;
    function increaseAmount(uint256 value) external;
    function increaseUnlockTime(uint256 unlockTime) external;
    function withdraw() external;
    function delegate(address delegatee) external;

    // --- View Functions ---
    function balanceOf(address addr) external view returns (uint256);
    function balanceOfAt(address addr, uint256 blockNumber) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalSupplyAt(uint256 blockNumber) external view returns (uint256);
    function locked(address addr) external view returns (LockedBalance memory);
    function delegates(address addr) external view returns (address);
    function getVotes(address account) external view returns (uint256);
    function getPastVotes(address account, uint256 blockNumber) external view returns (uint256);
    function getPastTotalSupply(uint256 blockNumber) external view returns (uint256);
} 