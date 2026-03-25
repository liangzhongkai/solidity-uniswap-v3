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
    address public immutable token0;
    address public immutable token1;
    // 0.1% = 1000
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    uint128 public immutable maxLiquidityPerTick;

    Slot0 public slot0;

    constructor(
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickSpacing
    ) {
        require(_token0 != address(0), "token 0 = zero address");
        require(_token0 < _token1, "token 0 >= token 1");

        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(tickSpacing);
    }

    function initialize(uint160 sqrtPriceX96) external {
        require(slot0.sqrtPriceX96 == 0, "already initialized");
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick, unlocked: true});
    }

    
}