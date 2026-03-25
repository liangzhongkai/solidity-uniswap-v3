// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.27;

import {TickMath} from "./TickMath.sol";

library Tick {
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing)
        internal
        pure
        returns (uint128)
    {
        // Round down to a multiple of tick spacing
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        // Round up num ticks
        uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
        // Max liquidity = max(uint128) = 2**128 - 1
        // Max liquidity / num of ticks
        return type(uint128).max / numTicks;
    }
}