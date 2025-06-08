// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
// IERC20 and SafeERC20 are not directly needed here if CorePool handles all token movements based on approvals.
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./CorePool.sol"; // For interacting with CorePool
import "./LendRiskController.sol"; // For risk parameters and health checks
import "../common/interfaces/IOracleRelayer.sol"; // For prices
// SafeDecimalMath is not strictly needed here if Math.mulDiv covers needs.

/**
 * @title LendLiquidationEngine
 * @author Unxversal Team
 * @notice Handles liquidation of undercollateralized borrows in Unxversal Lend.
 * @dev Keepers call `liquidate`. Liquidator repays borrower's debt and seizes collateral at a bonus.
 *      Liquidator must approve CorePool for the debt asset they are repaying.
 */
contract LendLiquidationEngine is Ownable, ReentrancyGuard, Pausable {
    CorePool public corePool;
    LendRiskController public riskController;
    IOracleRelayer public oracle;

    // Max percentage of a single borrowed asset's outstanding balance that can be repaid in one liquidation call.
    uint256 public closeFactorBps; // e.g., 5000 for 50% (0-10000 BPS)
    
    uint256 public constant BPS_DENOMINATOR = 10000;

    event LiquidationCall(
        address indexed liquidator,
        address indexed borrower,
        address indexed debtAssetRepaid,
        uint256 amountDebtRepaid,       // In debt asset's native decimals
        address collateralAssetSeized,
        uint256 amountCollateralSeized, // In collateral asset's native decimals
        uint256 debtRepaidUsdValue,     // USD value of debt repaid (1e18 scaled)
        uint256 collateralSeizedUsdValue // USD value of collateral seized (1e18 scaled, includes bonus)
    );

    event CorePoolSet(address indexed poolAddress);
    event RiskControllerSet(address indexed controllerAddress);
    event OracleSet(address indexed oracleAddress);
    event CloseFactorSet(uint256 newCloseFactorBps);

    constructor(
        address _corePoolAddress,
        address _riskControllerAddress,
        address _oracleAddress,
        address _initialOwner
    ) Ownable(_initialOwner) {
        setCorePool(_corePoolAddress); // Emits
        setRiskController(_riskControllerAddress); // Emits
        setOracle(_oracleAddress); // Emits
        // closeFactorBps is set by owner post-deployment
    }

    // --- Admin Functions ---
    function setCorePool(address _newPoolAddress) public onlyOwner {
        require(_newPoolAddress != address(0), "LLE: Zero CorePool");
        corePool = CorePool(_newPoolAddress);
        emit CorePoolSet(_newPoolAddress);
    }

    function setRiskController(address _newControllerAddress) public onlyOwner {
        require(_newControllerAddress != address(0), "LLE: Zero RiskController");
        riskController = LendRiskController(_newControllerAddress);
        emit RiskControllerSet(_newControllerAddress);
    }

    function setOracle(address _newOracleAddress) public onlyOwner {
        require(_newOracleAddress != address(0), "LLE: Zero Oracle");
        oracle = IOracleRelayer(_newOracleAddress);
        emit OracleSet(_newOracleAddress);
    }

    function setCloseFactor(uint256 _newCloseFactorBps) external onlyOwner {
        require(_newCloseFactorBps > 0 && _newCloseFactorBps <= BPS_DENOMINATOR,
            "LLE: Invalid close factor");
        closeFactorBps = _newCloseFactorBps;
        emit CloseFactorSet(_newCloseFactorBps);
    }

    function pauseEngine() external onlyOwner { _pause(); } // Pauses new liquidations
    function unpauseEngine() external onlyOwner { _unpause(); }


    // --- Liquidation Function ---
    /**
     * @notice Liquidates an unhealthy borrow position.
     * @param borrower The address of the account to liquidate.
     * @param debtAssetToRepay The address of the underlying token for the debt being repaid.
     * @param collateralAssetToSeize The address of the underlying token for the collateral being seized.
     * @param amountToRepay The amount of `debtAssetToRepay` the liquidator wishes to repay.
     *                      The liquidator (`msg.sender`) must have approved `CorePool` to spend this amount.
     */
    function liquidate(
        address borrower,
        address debtAssetToRepay,
        address collateralAssetToSeize,
        uint256 amountToRepay // In native decimals of debtAssetToRepay
    ) external nonReentrant whenNotPaused { // Note: whenNotPaused applies to this engine. CorePool might have its own pause state.
        // Check if dependencies are set
        require(address(corePool) != address(0), "LLE: CorePool not set");
        require(address(riskController) != address(0), "LLE: RiskController not set");
        require(address(oracle) != address(0), "LLE: Oracle not set");
        require(closeFactorBps > 0, "LLE: Close factor not set");
        require(amountToRepay > 0, "LLE: Repay amount is zero");

        // 1. Verify borrower is liquidatable (via RiskController)
        require(riskController.isAccountLiquidatable(borrower), "LLE: Account not liquidatable");

        // 2. Get market configs from RiskController
        (bool debtIsListed,,,,,, uint256 debtOracleAssetId, uint8 debtUnderlyingDecimals) = riskController.marketRiskConfigs(debtAssetToRepay);
        (bool collIsListed, bool collCanBeCollateral,,, uint256 collLiquidationBonusBps,, uint256 collOracleAssetId, uint8 collUnderlyingDecimals) = riskController.marketRiskConfigs(collateralAssetToSeize);
        require(debtIsListed, "LLE: Debt asset not listed");
        require(collIsListed && collCanBeCollateral, "LLE: Collateral asset not valid");

        // 3. Accrue interest for relevant markets in CorePool before reading balances
        // Note: CorePool's repayBorrowBehalfByEngine and seizeAndTransferCollateral should handle their own accruals.
        // It's safer for CorePool to manage its accruals internally before any state change.
        // So, this engine doesn't need to explicitly call accrueInterest if CorePool's methods do.
        // Let's assume CorePool's relevant methods (called below) handle accrual.

        // 4. Determine actual amount of debt to repay
        // Query CorePool for current borrow balance (after its internal accrual)
        (, uint256 borrowerDebtBalance) = corePool.getUserSupplyAndBorrowBalance(borrower, debtAssetToRepay);
        require(borrowerDebtBalance > 0, "LLE: Borrower has no debt for this asset");

        uint256 maxRepayableByCloseFactor = Math.mulDiv(borrowerDebtBalance, closeFactorBps, BPS_DENOMINATOR);
        uint256 actualAmountDebtToRepay = Math.min(amountToRepay, maxRepayableByCloseFactor);
        actualAmountDebtToRepay = Math.min(actualAmountDebtToRepay, borrowerDebtBalance);
        require(actualAmountDebtToRepay > 0, "LLE: Calculated repay amount is zero");

        // 5. Calculate USD value of the debt being repaid
        uint256 debtAssetPrice = oracle.getPrice(debtOracleAssetId); // 1e18 scaled USD per whole unit
        uint256 debtRepaidUsdValue = Math.mulDiv(actualAmountDebtToRepay, debtAssetPrice, (10**debtUnderlyingDecimals));
        require(debtRepaidUsdValue > 0, "LLE: Debt repaid USD value is zero");

        // 6. Calculate USD value of collateral to seize (debt repaid + bonus from collateral asset's config)
        require(collLiquidationBonusBps > 0, "LLE: Liquidation bonus not set for collateral"); // Bonus should typically be > 0

        uint256 bonusValueUsd = Math.mulDiv(debtRepaidUsdValue, collLiquidationBonusBps, BPS_DENOMINATOR);
        uint256 totalCollateralToSeizeUsdValue = debtRepaidUsdValue + bonusValueUsd;

        // 7. Convert seizeable USD value to amount of collateral asset
        uint256 collateralAssetPrice = oracle.getPrice(collOracleAssetId);
        require(collateralAssetPrice > 0, "LLE: Collateral price is zero");
        uint256 amountCollateralToSeize = Math.mulDiv(totalCollateralToSeizeUsdValue, (10**collUnderlyingDecimals), collateralAssetPrice);
        require(amountCollateralToSeize > 0, "LLE: Calculated seize amount is zero");

        // 8. Liquidator (msg.sender) must have approved CorePool for `actualAmountDebtToRepay` of `debtAssetToRepay`.
        // This engine calls CorePool to execute the repayment on behalf of the liquidator.
        corePool.repayBorrowBehalfByEngine(
            _msgSender(),               // liquidator (payer)
            borrower,                   // borrower whose debt is reduced
            debtAssetToRepay,
            actualAmountDebtToRepay
        );
        // Note: repayBorrowBehalfByEngine in CorePool handles:
        // - Accruing interest for the debt market.
        // - Pulling `actualAmountDebtToRepay` of `debtAssetToRepay` from `liquidator` to the debt asset's `uToken`.
        // - Updating `borrower`'s borrow balance and market's `totalBorrowsPrincipal`.

        // 9. CorePool transfers seized collateral (underlying) from borrower's uToken holdings to liquidator
        corePool.seizeAndTransferCollateral(
            borrower,
            _msgSender(), // liquidator (recipient of collateral)
            collateralAssetToSeize,
            amountCollateralToSeize
        );
        // Note: seizeAndTransferCollateral in CorePool handles:
        // - Accruing interest for the collateral market.
        // - Calculating uTokens to burn from borrower based on `amountCollateralToSeize` and exchange rate.
        // - Burning those uTokens from borrower.
        // - Transferring `amountCollateralToSeize` of `collateralAssetToSeize` (underlying) from its uToken to `liquidator`.

        emit LiquidationCall(
            _msgSender(), borrower, debtAssetToRepay, actualAmountDebtToRepay,
            collateralAssetToSeize, amountCollateralToSeize,
            debtRepaidUsdValue, totalCollateralToSeizeUsdValue
        );
    }
}