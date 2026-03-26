// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.27;

// Copied from https://github.com/Uniswap/v4-core

import {SafeCast} from "./SafeCast.sol";
import {FullMath} from "./FullMath.sol";
import {UnsafeMath} from "./UnsafeMath.sol";
import {FixedPoint96} from "./FixedPoint96.sol";

/// @title Functions based on Q64.96 sqrt price and liquidity
/// @notice Contains the math that uses square root of price as a Q64.96 and liquidity to compute deltas
library SqrtPriceMath {
    using SafeCast for uint256;

    /// @notice Gets the next sqrt price given a delta of currency0
    /// @dev Always rounds up, because in the exact output case (increasing price) we need to move the price at least
    /// far enough to get the desired output amount, and in the exact input case (decreasing price) we need to move the
    /// price less in order to not send too much output.
    /// The most precise formula for this is liquidity * sqrtPx96 / (liquidity +- amount * sqrtPx96),
    /// if this is impossible because of overflow, we calculate liquidity / (liquidity / sqrtPx96 +- amount).
    /// @param sqrtPx96 The starting price, i.e. before accounting for the currency0 delta
    /// @param liquidity The amount of usable liquidity
    /// @param amount How much of currency0 to add or remove from virtual reserves
    /// @param add Whether to add or remove the amount of currency0
    /// @return The price after adding or removing amount, depending on add
    function getNextSqrtPriceFromAmount0RoundingUp(uint160 sqrtPx96, uint128 liquidity, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        // we short circuit amount == 0 because the result is otherwise not guaranteed to equal the input price
        if (amount == 0) return sqrtPx96;
        uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;

        if (add) {
            unchecked {
                uint256 product;
                if ((product = amount * sqrtPx96) / amount == sqrtPx96) {
                    uint256 denominator = numerator1 + product;
                    if (denominator >= numerator1) {
                        // always fits in 160 bits
                        return uint160(FullMath.mulDivRoundingUp(numerator1, sqrtPx96, denominator));
                    }
                }
            }
            // denominator is checked for overflow
            return uint160(UnsafeMath.divRoundingUp(numerator1, (numerator1 / sqrtPx96) + amount));
        } else {
            unchecked {
                uint256 product;
                // if the product overflows, we know the denominator underflows
                // in addition, we must check that the denominator does not underflow
                require((product = amount * sqrtPx96) / amount == sqrtPx96 && numerator1 > product);
                uint256 denominator = numerator1 - product;
                return FullMath.mulDivRoundingUp(numerator1, sqrtPx96, denominator).toUint160();
            }
        }
    }

    /// @notice Gets the next sqrt price given a delta of currency1
    /// @dev Always rounds down, because in the exact output case (decreasing price) we need to move the price at least
    /// far enough to get the desired output amount, and in the exact input case (increasing price) we need to move the
    /// price less in order to not send too much output.
    /// The formula we compute is within <1 wei of the lossless version: sqrtPx96 +- amount / liquidity
    /// @param sqrtPx96 The starting price, i.e., before accounting for the currency1 delta
    /// @param liquidity The amount of usable liquidity
    /// @param amount How much of currency1 to add, or remove, from virtual reserves
    /// @param add Whether to add, or remove, the amount of currency1
    /// @return The price after adding or removing `amount`
    function getNextSqrtPriceFromAmount1RoundingDown(uint160 sqrtPx96, uint128 liquidity, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        // if we're adding (subtracting), rounding down requires rounding the quotient down (up)
        // in both cases, avoid a mulDiv for most inputs
        if (add) {
            uint256 quotient =
                (amount <= type(uint160).max
                    ? (amount << FixedPoint96.RESOLUTION) / liquidity
                    : FullMath.mulDiv(amount, FixedPoint96.Q96, liquidity));

            return (uint256(sqrtPx96) + quotient).toUint160();
        } else {
            uint256 quotient =
                (amount <= type(uint160).max
                    ? UnsafeMath.divRoundingUp(amount << FixedPoint96.RESOLUTION, liquidity)
                    : FullMath.mulDivRoundingUp(amount, FixedPoint96.Q96, liquidity));

            require(sqrtPx96 > quotient);
            // always fits 160 bits (sqrtPx96 is uint160 and quotient is smaller)
            return (uint256(sqrtPx96) - quotient).toUint160();
        }
    }

    /// @notice Gets the next sqrt price given an input amount of currency0 or currency1
    /// @dev Throws if price or liquidity are 0, or if the next price is out of bounds
    /// @param sqrtPx96 The starting price, i.e., before accounting for the input amount
    /// @param liquidity The amount of usable liquidity
    /// @param amountIn How much of currency0, or currency1, is being swapped in
    /// @param zeroForOne Whether the amount in is currency0 or currency1
    /// @return sqrtQx96 The price after adding the input amount to currency0 or currency1
    function getNextSqrtPriceFromInput(uint160 sqrtPx96, uint128 liquidity, uint256 amountIn, bool zeroForOne)
        internal
        pure
        returns (uint160 sqrtQx96)
    {
        require(sqrtPx96 > 0);
        require(liquidity > 0);

        // round to make sure that we don't pass the target price
        return zeroForOne
            ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPx96, liquidity, amountIn, true)
            : getNextSqrtPriceFromAmount1RoundingDown(sqrtPx96, liquidity, amountIn, true);
    }

    /// @notice Gets the next sqrt price given an output amount of currency0 or currency1
    /// @dev Throws if price or liquidity are 0 or the next price is out of bounds
    /// @param sqrtPx96 The starting price before accounting for the output amount
    /// @param liquidity The amount of usable liquidity
    /// @param amountOut How much of currency0, or currency1, is being swapped out
    /// @param zeroForOne Whether the amount out is currency0 or currency1
    /// @return sqrtQx96 The price after removing the output amount of currency0 or currency1
    function getNextSqrtPriceFromOutput(uint160 sqrtPx96, uint128 liquidity, uint256 amountOut, bool zeroForOne)
        internal
        pure
        returns (uint160 sqrtQx96)
    {
        require(sqrtPx96 > 0);
        require(liquidity > 0);

        // round to make sure that we pass the target price
        return zeroForOne
            ? getNextSqrtPriceFromAmount1RoundingDown(sqrtPx96, liquidity, amountOut, false)
            : getNextSqrtPriceFromAmount0RoundingUp(sqrtPx96, liquidity, amountOut, false);
    }

    /// @notice Gets the amount0 delta between two prices
    /// @dev Calculates liquidity / sqrt(lower) - liquidity / sqrt(upper),
    /// i.e. liquidity * (sqrt(upper) - sqrt(lower)) / (sqrt(upper) * sqrt(lower))
    /// @param sqrtRatioAx96 A sqrt price
    /// @param sqrtRatioBx96 Another sqrt price
    /// @param liquidity The amount of usable liquidity
    /// @param roundUp Whether to round the amount up or down
    /// @return amount0 Amount of currency0 required to cover a position of size liquidity between the two passed prices
    function getAmount0Delta(uint160 sqrtRatioAx96, uint160 sqrtRatioBx96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount0)
    {
        unchecked {
            if (sqrtRatioAx96 > sqrtRatioBx96) {
                (sqrtRatioAx96, sqrtRatioBx96) = (sqrtRatioBx96, sqrtRatioAx96);
            }

            // NOTE liquidity << 96
            uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;
            uint256 numerator2 = sqrtRatioBx96 - sqrtRatioAx96;

            require(sqrtRatioAx96 > 0);

            return roundUp
                ? UnsafeMath.divRoundingUp(
                    FullMath.mulDivRoundingUp(numerator1, numerator2, sqrtRatioBx96), sqrtRatioAx96
                )
                : FullMath.mulDiv(numerator1, numerator2, sqrtRatioBx96) / sqrtRatioAx96;
        }
    }

    /// @notice Gets the amount1 delta between two prices
    /// @dev Calculates liquidity * (sqrt(upper) - sqrt(lower))
    /// @param sqrtRatioAx96 A sqrt price
    /// @param sqrtRatioBx96 Another sqrt price
    /// @param liquidity The amount of usable liquidity
    /// @param roundUp Whether to round the amount up, or down
    /// @return amount1 Amount of currency1 required to cover a position of size liquidity between the two passed prices
    function getAmount1Delta(uint160 sqrtRatioAx96, uint160 sqrtRatioBx96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAx96 > sqrtRatioBx96) {
            (sqrtRatioAx96, sqrtRatioBx96) = (sqrtRatioBx96, sqrtRatioAx96);
        }

        return roundUp
            ? FullMath.mulDivRoundingUp(liquidity, sqrtRatioBx96 - sqrtRatioAx96, FixedPoint96.Q96)
            : FullMath.mulDiv(liquidity, sqrtRatioBx96 - sqrtRatioAx96, FixedPoint96.Q96);
    }

    /// @notice Helper that gets signed currency0 delta
    /// @param sqrtRatioAx96 A sqrt price
    /// @param sqrtRatioBx96 Another sqrt price
    /// @param liquidity The change in liquidity for which to compute the amount0 delta
    /// @return amount0 Amount of currency0 corresponding to the passed liquidityDelta between the two prices
    function getAmount0Delta(uint160 sqrtRatioAx96, uint160 sqrtRatioBx96, int128 liquidity)
        internal
        pure
        returns (int256 amount0)
    {
        unchecked {
            // NOTE
            // liquidity < 0 = remove liquidity ---> round down amount to withdraw
            // liquidity > 0 = add liquidity    ---> round up amount required to deposit
            uint128 liq = SafeCast.absAsUint128(liquidity);
            return liquidity < 0
                ? -getAmount0Delta(sqrtRatioAx96, sqrtRatioBx96, liq, false).toInt256()
                : getAmount0Delta(sqrtRatioAx96, sqrtRatioBx96, liq, true).toInt256();
        }
    }

    /// @notice Helper that gets signed currency1 delta
    /// @param sqrtRatioAx96 A sqrt price
    /// @param sqrtRatioBx96 Another sqrt price
    /// @param liquidity The change in liquidity for which to compute the amount1 delta
    /// @return amount1 Amount of currency1 corresponding to the passed liquidityDelta between the two prices
    function getAmount1Delta(uint160 sqrtRatioAx96, uint160 sqrtRatioBx96, int128 liquidity)
        internal
        pure
        returns (int256 amount1)
    {
        unchecked {
            // NOTE
            // liquidity < 0 = remove liquidity ---> round down amount to withdraw
            // liquidity > 0 = add liquidity    ---> round up amount required to deposit
            uint128 liq = SafeCast.absAsUint128(liquidity);
            return liquidity < 0
                ? -getAmount1Delta(sqrtRatioAx96, sqrtRatioBx96, liq, false).toInt256()
                : getAmount1Delta(sqrtRatioAx96, sqrtRatioBx96, liq, true).toInt256();
        }
    }
}
