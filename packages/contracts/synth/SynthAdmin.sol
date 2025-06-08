// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../common/access/ProtocolAdminAccess.sol"; // Inherits Ownable
import "./USDCVault.sol";
import "./SynthFactory.sol";
import "./SynthLiquidationEngine.sol"; // Added
import "../common/interfaces/IOracleRelayer.sol";

/**
 * @title SynthAdmin
 * @author Unxversal Team
 * @notice Administrative module for the Unxversal Synthetics protocol.
 * @dev Manages critical parameters and target contract addresses for USDCVault, SynthFactory,
 *      and SynthLiquidationEngine. Owned by a multisig or DAO Timelock.
 *      This contract will be the owner of the core synth protocol contracts.
 */
contract SynthAdmin is ProtocolAdminAccess {
    USDCVault public usdcVault;
    SynthFactory public synthFactory;
    SynthLiquidationEngine public synthLiquidationEngine; // Added
    IOracleRelayer public oracleRelayer; // The OracleRelayerDst contract

    event USDCVaultSet(address indexed vaultAddress);
    event SynthFactorySet(address indexed factoryAddress);
    event SynthLiquidationEngineSet(address indexed engineAddress); // Added
    event OracleRelayerSet(address indexed oracleAddress);
    // Events for parameter changes are typically emitted by the target contracts themselves.

    constructor(
        address _initialOwner,
        address _usdcVault,         // Expected to be deployed already
        address _synthFactory,      // Expected to be deployed already
        address _synthLiquidationEngine, // Expected to be deployed already
        address _oracleRelayer
    ) ProtocolAdminAccess(_initialOwner) {
        // Set target contracts. Ownership of these contracts should be transferred to this SynthAdmin.
        setUSDCVault(_usdcVault);
        setSynthFactory(_synthFactory);
        setSynthLiquidationEngine(_synthLiquidationEngine); // Added
        setOracleRelayer(_oracleRelayer); // This sets it on SynthAdmin for reference
                                          // Individual contracts get it set via their own setters below.
    }

    // --- Target Contract Setters (Callable by SynthAdmin Owner) ---
    // These functions set the addresses in this admin contract.
    // The actual ownership transfer of those target contracts to this admin contract
    // must happen separately (e.g., targetContract.transferOwnership(address(thisSynthAdmin))).

    function setUSDCVault(address _newVaultAddress) public onlyOwner {
        require(_newVaultAddress != address(0), "SynthAdmin: Zero vault address");
        usdcVault = USDCVault(_newVaultAddress);
        emit USDCVaultSet(_newVaultAddress);
    }

    function setSynthFactory(address _newFactoryAddress) public onlyOwner {
        require(_newFactoryAddress != address(0), "SynthAdmin: Zero factory address");
        synthFactory = SynthFactory(_newFactoryAddress);
        emit SynthFactorySet(_newFactoryAddress);
    }

    function setSynthLiquidationEngine(address _newEngineAddress) public onlyOwner { // Added
        require(_newEngineAddress != address(0), "SynthAdmin: Zero liquidation engine address");
        synthLiquidationEngine = SynthLiquidationEngine(_newEngineAddress);
        emit SynthLiquidationEngineSet(_newEngineAddress);
    }

    function setOracleRelayer(address _newOracleAddress) public onlyOwner {
        require(_newOracleAddress != address(0), "SynthAdmin: Zero oracle address for admin ref");
        oracleRelayer = IOracleRelayer(_newOracleAddress);
        emit OracleRelayerSet(_newOracleAddress);
    }


    // --- USDCVault Parameter Management ---
    // These functions call setters on the USDCVault contract.
    // Requires this SynthAdmin contract to be the owner of usdcVault.

    function configureVaultParameters(
        uint256 _newMinCRbps,
        uint256 _newMintFeeBps,
        uint256 _newBurnFeeBps,
        address _newFeeRecipient,
        address _newTreasury,
        uint256 _newSurplusThreshold
    ) external onlyOwner {
        require(address(usdcVault) != address(0), "SynthAdmin: Vault not set");
        usdcVault.setMinCollateralRatio(_newMinCRbps);
        usdcVault.setMintFee(_newMintFeeBps);
        usdcVault.setBurnFee(_newBurnFeeBps);
        usdcVault.setFeeRecipient(_newFeeRecipient);
        usdcVault.setTreasury(_newTreasury);
        usdcVault.setSurplusBufferThreshold(_newSurplusThreshold);
    }

    function setVaultOracle(address _newOracle) external onlyOwner {
        require(address(usdcVault) != address(0), "SynthAdmin: Vault not set");
        usdcVault.setOracle(_newOracle);
    }

    function setVaultSynthFactory(address _newFactory) external onlyOwner {
        require(address(usdcVault) != address(0), "SynthAdmin: Vault not set");
        usdcVault.setSynthFactory(_newFactory);
    }
    
    function setVaultLiquidationEngine(address _newEngine) external onlyOwner {
        require(address(usdcVault) != address(0), "SynthAdmin: Vault not set");
        usdcVault.setLiquidationEngine(_newEngine);
    }

    // --- SynthFactory Parameter Management ---
    // Requires this SynthAdmin contract to be the owner of synthFactory.

    function addSynthToFactory(
        string calldata name,
        string calldata symbol,
        uint256 assetId,
        uint256 customMinCRbps,
        address controllerAddress // Should be address(usdcVault)
    ) external onlyOwner returns (address synthAddress) {
        require(address(synthFactory) != address(0), "SynthAdmin: Factory not set");
        require(controllerAddress == address(usdcVault) && controllerAddress != address(0), "SynthAdmin: Controller must be vault");
        return synthFactory.deploySynth(name, symbol, assetId, customMinCRbps, controllerAddress);
    }

    function setFactorySynthCustomMinCR(address synthAddress, uint256 newCustomMinCRbps) external onlyOwner {
        require(address(synthFactory) != address(0), "SynthAdmin: Factory not set");
        synthFactory.setSynthCustomMinCR(synthAddress, newCustomMinCRbps);
    }

    function setFactoryOracle(address _newOracle) external onlyOwner {
        require(address(synthFactory) != address(0), "SynthAdmin: Factory not set");
        synthFactory.setOracle(_newOracle);
    }

    function transferFactorySynthTokenAdmin(address synthAddress, address newAdmin) external onlyOwner {
        require(address(synthFactory) != address(0), "SynthAdmin: Factory not set");
        synthFactory.transferSynthTokenAdmin(synthAddress, newAdmin);
    }


    // --- SynthLiquidationEngine Parameter Management --- (Added)
    // Requires this SynthAdmin contract to be the owner of synthLiquidationEngine.

    function configureLiquidationEngineParams(
        uint256 _penaltyBps,
        uint256 _rewardShareBps,
        uint256 _maxPortionBps
    ) external onlyOwner {
        require(address(synthLiquidationEngine) != address(0), "SynthAdmin: Liquidation engine not set");
        synthLiquidationEngine.setLiquidationParameters(_penaltyBps, _rewardShareBps, _maxPortionBps);
    }

    function setLiquidationEngineUSDCVault(address _vaultAddress) external onlyOwner {
        require(address(synthLiquidationEngine) != address(0), "SynthAdmin: Liquidation engine not set");
        synthLiquidationEngine.setUSDCVault(_vaultAddress);
    }

    function setLiquidationEngineSynthFactory(address _factoryAddress) external onlyOwner {
        require(address(synthLiquidationEngine) != address(0), "SynthAdmin: Liquidation engine not set");
        synthLiquidationEngine.setSynthFactory(_factoryAddress);
    }

    function setLiquidationEngineOracle(address _oracleAddress) external onlyOwner {
        require(address(synthLiquidationEngine) != address(0), "SynthAdmin: Liquidation engine not set");
        synthLiquidationEngine.setOracle(_oracleAddress);
    }

     function setLiquidationEngineUsdcToken(address _usdcAddress) external onlyOwner {
        require(address(synthLiquidationEngine) != address(0), "SynthAdmin: Liquidation engine not set");
        synthLiquidationEngine.setUsdcToken(_usdcAddress);
    }


    // --- Protocol Pause/Unpause ---
    // These call pause/unpause on the respective contracts.
    // Assumes those contracts implement Pausable and are owned by this SynthAdmin.

    function pauseSynthProtocol() external onlyOwner {
        if (address(usdcVault) != address(0) && !usdcVault.paused()) {
             usdcVault.pauseActions(); // Assuming a function name like this in USDCVault
        }
        if (address(synthFactory) != address(0) && !synthFactory.paused()) {
            synthFactory.pause();
        }
        if (address(synthLiquidationEngine) != address(0) && !synthLiquidationEngine.paused()) {
            synthLiquidationEngine.pauseLiquidations(); // Assuming a function name
        }
    }

    function unpauseSynthProtocol() external onlyOwner {
        if (address(usdcVault) != address(0) && usdcVault.paused()) {
            usdcVault.unpauseActions();
        }
        if (address(synthFactory) != address(0) && synthFactory.paused()) {
            synthFactory.unpause();
        }
        if (address(synthLiquidationEngine) != address(0) && synthLiquidationEngine.paused()) {
            synthLiquidationEngine.unpauseLiquidations();
        }
    }

    // --- Fee/Surplus Management ---
    function sweepVaultSurplusToTreasury() external onlyOwner {
        require(address(usdcVault) != address(0), "SynthAdmin: Vault not set");
        usdcVault.sweepSurplusToTreasury();
    }

    // --- Ownership Transfers of Core Contracts ---
    // Functions to allow this SynthAdmin (owned by DAO Timelock) to transfer ownership
    // of the underlying protocol contracts to a new admin (e.g., a new version of SynthAdmin or directly to DAO).
    function transferUSDCVaultOwnership(address newOwner) external onlyOwner {
        require(address(usdcVault) != address(0), "SynthAdmin: Vault not set");
        usdcVault.transferOwnership(newOwner);
    }

    function transferSynthFactoryOwnership(address newOwner) external onlyOwner {
        require(address(synthFactory) != address(0), "SynthAdmin: Factory not set");
        synthFactory.transferOwnership(newOwner);
    }

    function transferLiquidationEngineOwnership(address newOwner) external onlyOwner {
        require(address(synthLiquidationEngine) != address(0), "SynthAdmin: Liquidation engine not set");
        synthLiquidationEngine.transferOwnership(newOwner);
    }
}