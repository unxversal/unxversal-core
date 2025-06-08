// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title GuardianPause
 * @notice Emergency pause mechanism controlled by a guardian multisig
 */
contract GuardianPause is AccessControl {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 public constant PAUSE_DURATION = 7 days;

    // Mapping of contract address to pause expiry timestamp
    mapping(address => uint256) public pauseExpiry;

    event ContractPaused(address indexed target, uint256 expiry);
    event ContractUnpaused(address indexed target);
    event GuardianAdded(address indexed account);
    event GuardianRemoved(address indexed account);

    constructor(address[] memory initialGuardians) {
        _setRoleAdmin(GUARDIAN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        
        _grantRole(ADMIN_ROLE, msg.sender);
        
        for (uint256 i = 0; i < initialGuardians.length; i++) {
            _grantRole(GUARDIAN_ROLE, initialGuardians[i]);
            emit GuardianAdded(initialGuardians[i]);
        }
    }

    /**
     * @notice Pause a contract for 7 days
     * @param target Contract to pause
     */
    function pauseContract(address target) external onlyRole(GUARDIAN_ROLE) {
        require(target != address(0), "Cannot pause zero address");
        require(pauseExpiry[target] < block.timestamp, "Contract already paused");

        pauseExpiry[target] = block.timestamp + PAUSE_DURATION;
        emit ContractPaused(target, pauseExpiry[target]);
    }

    /**
     * @notice Unpause a contract before the 7 day period ends
     * @param target Contract to unpause
     */
    function unpauseContract(address target) external onlyRole(GUARDIAN_ROLE) {
        require(target != address(0), "Cannot unpause zero address");
        require(pauseExpiry[target] > block.timestamp, "Contract not paused");

        pauseExpiry[target] = 0;
        emit ContractUnpaused(target);
    }

    /**
     * @notice Add a new guardian (admin only)
     * @param account Address to add as guardian
     */
    function addGuardian(address account) external onlyRole(ADMIN_ROLE) {
        grantRole(GUARDIAN_ROLE, account);
        emit GuardianAdded(account);
    }

    /**
     * @notice Remove a guardian (admin only)
     * @param account Address to remove as guardian
     */
    function removeGuardian(address account) external onlyRole(ADMIN_ROLE) {
        revokeRole(GUARDIAN_ROLE, account);
        emit GuardianRemoved(account);
    }

    /**
     * @notice Check if a contract is paused
     * @param target Contract to check
     * @return True if contract is paused
     */
    function isPaused(address target) external view returns (bool) {
        return pauseExpiry[target] > block.timestamp;
    }

    /**
     * @notice Get remaining pause duration for a contract
     * @param target Contract to check
     * @return Seconds remaining in pause period (0 if not paused)
     */
    function getPauseRemaining(address target) external view returns (uint256) {
        uint256 expiry = pauseExpiry[target];
        if (expiry <= block.timestamp) return 0;
        return expiry - block.timestamp;
    }
}
