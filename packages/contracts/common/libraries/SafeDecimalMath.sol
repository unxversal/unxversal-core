// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SafeDecimalMath
 * @author Unxversal Team (inspired by various fixed-point math libraries)
 * @notice Library for performing common arithmetic operations with fixed-point decimal numbers.
 * @dev Assumes that decimal numbers are represented as uint256 integers with a fixed number
 *      of decimal places, typically 18 (WAD) or as defined by `getDecimalPrecision()`.
 *      Uses OpenZeppelin's Math.Rounding for division.
 */
library SafeDecimalMath {
    // Default precision for numbers if not otherwise specified (e.g., 10^18 for WAD)
    uint256 private constant DEFAULT_DECIMAL_PRECISION = 1e18;

    // Error messages
    string private constant ERROR_DIV_BY_ZERO = "SafeDecimalMath: Division by zero";
    string private constant ERROR_MUL_OVERFLOW = "SafeDecimalMath: Multiplication overflow";

    /**
     * @notice Returns the standard decimal precision used by this library (10^18).
     */
    function getDecimalPrecision() internal pure returns (uint256) {
        return DEFAULT_DECIMAL_PRECISION;
    }

    /**
     * @notice Multiplies two decimal numbers, maintaining precision.
     * @dev x * y / precision
     * @param x The first decimal number.
     * @param y The second decimal number.
     * @return The product, scaled to the standard precision.
     */
    function multiplyDecimal(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, y, DEFAULT_DECIMAL_PRECISION, Math.Rounding.Floor);
    }

    /**
     * @notice Multiplies two decimal numbers, maintaining precision, with specific rounding.
     * @dev x * y / precision
     * @param x The first decimal number.
     * @param y The second decimal number.
     * @param rounding The rounding mode to use (Up, Down, Celling, Floor from OZ Math).
     * @return The product, scaled to the standard precision.
     */
    function multiplyDecimal(uint256 x, uint256 y, Math.Rounding rounding) internal pure returns (uint256) {
        return Math.mulDiv(x, y, DEFAULT_DECIMAL_PRECISION, rounding);
    }


    /**
     * @notice Divides one decimal number by another, maintaining precision.
     * @dev (x * precision) / y
     * @param x The numerator (decimal number).
     * @param y The denominator (decimal number).
     * @return The quotient, scaled to the standard precision.
     */
    function divideDecimal(uint256 x, uint256 y) internal pure returns (uint256) {
        require(y > 0, ERROR_DIV_BY_ZERO);
        return Math.mulDiv(x, DEFAULT_DECIMAL_PRECISION, y, Math.Rounding.Floor);
    }

    /**
     * @notice Divides one decimal number by another, maintaining precision, with specific rounding.
     * @dev (x * precision) / y
     * @param x The numerator (decimal number).
     * @param y The denominator (decimal number).
     * @param rounding The rounding mode to use (Up, Down, Celling, Floor from OZ Math).
     * @return The quotient, scaled to the standard precision.
     */
    function divideDecimal(uint256 x, uint256 y, Math.Rounding rounding) internal pure returns (uint256) {
        require(y > 0, ERROR_DIV_BY_ZERO);
        return Math.mulDiv(x, DEFAULT_DECIMAL_PRECISION, y, rounding);
    }

    /**
     * @notice Calculates a percentage of a decimal value.
     * @dev (value * percentageBps) / (BPS_DENOMINATOR * precision_factor_if_percentage_is_decimal)
     *      If percentageBps is a whole number percentage * 100 (e.g., 500 for 5%),
     *      then this is effectively (value * percentageBps) / 10000.
     *      The result maintains the precision of `value`.
     * @param value The decimal value to take the percentage of.
     * @param percentageBps The percentage in basis points (1% = 100 bps).
     * @return The calculated percentage of the value.
     */
    function calculatePercentage(uint256 value, uint256 percentageBps) internal pure returns (uint256) {
        uint256 BPS_PRECISION = 10000; // Basis points denominator
        // (value * percentageBps) / BPS_PRECISION
        // Math.mulDiv already handles scaling correctly.
        return Math.mulDiv(value, percentageBps, BPS_PRECISION, Math.Rounding.Floor);
    }

    /**
     * @notice Adds two decimal numbers.
     * @dev Standard addition, assumes both inputs have the same precision.
     * @param x The first decimal number.
     * @param y The second decimal number.
     * @return The sum.
     */
    function addDecimal(uint256 x, uint256 y) internal pure returns (uint256) {
        uint256 z = x + y;
        require(z >= x, "SafeDecimalMath: Addition overflow"); // Check for overflow
        return z;
    }

    /**
     * @notice Subtracts one decimal number from another.
     * @dev Standard subtraction, assumes both inputs have the same precision.
     * @param x The number to subtract from.
     * @param y The number to subtract.
     * @return The difference.
     */
    function subtractDecimal(uint256 x, uint256 y) internal pure returns (uint256) {
        require(x >= y, "SafeDecimalMath: Subtraction underflow"); // Check for underflow
        return x - y;
    }

    /**
     * @notice Converts a number to the standard decimal precision (e.g., if input is a whole number).
     * @param x The number to convert.
     * @return x scaled by the decimal precision.
     */
    function toDecimal(uint256 x) internal pure returns (uint256) {
        // x * DEFAULT_DECIMAL_PRECISION / 1
        // Check for overflow before multiplication
        if (x == 0) return 0;
        require(DEFAULT_DECIMAL_PRECISION <= type(uint256).max / x, ERROR_MUL_OVERFLOW);
        return x * DEFAULT_DECIMAL_PRECISION;
    }

    /**
     * @notice Converts a number from the standard decimal precision to a whole number (truncates).
     * @param x The decimal number to convert.
     * @return x divided by the decimal precision.
     */
    function fromDecimal(uint256 x) internal pure returns (uint256) {
        return x / DEFAULT_DECIMAL_PRECISION; // Integer division truncates
    }
}