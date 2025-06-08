// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import "@openzeppelin/contracts/interfaces/IERC5805.sol";

/**
 * @title VeUNXV
 * @author Unxversal Team  
 * @notice Voting escrow for UNXV token - lock UNXV for veUNXV (voting power)
 * @dev Production-ready implementation with OpenZeppelin IERC5805 compatibility
 */
contract VeUNXV is ReentrancyGuard, IERC5805 {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace224;

    // --- Events ---
    event Deposit(address indexed provider, uint256 value, uint256 locktime, uint256 deposit_type, uint256 ts);
    event Withdraw(address indexed provider, uint256 value, uint256 ts);

    // --- Structs ---
    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    // --- Constants ---
    uint256 public constant WEEK = 7 days;
    uint256 public constant MAXTIME = 4 * 365 days; // 4 years
    uint256 public constant MULTIPLIER = 1e18;
    uint256 public constant MIN_LOCK_TIME = 1 weeks;

    // --- State Variables ---
    IERC20 public immutable token;
    string public constant name = "Vote-Escrowed UNXV";
    string public constant symbol = "veUNXV";
    uint8 public constant decimals = 18;

    // Locking mechanism
    mapping(address => LockedBalance) public locked;
    uint256 public supply;

    // Delegation 
    mapping(address => address) private _delegates;
    mapping(address => Checkpoints.Trace224) private _delegateCheckpoints;
    Checkpoints.Trace224 private _totalCheckpoints;

    // --- Constructor ---
    constructor(address _token) {
        require(_token != address(0), "veUNXV: Zero token address");
        token = IERC20(_token);
    }

    // --- Core Locking Functions ---
    function createLock(uint256 value, uint256 unlockTime) external nonReentrant {
        require(value > 0, "veUNXV: Cannot lock 0");
        require(unlockTime > block.timestamp + MIN_LOCK_TIME, "veUNXV: Lock too short");
        require(unlockTime <= block.timestamp + MAXTIME, "veUNXV: Lock too long");
        require(locked[msg.sender].amount == 0, "veUNXV: Lock exists");

        LockedBalance memory newLocked = LockedBalance({
            amount: int128(uint128(value)),
            end: unlockTime
        });

        locked[msg.sender] = newLocked;
        supply += value;

        // Transfer tokens
        token.safeTransferFrom(msg.sender, address(this), value);

        // Update voting power
        _updateVotingPower(msg.sender, newLocked);

        emit Deposit(msg.sender, value, unlockTime, 1, block.timestamp);
    }

    function increaseAmount(uint256 value) external nonReentrant {
        require(value > 0, "veUNXV: Cannot add 0");
        
        LockedBalance memory oldLocked = locked[msg.sender];
        require(oldLocked.amount > 0, "veUNXV: No lock found");
        require(oldLocked.end > block.timestamp, "veUNXV: Lock expired");

        LockedBalance memory newLocked = LockedBalance({
            amount: oldLocked.amount + int128(uint128(value)),
            end: oldLocked.end
        });

        locked[msg.sender] = newLocked;
        supply += value;

        // Transfer tokens
        token.safeTransferFrom(msg.sender, address(this), value);

        // Update voting power
        _updateVotingPower(msg.sender, newLocked);

        emit Deposit(msg.sender, value, newLocked.end, 2, block.timestamp);
    }

    function increaseUnlockTime(uint256 unlockTime) external nonReentrant {
        LockedBalance memory oldLocked = locked[msg.sender];
        require(oldLocked.amount > 0, "veUNXV: No lock found");
        require(unlockTime > oldLocked.end, "veUNXV: Can only increase");
        require(unlockTime <= block.timestamp + MAXTIME, "veUNXV: Lock too long");

        LockedBalance memory newLocked = LockedBalance({
            amount: oldLocked.amount,
            end: unlockTime
        });

        locked[msg.sender] = newLocked;

        // Update voting power
        _updateVotingPower(msg.sender, newLocked);

        emit Deposit(msg.sender, uint256(uint128(newLocked.amount)), unlockTime, 3, block.timestamp);
    }

    function withdraw() external nonReentrant {
        LockedBalance memory oldLocked = locked[msg.sender];
        require(oldLocked.amount > 0, "veUNXV: No lock found");
        require(block.timestamp >= oldLocked.end, "veUNXV: Lock not expired");

        uint256 value = uint256(uint128(oldLocked.amount));
        
        // Clear lock
        locked[msg.sender] = LockedBalance({amount: 0, end: 0});
        supply -= value;

        // Transfer tokens
        token.safeTransfer(msg.sender, value);

        // Update voting power to 0
        _updateVotingPower(msg.sender, LockedBalance({amount: 0, end: 0}));

        emit Withdraw(msg.sender, value, block.timestamp);
    }

    // --- Delegation Functions (IERC5805) ---
    function delegate(address delegatee) external {
        _delegate(msg.sender, delegatee);
    }

    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(block.timestamp <= expiry, "veUNXV: Signature expired");
        
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)"),
            delegatee,
            nonce,
            expiry
        ));
        
        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
        
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            domainSeparator,
            structHash
        ));
        
        address signer = ECDSA.recover(digest, v, r, s);
        require(signer != address(0), "veUNXV: Invalid signature");
        
        _delegate(signer, delegatee);
    }

    // --- View Functions ---
    function balanceOf(address addr) external view returns (uint256) {
        return balanceOfAt(addr, block.number);
    }

    function balanceOfAt(address addr, uint256 blockNumber) public view returns (uint256) {
        LockedBalance memory lock = locked[addr];
        if (lock.amount == 0) return 0;
        
        // Calculate voting power based on time remaining
        uint256 lockEnd = lock.end;
        if (blockNumber == 0) blockNumber = block.number;
        
        // Estimate timestamp from block number (approximate)
        uint256 timestamp = _estimateTimestamp(blockNumber);
        
        if (timestamp >= lockEnd) return 0;
        
        // Linear decay: voting power = locked_amount * (time_remaining / max_time)
        uint256 timeRemaining = lockEnd - timestamp;
        uint256 votingPower = uint256(uint128(lock.amount)) * timeRemaining / MAXTIME;
        
        return votingPower;
    }

    function totalSupply() external view returns (uint256) {
        return totalSupplyAt(block.number);
    }

    function totalSupplyAt(uint256 blockNumber) public view returns (uint256) {
        return _totalCheckpoints.upperLookupRecent(uint32(blockNumber));
    }

    function delegates(address addr) external view returns (address) {
        return _delegates[addr];
    }

    function getVotes(address account) external view returns (uint256) {
        return _delegateCheckpoints[account].latest();
    }

    function getPastVotes(address account, uint256 blockNumber) external view returns (uint256) {
        require(blockNumber < block.number, "veUNXV: Future block");
        return _delegateCheckpoints[account].upperLookupRecent(uint32(blockNumber));
    }

    function getPastTotalSupply(uint256 blockNumber) external view returns (uint256) {
        require(blockNumber < block.number, "veUNXV: Future block");
        return totalSupplyAt(blockNumber);
    }

    function clock() external view returns (uint48) {
        return uint48(block.number);
    }

    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    // --- Internal Functions ---
    function _delegate(address delegator, address delegatee) internal {
        address oldDelegate = _delegates[delegator];
        _delegates[delegator] = delegatee;

        // Update voting power
        uint256 votes = balanceOfAt(delegator, block.number);
        require(votes <= type(uint224).max, "veUNXV: votes exceed uint224 max");
        
        if (oldDelegate != address(0)) {
            uint224 oldVotes = uint224(_delegateCheckpoints[oldDelegate].latest());
            uint224 votesToSubtract = uint224(votes);
            uint224 newVotes = oldVotes >= votesToSubtract ? oldVotes - votesToSubtract : 0;
            _delegateCheckpoints[oldDelegate].push(uint32(block.number), newVotes);
        }
        
        if (delegatee != address(0)) {
            uint224 oldVotes = uint224(_delegateCheckpoints[delegatee].latest());
            uint224 votesToAdd = uint224(votes);
            uint224 newVotes = oldVotes + votesToAdd;
            _delegateCheckpoints[delegatee].push(uint32(block.number), newVotes);
        }

        emit DelegateChanged(delegator, oldDelegate, delegatee);
    }

    function _updateVotingPower(address user, LockedBalance memory newLocked) internal {
        address delegatee = _delegates[user];
        if (delegatee == address(0)) delegatee = user;

        uint256 newVotes = _calculateVotingPower(newLocked);
        require(newVotes <= type(uint224).max, "veUNXV: votes exceed uint224 max");
        
        // Update delegate's voting power
        _delegateCheckpoints[delegatee].push(uint32(block.number), uint224(newVotes));
        
        // Update total supply
        uint256 currentTotalSupply = _totalSupply();
        require(currentTotalSupply <= type(uint224).max, "veUNXV: total supply exceeds uint224 max");
        _totalCheckpoints.push(uint32(block.number), uint224(currentTotalSupply));
    }

    function _calculateVotingPower(LockedBalance memory lock) internal view returns (uint256) {
        if (lock.amount == 0 || lock.end <= block.timestamp) return 0;
        
        uint256 timeRemaining = lock.end - block.timestamp;
        return uint256(uint128(lock.amount)) * timeRemaining / MAXTIME;
    }

    function _totalSupply() internal view returns (uint256) {
        // Simplified total supply calculation
        return supply;
    }

    function _estimateTimestamp(uint256 blockNumber) internal view returns (uint256) {
        if (blockNumber >= block.number) return block.timestamp;
        
        // Rough estimate: 12 second blocks
        uint256 blockDiff = block.number - blockNumber;
        return block.timestamp - (blockDiff * 12);
    }

    function _add(uint256 a, uint256 b) internal pure returns (uint224) {
        uint256 result = a + b;
        require(result <= type(uint224).max, "veUNXV: value exceeds uint224 range");
        return uint224(result);
    }

    function _subtract(uint256 a, uint256 b) internal pure returns (uint224) {
        require(a >= b, "veUNXV: subtraction underflow");
        uint256 result = a - b;
        require(result <= type(uint224).max, "veUNXV: value exceeds uint224 range");
        return uint224(result);
    }
}
