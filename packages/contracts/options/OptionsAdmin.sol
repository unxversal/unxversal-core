// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../common/access/ProtocolAdminAccess.sol"; // Inherits Ownable
import "./OptionNFT.sol";
import "./CollateralVault.sol";
import "./OptionFeeSwitch.sol";
import "../common/interfaces/IOracleRelayer.sol";

/**
 * @title OptionsAdmin
 * @author Unxversal Team
 * @notice Administrative module for the Unxversal Options protocol.
 * @dev Manages parameters and target contract addresses for OptionNFT, CollateralVault,
 *      and OptionsFeeSwitch. Owned by a multisig or DAO Timelock.
 *      This contract will typically be the owner of the core options protocol contracts.
 */
contract OptionsAdmin is ProtocolAdminAccess {
    OptionNFT public optionNFT;
    CollateralVault public collateralVault;
    OptionFeeSwitch public optionsFeeSwitch;
    IOracleRelayer public oracleRelayer; // Used by OptionNFT for exercise prices

    // Parameters that might be global to the options protocol
    uint256 public defaultMaxOptionFeeBps; // e.g., 100 BPS = 1% on premium/exercise

    event OptionNFTSet(address indexed nftAddress);
    event CollateralVaultSet(address indexed vaultAddress);
    event OptionsFeeSwitchSet(address indexed feeSwitchAddress);
    event OracleRelayerSet(address indexed oracleAddress);
    event DefaultMaxOptionFeeBpsSet(uint256 newMaxFeeBps);

    constructor(
        address _initialOwner,
        address _optionNFTAddress,
        address _collateralVaultAddress,
        address _optionsFeeSwitchAddress,
        address _oracleRelayerAddress
    ) ProtocolAdminAccess(_initialOwner) {
        setOptionNFT(_optionNFTAddress);
        setCollateralVault(_collateralVaultAddress);
        setOptionsFeeSwitch(_optionsFeeSwitchAddress);
        setOracleRelayer(_oracleRelayerAddress);
    }

    // --- Target Contract Setters ---
    function setOptionNFT(address _newNFTAddress) public onlyOwner {
        require(_newNFTAddress != address(0), "OptionsAdmin: Zero OptionNFT");
        optionNFT = OptionNFT(_newNFTAddress);
        emit OptionNFTSet(_newNFTAddress);
    }

    function setCollateralVault(address _newVaultAddress) public onlyOwner {
        require(_newVaultAddress != address(0), "OptionsAdmin: Zero CollateralVault");
        collateralVault = CollateralVault(_newVaultAddress);
        emit CollateralVaultSet(_newVaultAddress);
    }

    function setOptionsFeeSwitch(address _newFeeSwitchAddress) public onlyOwner {
        require(_newFeeSwitchAddress != address(0), "OptionsAdmin: Zero OptionsFeeSwitch");
        optionsFeeSwitch = OptionFeeSwitch(_newFeeSwitchAddress);
        emit OptionsFeeSwitchSet(_newFeeSwitchAddress);
    }

    function setOracleRelayer(address _newOracleAddress) public onlyOwner {
        require(_newOracleAddress != address(0), "OptionsAdmin: Zero OracleRelayer");
        oracleRelayer = IOracleRelayer(_newOracleAddress);
        // Also set it on OptionNFT if it needs direct access (likely does for exercise)
        if (address(optionNFT) != address(0)) {
            // OptionNFT would need a `setOracle(address)` function callable by its owner (this admin contract)
            // optionNFT.setOracle(_newOracleAddress);
        }
        emit OracleRelayerSet(_newOracleAddress);
    }

    // --- Global Option Parameters ---
    function setDefaultMaxOptionFeeBps(uint256 _newMaxFeeBps) external onlyOwner {
        require(_newMaxFeeBps <= 1000, "OptionsAdmin: Fee too high (max 10%)"); // Example cap
        defaultMaxOptionFeeBps = _newMaxFeeBps;
        emit DefaultMaxOptionFeeBpsSet(_newMaxFeeBps);
    }

    // --- Whitelisting Assets (Optional, if not fully permissionless) ---
    // mapping(address => bool) public isUnderlyingSupported;
    // mapping(address => bool) public isQuoteSupported;
    // event AssetSupportChanged(address indexed asset, bool isSupported, bool isUnderlying);
    // function setAssetSupport(address asset, bool supported, bool isUnderlyingType) external onlyOwner { ... }

    // --- Protocol Pause ---
    // Assumes OptionNFT and CollateralVault implement Pausable and are owned by this admin.
    function pauseOptionsProtocol() external view onlyOwner {
        if (address(optionNFT) != address(0) && !optionNFT.paused()) {
            // optionNFT.pause(); // OptionNFT needs pause()
        }
        if (address(collateralVault) != address(0) && !collateralVault.paused()) {
            // collateralVault.pause(); // CollateralVault needs pause()
        }
    }

    function unpauseOptionsProtocol() external view onlyOwner {
        if (address(optionNFT) != address(0) && optionNFT.paused()) {
            // optionNFT.unpause();
        }
        if (address(collateralVault) != address(0) && collateralVault.paused()) {
            // collateralVault.unpause();
        }
    }

    // --- Ownership Transfers of Core Options Contracts ---
    function transferOptionNFTOwnership(address newOwner) external onlyOwner {
        require(address(optionNFT) != address(0), "OptionsAdmin: OptionNFT not set");
        optionNFT.transferOwnership(newOwner);
    }
    // ... similar for CollateralVault, OptionsFeeSwitch ...
}