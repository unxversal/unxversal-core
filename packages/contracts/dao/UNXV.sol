// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title UNXV Token
 * @notice Governance token for the unxversal protocol with fixed supply and permit functionality
 */
contract UNXV is ERC20, ERC20Permit, Ownable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether; // 1 billion tokens with 18 decimals

    bool public mintingFinished;

    event MintingFinished();

    constructor() 
        ERC20("unxversal", "UNXV") 
        ERC20Permit("unxversal") 
        Ownable(msg.sender)
    {
        // Initial mint to deployer who will distribute to vesting contracts
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /**
     * @notice Permanently disables minting functionality
     * @dev Can only be called once by owner
     */
    function finishMinting() external onlyOwner {
        require(!mintingFinished, "Minting already finished");
        mintingFinished = true;
        emit MintingFinished();
        renounceOwnership();
    }
}
