// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title FundingRateLib
 * @author Unxversal Team
 * @notice Library for calculating perpetual futures funding rates.
 * @dev All rates and prices are expected to be scaled by 1e18 (SafeDecimalMath.DEFAULT_DECIMAL_PRECISION).
 */
library FundingRateLib {

    uint256 private constant ONE_HOUR_IN_SECONDS = 3600;
    uint256 private constant ONE_DAY_IN_SECONDS = 86400;

    struct FundingParams {
        uint256 fundingIntervalSeconds;   // e.g., 3600 for 1 hour, 28800 for 8 hours
        uint256 maxFundingRateAbsValue; // Max absolute funding rate per interval (1e18 scaled, e.g., 0.001e18 for 0.1%)
        // Potentially add impact premium/discount based on open interest skew if needed later
        // uint256 interestRateComponent; // (QuoteRate - BaseRate) per interval, if applicable (1e18 scaled)
    }

    /**
     * @notice Calculates the next funding rate for a perpetual market.
     * @param markPriceTwap Time-Weighted Average Price of the oracle/mark price (1e18 scaled).
     * @param indexPriceTwap Time-Weighted Average Price of the underlying spot index (1e18 scaled).
     * @param params Struct containing funding interval and max rate parameters.
     * @return nextFundingRate The calculated funding rate for the upcoming interval (1e18 scaled).
     *                         Positive if longs pay shorts, negative if shorts pay longs.
     */
    function calculateNextFundingRate(
        uint256 markPriceTwap,
        uint256 indexPriceTwap,
        FundingParams memory params
    ) internal pure returns (int256 nextFundingRate) {
        require(indexPriceTwap > 0, "FRL: Index price is zero");
        require(params.fundingIntervalSeconds > 0, "FRL: Funding interval is zero");

        // Premium = (MarkPriceTWAP - IndexPriceTWAP) / IndexPriceTWAP
        // Scale by 1e18 for precision
        int256 premium;
        if (markPriceTwap >= indexPriceTwap) {
            premium = int256(Math.mulDiv(markPriceTwap - indexPriceTwap, 1e18, indexPriceTwap));
        } else {
            premium = -int256(Math.mulDiv(indexPriceTwap - markPriceTwap, 1e18, indexPriceTwap));
        }

        // Basic funding rate is often just the premium averaged over the interval.
        // Funding Rate = Premium * (Time Until Funding / Funding Interval)
        // For simplicity, if this is called *at* funding time to determine rate for *next* interval,
        // the (Time Until Funding / Funding Interval) factor is 1.
        // More advanced models incorporate an interest rate component (e.g., borrow costs of quote vs base).
        // For now, funding rate = premium (clamped).
        // If an interest component is added:
        // int256 interestComponent = int256(params.interestRateComponent); // Assuming it's signed
        // fundingRate = premium + interestComponent;
        
        nextFundingRate = premium; // For simplicity, base funding rate is the premium

        // Clamp the funding rate
        int256 maxRate = int256(params.maxFundingRateAbsValue);
        if (nextFundingRate > maxRate) {
            nextFundingRate = maxRate;
        } else if (nextFundingRate < -maxRate) {
            nextFundingRate = -maxRate;
        }
    }

    /**
     * @notice Calculates the funding payment for a single position.
     * @param positionSizeNotional Size of the position in USD notional (int256: +long, -short).
     *                               This should be scaled by 1e18 if it represents precise USD.
     * @param marketCumulativeFundingIndex Current cumulative funding index of the market (1e18 scaled).
     * @param positionLastFundingIndex Snapshot of market's cumulative index when position was last settled (1e18 scaled).
     * @return fundingPayment Amount to be paid by/to the position holder (1e18 scaled USD).
     *                        Positive if position pays, negative if position receives.
     */
    function calculateFundingPayment(
        int256 positionSizeNotional, // e.g., 10000e18 for $10k long, -5000e18 for $5k short
        int256 marketCumulativeFundingIndex, // Can be positive or negative
        int256 positionLastFundingIndex      // Can be positive or negative
    ) internal pure returns (int256 fundingPayment) {
        if (positionSizeNotional == 0) {
            return 0;
        }
        // Payment = -PositionSize * (MarketCumulativeIndex - PositionSnapshotIndex)
        // All terms are 1e18 scaled. Result will be 1e36 scaled, need to divide by 1e18.
        // using SafeDecimalMath: result = positionSize.multiplyDecimal(indexDiff)
        // Since these are int256, use direct math with care or an IntSafeDecimalMath lib.

        int256 indexDifference = marketCumulativeFundingIndex - positionLastFundingIndex;

        // fundingPayment = positionSizeNotional * indexDifference / 1e18 (SafeDecimalMath.DEFAULT_DECIMAL_PRECISION)
        // Need to handle signs carefully.
        // If positionSizeNotional is positive (long):
        //   If indexDifference is positive (market funding rate was positive): longs pay (payment > 0)
        //   If indexDifference is negative (market funding rate was negative): longs receive (payment < 0)
        // Payment = PositionSize * (IndexNew - IndexOld)
        // A common convention: Funding payment = -Position Size * Funding Rate.
        // If funding rate is positive (longs pay shorts), long position (positive size) results in positive payment (debit).
        // If funding rate is positive, short position (negative size) results in negative payment (credit).
        // This implies payment = PositionSizeNotional * (MarketCumulativeIndex - PositionLastFundingIndex) / 1e18.
        // Let's verify the formula: payment = -Size * Rate.
        // If funding rate is positive: Longs pay shorts.
        //   Long position (+size): payment = -(+size) * (+rate) = negative (receives from system, which is wrong)
        //   Short position (-size): payment = -(-size) * (+rate) = positive (pays to system, which is wrong)
        // Standard: payment = PositionSize * FundingRate (where funding rate is per period for the notional)
        // If Index stores cumulative rates: Payment = PositionSize * (CurrentIndex - LastIndex)

        // Let CurrentIndex = C, LastIndex = L. Rate for period = C - L.
        // If Size > 0 (Long):
        //   If C > L (funding rate positive, longs pay shorts): Payment = Size * (C-L) -> Positive (Long pays)
        // If Size < 0 (Short):
        //   If C > L (funding rate positive, longs pay shorts): Payment = Size * (C-L) -> Negative (Short receives)
        // This seems correct.
        
        // (positionSizeNotional * indexDifference) / 1e18
        // To avoid overflow with intermediate multiplication if numbers are large:
        bool isNegative = false;
        uint256 absPositionSize = uint256(positionSizeNotional > 0 ? positionSizeNotional : -positionSizeNotional);
        uint256 absIndexDifference = uint256(indexDifference > 0 ? indexDifference : -indexDifference);

        if ((positionSizeNotional > 0 && indexDifference < 0) || (positionSizeNotional < 0 && indexDifference > 0)) {
            isNegative = true;
        }
        
        uint256 paymentMagnitude = Math.mulDiv(absPositionSize, absIndexDifference, 1e18); // (absSize * absDiff) / 1e18

        return isNegative ? -int256(paymentMagnitude) : int256(paymentMagnitude);
    }
}