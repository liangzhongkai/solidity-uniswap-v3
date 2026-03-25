// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.27;

import {Tick} from "./lib/Tick.sol";
import {TickMath} from "./lib/TickMath.sol";

// slot 0 = 32 bytes
// 2**256 = 32 bytes
struct Slot0 {
    // 160 / 8 = 20 bytes
    uint160 sqrtPriceX96;
    // 24 / 8 = 3 bytes
    int24 tick;
    // 1 byte
    bool unlocked;
}

contract CLAMM {
    address private immutable TOKEN0;
    address private immutable TOKEN1;
    // 0.1% = 1000
    uint24 private immutable FEE;
    int24 private immutable TICK_SPACING;
    uint128 private immutable MAX_LIQUIDITY_PER_TICK;

    Slot0 public slot0;

    constructor(address _token0, address _token1, uint24 _fee, int24 _tickSpacing) {
        require(_token0 != address(0), "token 0 = zero address");
        require(_token0 < _token1, "token 0 >= token 1");

        TOKEN0 = _token0;
        TOKEN1 = _token1;
        FEE = _fee;
        TICK_SPACING = _tickSpacing;
        MAX_LIQUIDITY_PER_TICK = Tick.tickSpacingToMaxLiquidityPerTick(TICK_SPACING);
    }

    function token0() external view returns (address) {
        return TOKEN0;
    }

    function token1() external view returns (address) {
        return TOKEN1;
    }

    function fee() external view returns (uint24) {
        return FEE;
    }

    function tickSpacing() external view returns (int24) {
        return TICK_SPACING;
    }

    function maxLiquidityPerTick() external view returns (uint128) {
        return MAX_LIQUIDITY_PER_TICK;
    }

    function initialize(uint160 sqrtPriceX96) external {
        require(slot0.sqrtPriceX96 == 0, "already initialized");
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick, unlocked: true});
    }
}
