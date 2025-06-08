// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol"; // If params are updatable
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./IInterestRateModel.sol";
import "../../common/libraries/SafeDecimalMath.sol"; // For precise calculations

/**
 * @title PiecewiseLinearInterestRateModel
 * @author Unxversal Team (Inspired by Compound/Aave V2 models)
 * @notice A standard interest rate model with a kink point.
 *         Borrow rates increase linearly based on utilization, with a steeper slope after the kink.
 * @dev All rates are per block. Precision is 1e18.
 */
contract PiecewiseLinearInterestRateModel is IInterestRateModel, Ownable {
    using SafeDecimalMath for uint256;

    uint256 public constant BLOCKS_PER_YEAR = 2_628_000; // Assuming ~12s block time (adjust for Peaq)
    uint256 private constant UTILIZATION_PRECISION = 1e18; // For utilization ratio
    uint256 private constant BPS_DENOMINATOR = 10000; // For basis points calculations

    // Rates are per block, scaled by 1e18.
    // e.g., 0.0000000237823... for 5% APR (5% / BLOCKS_PER_YEAR)
    uint256 public baseRatePerBlock;
    uint256 public multiplierPerBlock; // Slope before kink
    uint256 public kinkUtilizationRate; // Utilization rate at which the slope changes (scaled by 1e18, e.g., 0.8e18 for 80%)
    uint256 public jumpMultiplierPerBlock; // Additional slope after kink (this is added to multiplierPerBlock)

    event NewInterestParams(
        uint256 baseRatePerBlock,
        uint256 multiplierPerBlock,
        uint256 kinkUtilizationRate,
        uint256 jumpMultiplierPerBlock
    );

    /**
     * @param _baseRateAnnual Annual base borrow rate (e.g., 200 for 2.00%, scaled by 100).
     * @param _multiplierAnnual Annual slope of interest rate before kink (e.g., 900 for 9.00%).
     * @param _kinkUtilizationAnnual Utilization rate at kink (e.g., 8000 for 80.00%).
     * @param _jumpMultiplierAnnual Annual additional slope after kink (e.g., 20000 for 200.00%).
     * @param _owner The owner who can update parameters.
     */
    constructor(
        uint256 _baseRateAnnual,        // e.g., 200 for 2% (scaled by 100 = 1%)
        uint256 _multiplierAnnual,      // e.g., 900 for 9%
        uint256 _kinkUtilizationAnnual, // e.g., 8000 for 80%
        uint256 _jumpMultiplierAnnual,  // e.g., 20000 for 200%
        address _owner
    ) Ownable(_owner) {
        updateModelParameters(_baseRateAnnual, _multiplierAnnual, _kinkUtilizationAnnual, _jumpMultiplierAnnual);
    }

    /**
     * @notice Updates the parameters of the interest rate model.
     * @dev Only callable by the owner. All rates are annual percentages scaled by 100 (1% = 100).
     */
    function updateModelParameters(
        uint256 _baseRateAnnual,
        uint256 _multiplierAnnual,
        uint256 _kinkUtilizationAnnual,
        uint256 _jumpMultiplierAnnual
    ) public onlyOwner {
        require(_kinkUtilizationAnnual <= 10000, "IRM: Kink too high"); // Max 100%

        // Convert annual percentage rates (scaled by 100) to per-block rates (scaled by 1e18)
        // Rate per block = (AnnualRate / 100 (to get decimal) / 100 (if input is %*100) ) / BLOCKS_PER_YEAR * 1e18
        // Rate per block = (AnnualRateScaledBy100 / (100 * 100) / BLOCKS_PER_YEAR) * 1e18
        // Rate per block = (AnnualRateScaledBy100 * 1e18) / (10000 * BLOCKS_PER_YEAR)
        uint256 denominator = BPS_DENOMINATOR * BLOCKS_PER_YEAR; // 10000 (for BPS) * blocks

        baseRatePerBlock = (_baseRateAnnual * UTILIZATION_PRECISION) / denominator;
        multiplierPerBlock = (_multiplierAnnual * UTILIZATION_PRECISION) / denominator;
        jumpMultiplierPerBlock = (_jumpMultiplierAnnual * UTILIZATION_PRECISION) / denominator;
        kinkUtilizationRate = (_kinkUtilizationAnnual * UTILIZATION_PRECISION) / BPS_DENOMINATOR; // Kink is 0-1e18

        emit NewInterestParams(baseRatePerBlock, multiplierPerBlock, kinkUtilizationRate, jumpMultiplierPerBlock);
    }


    /**
     * @inheritdoc IInterestRateModel
     * @dev Calculates borrow rate: base + (slope1 * utilization) [+ slope2 * (utilization - kink)]
     */
    function getBorrowRate(
        uint256 underlyingBalance, // Cash available in the uToken contract
        uint256 totalBorrows,      // Total amount borrowed from this market
        uint256 /*totalReserves*/  // Reserves are not directly used in this model's borrow rate calculation
    ) external view override returns (uint256) {
        if (totalBorrows == 0) { // No borrows, utilization is 0
            return baseRatePerBlock;
        }

        uint256 utilizationRatio = calculateUtilizationRatio(underlyingBalance, totalBorrows);
        uint256 borrowRate = baseRatePerBlock;

        if (utilizationRatio <= kinkUtilizationRate) {
            // rate = (utilization * multiplierPerBlock) + baseRatePerBlock
            borrowRate += utilizationRatio.multiplyDecimal(multiplierPerBlock);
        } else {
            // rate = (kinkUtilization * multiplierPerBlock) + ((utilization - kinkUtilization) * jumpMultiplierPerBlock) + baseRatePerBlock
            uint256 normalRateAtKink = kinkUtilizationRate.multiplyDecimal(multiplierPerBlock);
            uint256 excessUtilization = utilizationRatio - kinkUtilizationRate;
            uint256 jumpRate = excessUtilization.multiplyDecimal(jumpMultiplierPerBlock);
            borrowRate += normalRateAtKink + jumpRate;
        }
        return borrowRate;
    }

    /**
     * @inheritdoc IInterestRateModel
     * @dev Supply Rate = Borrow Rate * Utilization Rate * (1 - Reserve Factor)
     */
    function getSupplyRate(
        uint256 underlyingBalance,
        uint256 totalBorrows,
        uint256 totalReserves,
        uint256 reserveFactorMantissa // Scaled by 1e18 (e.g., 0.1e18 for 10%)
    ) external view override returns (uint256) {
        if (totalBorrows == 0 && underlyingBalance == 0) return 0; // No activity

        uint256 oneMinusReserveFactor = UTILIZATION_PRECISION - reserveFactorMantissa; // Assuming reserveFactorMantissa <= 1e18
        uint256 borrowRate = this.getBorrowRate(underlyingBalance, totalBorrows, totalReserves);
        uint256 utilizationRatio = calculateUtilizationRatio(underlyingBalance, totalBorrows);

        // supplyRate = borrowRate * utilizationRatio * (1 - reserveFactor)
        // All scaled by 1e18, so intermediate products need division by 1e18
        uint256 interimRate = borrowRate.multiplyDecimal(utilizationRatio);
        uint256 supplyRate = interimRate.multiplyDecimal(oneMinusReserveFactor);

        return supplyRate;
    }

    /**
     * @notice Calculates the utilization ratio of the market.
     * @dev Utilization = TotalBorrows / (UnderlyingBalanceInPool + TotalBorrows - TotalReserves)
     *      If TotalReserves are considered part of liquidity available for borrow, then:
     *      Utilization = TotalBorrows / (UnderlyingBalanceInPool + TotalBorrows)
     *      Compound's model: Util = Borrows / (Cash + Borrows - Reserves). Assuming reserves are not borrowable.
     *      Aave's model: Util = TotalBorrows / TotalLiquidityAvailable (which is cash for lending).
     *      Let's use the simpler: Borrows / (Cash + Borrows). This means utilization can reach 100%.
     * @return Utilization ratio, scaled by 1e18 (UTILIZATION_PRECISION).
     */
    function calculateUtilizationRatio(
        uint256 underlyingBalance,
        uint256 totalBorrows
    ) public pure returns (uint256) {
        if (totalBorrows == 0) {
            return 0; // No borrows, utilization is 0
        }
        // utilization = totalBorrows / (totalBorrows + underlyingBalance)
        uint256 totalLiquidity = totalBorrows + underlyingBalance;
        if (totalLiquidity == 0) return 0; // Should not happen if totalBorrows > 0

        return totalBorrows.divideDecimal(totalLiquidity); // Results in a 1e18 scaled value
    }
}