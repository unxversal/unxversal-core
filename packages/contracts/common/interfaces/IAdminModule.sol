// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAdminModule
 * @author Unxversal Team
 * @notice Interface for administrative modules controlling protocol components.
 * @dev Defines standard functions for pausing, unpausing, and managing ownership,
 *      intended to be implemented by specific admin contracts for each protocol.
 *      The owner of implementations will typically be a multisig or DAO Timelock.
 */
interface IAdminModule {
    /**
     * @notice Emitted when the entire module or a significant part of its controlled protocol is paused.
     * @param account The account that triggered the pause (usually the owner).
     */
    event Paused(address account);

    /**
     * @notice Emitted when the entire module or a significant part of its controlled protocol is unpaused.
     * @param account The account that triggered the unpause (usually the owner).
     */
    event Unpaused(address account);

    // Note: OpenZeppelin's Ownable already emits OwnershipTransferred(address previousOwner, address newOwner)
    // So, we don't need to redefine it here unless we want a more specific event.

    /**
     * @notice Pauses the contract or the functionalities it controls.
     * @dev Implementations should ensure this can only be called by the owner.
     *      The exact scope of "pause" is implementation-specific (e.g., halt new mints,
     *      stop all trading, prevent new borrows).
     */
    function pause() external;

    /**
     * @notice Unpauses the contract or the functionalities it controls.
     * @dev Implementations should ensure this can only be called by the owner.
     */
    function unpause() external;

    /**
     * @notice Returns true if the contract or its main functionalities are paused, false otherwise.
     */
    function paused() external view returns (bool);

    /**
     * @notice Returns the address of the current owner.
     * @dev This is part of the Ownable pattern.
     */
    function owner() external view returns (address);

    /**
     * @notice Transfers ownership of the contract to a new account (`newOwner`).
     * @dev Can only be called by the current owner.
     *      This is part of the Ownable pattern.
     * @param newOwner The address of the new owner.
     */
    function transferOwnership(address newOwner) external;

    /**
     * @notice Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore.
     * @dev Can only be called by the current owner.
     *      WARNING: Renouncing ownership will leave the contract without an owner,
     *      thereby removing any functionality that is only available to the owner.
     *      This is part of the Ownable pattern and should be used with extreme caution,
     *      typically only if the contract is designed to become fully autonomous or
     *      if ownership is being transferred to a burn address or a fully decentralized DAO
     *      that doesn't use this direct ownership pattern.
     */
    function renounceOwnership() external;

    // Potential future additions:
    // - Functions for managing fee recipients if fees are collected by admin modules.
    // - Functions for upgrading target contract addresses if the admin module acts as a proxy admin.
    // - Granular pause functions (e.g., pauseMinting(), pauseBorrowing()) if needed.
}