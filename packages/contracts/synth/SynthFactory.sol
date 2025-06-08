// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol"; // For factory ownership
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./SynthToken.sol"; // The actual SynthToken implementation
import "../common/interfaces/IOracleRelayer.sol"; // For storing and validating oracle interface

/**
 * @title SynthFactory
 * @author Unxversal Team
 * @notice Factory for deploying and managing synthetic asset (sAsset) tokens.
 * @dev Deploys full instances of SynthToken (not clones, for constructor arg simplicity in V1).
 *      Manages oracle asset IDs and custom CRs for each deployed synth.
 *      Grants MINTER_ROLE and BURNER_ROLE of newly created SynthTokens to a specified controller (USDCVault).
 *      The DEFAULT_ADMIN_ROLE of newly created SynthTokens is granted to this factory,
 *      allowing it to manage roles further if needed (e.g., transfer admin to DAO).
 */
contract SynthFactory is Ownable, Pausable {
    IOracleRelayer public oracle; // Shared oracle relayer instance (OracleRelayerDst)

    struct SynthConfig {
        address tokenAddress;   // Address of the deployed sAsset ERC20
        uint256 assetId;        // ID used to fetch price from the oracle
        uint256 customMinCRbps; // Custom min CR for this synth in BPS (0 for vault default)
        bool isRegistered;
    }

    mapping(address => SynthConfig) public synthConfigsByAddress; // sAsset address => config
    mapping(uint256 => address) public synthAddressByAssetId;   // Oracle assetId => sAsset address
    address[] public deployedSynthAddresses; // Array of all deployed sAsset contract addresses

    event SynthDeployedAndConfigured(
        address indexed synthAddress,
        string name,
        string symbol,
        uint256 indexed assetId,
        uint256 customMinCRbps,
        address indexed controllerWithRoles // Typically the USDCVault
    );
    event SynthCustomMinCRSet(address indexed synthAddress, uint256 newCustomMinCRbps);
    event OracleSet(address indexed newOracleAddress);
    event SynthAdminRoleTransferred(address indexed synthAddress, address indexed newAdmin);


    /**
     * @param _initialOwner The initial owner (e.g., SynthAdmin or deployer).
     * @param _oracleAddress Address of the IOracleRelayer contract (OracleRelayerDst).
     */
    constructor(address _initialOwner, address _oracleAddress) Ownable(_initialOwner) {
        require(_oracleAddress != address(0), "SF: Zero oracle address");
        oracle = IOracleRelayer(_oracleAddress);
        emit OracleSet(_oracleAddress);
    }

    /**
     * @notice Deploys and configures a new synthetic asset (sAsset) token.
     * @dev Only callable by the contract owner (e.g., SynthAdmin).
     *      The DEFAULT_ADMIN_ROLE of the new SynthToken is this factory.
     *      MINTER_ROLE and BURNER_ROLE are granted to `controllerAddress`.
     * @param name Name for the new synth (e.g., "Unxversal Bitcoin").
     * @param symbol Symbol for the new synth (e.g., "sBTC").
     * @param assetId The oracle asset ID for the underlying. Must be unique.
     * @param customMinCRbps Custom minimum CR for this synth in BPS (e.g., 15000 for 150%). 0 to use vault default.
     * @param controllerAddress The address (typically USDCVault) to receive mint/burn roles for the new synth.
     * @return synthAddress The address of the newly deployed sAsset token.
     */
    function deploySynth(
        string calldata name,
        string calldata symbol,
        uint256 assetId,
        uint256 customMinCRbps,
        address controllerAddress
    ) external onlyOwner whenNotPaused returns (address synthAddress) {
        require(assetId != 0, "SF: Zero assetId");
        require(synthAddressByAssetId[assetId] == address(0), "SF: AssetId already registered");
        require(controllerAddress != address(0), "SF: Zero controller address");
        if (customMinCRbps > 0) { // 0 means use vault default
            require(customMinCRbps >= 10000, "SF: Custom CR must be >= 100%"); // 10000 BPS = 100%
        }

        // Deploy new SynthToken, factory becomes its initial admin
        SynthToken newSynth = new SynthToken(name, symbol, address(this));
        synthAddress = address(newSynth);

        // Grant Minter and Burner roles to the controller (USDCVault)
        newSynth.grantRole(newSynth.MINTER_ROLE(), controllerAddress);
        newSynth.grantRole(newSynth.BURNER_ROLE(), controllerAddress);

        // Store configuration
        synthConfigsByAddress[synthAddress] = SynthConfig({
            tokenAddress: synthAddress,
            assetId: assetId,
            customMinCRbps: customMinCRbps,
            isRegistered: true
        });
        synthAddressByAssetId[assetId] = synthAddress;
        deployedSynthAddresses.push(synthAddress);

        emit SynthDeployedAndConfigured(
            synthAddress, name, symbol, assetId, customMinCRbps, controllerAddress
        );
        return synthAddress;
    }

    /**
     * @notice Updates the custom minimum CR for an existing synth.
     * @param synthAddress The address of the sAsset token.
     * @param newCustomMinCRbps The new custom CR in BPS. 0 to use vault default.
     */
    function setSynthCustomMinCR(address synthAddress, uint256 newCustomMinCRbps) external onlyOwner {
        SynthConfig storage config = synthConfigsByAddress[synthAddress];
        require(config.isRegistered, "SF: Synth not registered");
        if (newCustomMinCRbps > 0) {
            require(newCustomMinCRbps >= 10000, "SF: Custom CR must be >= 100%");
        }
        config.customMinCRbps = newCustomMinCRbps;
        emit SynthCustomMinCRSet(synthAddress, newCustomMinCRbps);
    }

    /**
     * @notice Updates the oracle address used by this factory (and potentially by associated contracts).
     * @param _newOracleAddress The address of the IOracleRelayer implementation.
     */
    function setOracle(address _newOracleAddress) external onlyOwner {
        require(_newOracleAddress != address(0), "SF: Zero oracle address");
        oracle = IOracleRelayer(_newOracleAddress);
        emit OracleSet(_newOracleAddress);
    }

    /**
     * @notice Transfers the DEFAULT_ADMIN_ROLE of a deployed SynthToken to a new admin.
     * @dev Useful for transferring admin rights from the factory to a DAO or multisig.
     *      Only callable by the owner of this factory.
     * @param synthAddress The address of the sAsset token.
     * @param newAdmin The address of the new admin for the SynthToken.
     */
    function transferSynthTokenAdmin(address synthAddress, address newAdmin) external onlyOwner {
        SynthConfig storage config = synthConfigsByAddress[synthAddress];
        require(config.isRegistered, "SF: Synth not registered");
        require(newAdmin != address(0), "SF: New admin is zero address");

        SynthToken synthToken = SynthToken(synthAddress);
        synthToken.grantRole(synthToken.DEFAULT_ADMIN_ROLE(), newAdmin);
        synthToken.renounceRole(synthToken.DEFAULT_ADMIN_ROLE(), address(this));
        emit SynthAdminRoleTransferred(synthAddress, newAdmin);
    }


    // --- View Functions ---
    function getSynthConfig(address synthAddress) external view returns (SynthConfig memory) {
        require(synthConfigsByAddress[synthAddress].isRegistered, "SF: Synth not registered");
        return synthConfigsByAddress[synthAddress];
    }

    function getSynthAddressByAssetId(uint256 assetId) external view returns (address) {
        return synthAddressByAssetId[assetId];
    }

    function getDeployedSynthsCount() external view returns (uint256) {
        return deployedSynthAddresses.length;
    }

    function getDeployedSynthAddressAtIndex(uint256 index) external view returns (address) {
        return deployedSynthAddresses[index];
    }

    function isSynthRegistered(address queryAddress) external view returns (bool) {
        return synthConfigsByAddress[queryAddress].isRegistered;
    }

    // --- Pausable ---
    function pause() external onlyOwner { // Pauses deploying new synths
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}