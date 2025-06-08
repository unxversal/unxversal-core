// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../common/access/ProtocolAdminAccess.sol"; // Inherits Ownable
import "./CorePool.sol";
import "./LendRiskController.sol";
import "./uToken.sol";
import "./interestModels/IInterestRateModel.sol";
import "./interestModels/PiecewiseLinearInterestRateModel.sol"; // Example concrete model
import "../common/interfaces/IOracleRelayer.sol";

/**
 * @title LendAdmin
 * @author Unxversal Team
 * @notice Administrative module for the Unxversal Lend protocol.
 * @dev Manages critical parameters for CorePool, LendRiskController, and associated
 *      uTokens and InterestRateModels. Owned by a multisig or DAO Timelock.
 *      This contract will be the owner of CorePool and LendRiskController.
 *      It can also deploy new uTokens and InterestRateModels or register existing ones.
 */
contract LendAdmin is ProtocolAdminAccess {
    CorePool public corePool;
    LendRiskController public lendRiskController;
    IOracleRelayer public oracleRelayer; // For configuring LendRiskController

    // Optional: Addresses of deployed uToken/InterestRateModel implementations for cloning/reference
    // address public uTokenImplementation;
    // address public piecewiseInterestModelImplementation;

    event CorePoolSet(address indexed poolAddress);
    event LendRiskControllerSet(address indexed controllerAddress);
    event OracleRelayerSet(address indexed oracleAddress); // For LRC configuration
    event MarketListedInCorePool(
        address indexed underlyingAsset,
        address indexed uTokenAddress,
        address indexed interestRateModelAddress
    );
    event MarketConfiguredInRiskController(
        address indexed underlyingAsset,
        address uTokenAddress, // Repeated for event clarity
        bool canBeCollateral,
        uint256 collateralFactorBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps,
        uint256 oracleAssetId
    );
    event ReserveFactorSet(address indexed underlyingAsset, uint256 newReserveFactorBps);
    event LiquidationEngineSetForCorePool(address indexed engineAddress);


    constructor(
        address _initialOwner,
        address _corePoolAddress,         // Expected to be deployed
        address _lendRiskControllerAddress, // Expected to be deployed
        address _oracleRelayerAddress    // For configuring LRC
    ) ProtocolAdminAccess(_initialOwner) {
        setCorePool(_corePoolAddress);
        setLendRiskController(_lendRiskControllerAddress);
        setOracleRelayer(_oracleRelayerAddress); // Store for LRC setup
    }

    // --- Target Contract Setters ---
    function setCorePool(address _newPoolAddress) public onlyOwner {
        require(_newPoolAddress != address(0), "LendAdmin: Zero CorePool");
        corePool = CorePool(_newPoolAddress);
        emit CorePoolSet(_newPoolAddress);
    }

    function setLendRiskController(address _newControllerAddress) public onlyOwner {
        require(_newControllerAddress != address(0), "LendAdmin: Zero RiskController");
        lendRiskController = LendRiskController(_newControllerAddress);
        emit LendRiskControllerSet(_newControllerAddress);
    }

    function setOracleRelayer(address _newOracleAddress) public onlyOwner {
        require(_newOracleAddress != address(0), "LendAdmin: Zero OracleRelayer for LRC");
        oracleRelayer = IOracleRelayer(_newOracleAddress);
        // Also update it on the LendRiskController if it's already set
        if (address(lendRiskController) != address(0)) {
            lendRiskController.setOracle(_newOracleAddress);
        }
        emit OracleRelayerSet(_newOracleAddress);
    }

    /**
     * @notice Lists a new asset market in the lending protocol.
     * @dev This involves:
     *      1. Deploying a new uToken contract (or using a pre-deployed one).
     *      2. Deploying a new InterestRateModel contract (or using a pre-deployed one).
     *      3. Calling CorePool.listMarket to register the uToken and its IRM.
     *      4. Calling LendRiskController.listMarket to set risk parameters.
     *      This function assumes new uToken and IRM are deployed per market for simplicity.
     *      Production systems might use clone factories for uTokens/IRMs.
     * @param uTokenName Name for the new uToken (e.g., "Unxversal USDC").
     * @param uTokenSymbol Symbol for the new uToken (e.g., "uUSDC").
     * @param underlyingAssetAddr Address of the underlying ERC20 token.
     * @param irmBaseRateAnnual Annual base borrow rate for IRM (e.g., 200 for 2.00%).
     * @param irmMultiplierAnnual Annual slope for IRM (e.g., 900 for 9.00%).
     * @param irmKinkAnnual Kink utilization for IRM (e.g., 8000 for 80.00%).
     * @param irmJumpMultiplierAnnual Annual jump slope for IRM (e.g., 20000 for 200.00%).
     * @param lrcCanBeCollateral True if asset can be collateral in LendRiskController.
     * @param lrcCollateralFactorBps Collateral factor in BPS for LRC.
     * @param lrcLiquidationThresholdBps Liquidation threshold in BPS for LRC.
     * @param lrcLiquidationBonusBps Liquidation bonus in BPS for LRC.
     * @param lrcOracleAssetId Oracle asset ID for LRC (0 to try derive from SynthFactory).
     */
    function listNewMarketFull(
        // uToken params
        string calldata uTokenName,
        string calldata uTokenSymbol,
        address underlyingAssetAddr,
        // InterestRateModel params (PiecewiseLinear for this example)
        uint256 irmBaseRateAnnual,
        uint256 irmMultiplierAnnual,
        uint256 irmKinkAnnual,
        uint256 irmJumpMultiplierAnnual,
        // LendRiskController params
        bool lrcCanBeCollateral,
        uint256 lrcCollateralFactorBps,
        uint256 lrcLiquidationThresholdBps,
        uint256 lrcLiquidationBonusBps,
        uint256 lrcOracleAssetId
    ) external onlyOwner {
        require(address(corePool) != address(0), "LendAdmin: CorePool not set");
        require(address(lendRiskController) != address(0), "LendAdmin: RiskController not set");
        require(underlyingAssetAddr != address(0), "LendAdmin: Zero underlying asset");

        // 1. Deploy new InterestRateModel (PiecewiseLinear example)
        // The owner of the IRM will be this LendAdmin contract.
        PiecewiseLinearInterestRateModel newIrm = new PiecewiseLinearInterestRateModel(
            irmBaseRateAnnual, irmMultiplierAnnual, irmKinkAnnual, irmJumpMultiplierAnnual, address(this)
        );

        // 2. Deploy new uToken
        // The owner of the uToken will be this LendAdmin contract.
        // CorePool needs to be able to call mint/burn on it.
        // uToken constructor: underlying, corePool, name, symbol, admin
        uToken newUToken = new uToken(
            underlyingAssetAddr, address(corePool), uTokenName, uTokenSymbol, address(this)
        );
        // After deployment, uToken owner (this LendAdmin) might need to grant specific roles/permissions
        // to CorePool if uToken methods are restricted beyond msg.sender == corePool.
        // The current uToken has `require(msg.sender == address(corePool))` which is fine.

        // 3. Call CorePool.listMarket
        // This function in CorePool should be onlyOwner (i.e., callable by this LendAdmin)
        corePool.listMarket(underlyingAssetAddr, address(newUToken), address(newIrm));
        emit MarketListedInCorePool(underlyingAssetAddr, address(newUToken), address(newIrm));

        // 4. Call LendRiskController.listMarket
        // This function in LendRiskController should be onlyOwner
        lendRiskController.listMarket(
            underlyingAssetAddr, address(newUToken), lrcCanBeCollateral,
            lrcCollateralFactorBps, lrcLiquidationThresholdBps, lrcLiquidationBonusBps, lrcOracleAssetId
        );
        emit MarketConfiguredInRiskController(
            underlyingAssetAddr, address(newUToken), lrcCanBeCollateral,
            lrcCollateralFactorBps, lrcLiquidationThresholdBps, lrcLiquidationBonusBps, lrcOracleAssetId
        );
    }

    /**
     * @notice Updates risk parameters for an existing market in LendRiskController.
     */
    function updateMarketRiskParameters(
        address underlyingAsset,
        bool canBeCollateral,
        uint256 collateralFactorBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps
        // oracleAssetId is updated separately if needed via setMarketOracleAssetId
    ) external onlyOwner {
        require(address(lendRiskController) != address(0), "LendAdmin: RiskController not set");
        // LendRiskController.listMarket can also be used for updates if it handles existing markets.
        // Or add specific update functions in LendRiskController.
        // Assuming LendRiskController.listMarket handles updates by checking if market already listed.
        address uTokenAddr = corePool.getUTokenForUnderlying(underlyingAsset); // Need this for LRC's listMarket
        (,,,,,, uint256 currentOracleAssetId,) = lendRiskController.marketRiskConfigs(underlyingAsset); // Preserve current

        lendRiskController.listMarket(
            underlyingAsset, uTokenAddr, canBeCollateral,
            collateralFactorBps, liquidationThresholdBps, liquidationBonusBps, currentOracleAssetId
        );
        // Event is emitted by LendRiskController
    }

    /** @notice Sets the oracle asset ID for a market in LendRiskController. */
    function setMarketOracleAssetIdLRC(address underlyingAsset, uint256 newOracleAssetId) external onlyOwner {
        require(address(lendRiskController) != address(0), "LendAdmin: RiskController not set");
        lendRiskController.setMarketOracleAssetId(underlyingAsset, newOracleAssetId);
    }

    /** @notice Updates the interest rate model parameters for a market. */
    function updateInterestRateModelParams(
        address underlyingAsset, // To find the IRM address via CorePool
        uint256 newBaseRateAnnual,
        uint256 newMultiplierAnnual,
        uint256 newKinkAnnual,
        uint256 newJumpMultiplierAnnual
    ) external onlyOwner {
        require(address(corePool) != address(0), "LendAdmin: CorePool not set");
        address irmAddress = corePool.getInterestRateModelForUnderlying(underlyingAsset);
        require(irmAddress != address(0), "LendAdmin: IRM not found for asset");
        // Assumes IRM is PiecewiseLinear and owned by this LendAdmin contract
        PiecewiseLinearInterestRateModel(payable(irmAddress)).updateModelParameters( // payable for OZ v5 constructor calls in some contexts
            newBaseRateAnnual, newMultiplierAnnual, newKinkAnnual, newJumpMultiplierAnnual
        );
    }
    
    /** @notice Sets a new interest rate model for a market in CorePool. */
    function setMarketInterestRateModel(address underlyingAsset, address newIrmAddress) external onlyOwner {
        require(address(corePool) != address(0), "LendAdmin: CorePool not set");
        // CorePool must have a setter for this, callable by its owner (this LendAdmin)
        corePool.setInterestRateModel(underlyingAsset, newIrmAddress);
    }

    /** @notice Sets the reserve factor for a market in CorePool. */
    function setMarketReserveFactor(address underlyingAsset, uint256 newReserveFactorBps) external onlyOwner {
        require(address(corePool) != address(0), "LendAdmin: CorePool not set");
        // CorePool must have a setter, callable by its owner
        corePool.setReserveFactor(underlyingAsset, newReserveFactorBps);
        emit ReserveFactorSet(underlyingAsset, newReserveFactorBps); // Or CorePool emits this
    }

    /** @notice Sets the LiquidationEngine address on CorePool. */
    function setCorePoolLiquidationEngine(address engineAddress) external onlyOwner {
        require(address(corePool) != address(0), "LendAdmin: CorePool not set");
        corePool.setLiquidationEngine(engineAddress);
        emit LiquidationEngineSetForCorePool(engineAddress);
    }

    // --- Ownership Transfers of Core Lend Contracts ---
    function transferCorePoolOwnership(address newOwner) external onlyOwner {
        require(address(corePool) != address(0), "LendAdmin: CorePool not set");
        corePool.transferOwnership(newOwner);
    }

    function transferLendRiskControllerOwnership(address newOwner) external onlyOwner {
        require(address(lendRiskController) != address(0), "LendAdmin: RiskController not set");
        lendRiskController.transferOwnership(newOwner);
    }

    // --- Protocol Pause (delegated to CorePool) ---
    // CorePool would implement Pausable and pause its core functions.
    function pauseLendProtocol() external onlyOwner {
        require(address(corePool) != address(0), "LendAdmin: CorePool not set");
        corePool.pause(); // Assuming CorePool has pause()
    }

    function unpauseLendProtocol() external onlyOwner {
        require(address(corePool) != address(0), "LendAdmin: CorePool not set");
        corePool.unpause(); // Assuming CorePool has unpause()
    }
}