// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/ISynthToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol"; // Provides burnFrom
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

/**
 * @title SynthToken
 * @author Unxversal Team
 * @notice Base ERC20 implementation for synthetic assets (sAssets).
 * @dev Minting is restricted via MINTER_ROLE. Burning (via burnFrom) is restricted via BURNER_ROLE.
 *      These roles are typically granted to the USDCVault contract.
 *      The deployer receives DEFAULT_ADMIN_ROLE for initial role setup.
 */
contract SynthToken is ERC20, ERC20Burnable, AccessControlEnumerable, ISynthToken {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    // Optional: Store assetId for easier identification off-chain if needed by other contracts.
    // uint256 public immutable assetIdForOracle;

    /**
     * @param name_ Name of the synthetic asset (e.g., "Unxversal Bitcoin").
     * @param symbol_ Symbol of the synthetic asset (e.g., "sBTC").
     * @param initialAdmin The address to receive DEFAULT_ADMIN_ROLE for this token.
     *                     Typically the SynthFactory or a central DAO Timelock.
     */
    constructor(
        string memory name_,
        string memory symbol_,
        address initialAdmin // Address that can grant MINTER/BURNER roles
        // uint256 _assetIdForOracle // Optional
    ) ERC20(name_, symbol_) {
        require(initialAdmin != address(0), "SynthToken: Zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        // MINTER_ROLE and BURNER_ROLE will be granted by the admin (e.g., SynthFactory)
        // to the USDCVault contract after deployment of this SynthToken.
        // assetIdForOracle = _assetIdForOracle; // Optional
    }

    /**
     * @inheritdoc ISynthToken
     * @dev Mints `amount` of tokens to `to`. Only callable by an account with MINTER_ROLE.
     */
    function mint(address to, uint256 amount) public virtual override {
        require(hasRole(MINTER_ROLE, _msgSender()), "SynthToken: Caller is not a minter");
        _mint(to, amount);
    }

    /**
     * @notice Destroys `amount` tokens from `account`, reducing the total supply.
     * @dev Overrides ERC20Burnable.burnFrom to restrict access to BURNER_ROLE.
     *      The caller (with BURNER_ROLE, e.g., USDCVault) must have been approved by `account`
     *      to spend at least `amount` of tokens.
     * @param account The account whose tokens will be burnt.
     * @param amount The amount of tokens to burn.
     */
    function burnFrom(address account, uint256 amount) public virtual override(ERC20Burnable, ISynthToken) {
        require(hasRole(BURNER_ROLE, _msgSender()), "SynthToken: Caller is not a burner");
        // The allowance check is handled by super.burnFrom() in ERC20Burnable
        super.burnFrom(account, amount);
    }

    // --- AccessControlEnumerable Overrides for OZ v5 ---
    // (supportsInterface from AccessControlEnumerable will cover roles)
    function supportsInterface(bytes4 interfaceId)
        public view virtual override(AccessControlEnumerable) returns (bool)
    {
        return interfaceId == type(ISynthToken).interfaceId ||
               super.supportsInterface(interfaceId);
    }
}