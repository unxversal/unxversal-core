// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title ISynthToken
 * @author Unxversal Team
 * @notice Interface for synthetic asset (sAsset) tokens.
 * @dev Extends IERC20 and IERC20Metadata with a controlled minting function. 
 *      Burning is handled via ERC20Burnable's `burnFrom` by an authorized controller.
 */
interface ISynthToken is IERC20, IERC20Metadata {
    /**
     * @notice Mints new synth tokens to an account.
     * @dev Typically only callable by a trusted minter (e.g., USDCVault).
     * @param to The address to mint tokens to.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint256 amount) external;

    /**
     * @notice Burns tokens from an account, reducing the total supply.
     * @dev Only callable by accounts with BURNER_ROLE.
     * @param account The account whose tokens will be burnt.
     * @param amount The amount of tokens to burn.
     */
    function burnFrom(address account, uint256 amount) external;

    // ERC20Burnable's `burnFrom(address account, uint256 amount)` will be used by the controller.
    // No separate `burn(address from, ...)` needed in this interface if controller uses `burnFrom`.
}