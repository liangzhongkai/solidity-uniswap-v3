// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.27;

import {Tick} from "./lib/Tick.sol";
import {TickMath} from "./lib/TickMath.sol";
import {Position} from "./lib/Position.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SafeCast} from "./lib/SafeCast.sol";
import {SqrtPriceMath} from "./lib/SqrtPriceMath.sol";
import {SwapMath} from "./lib/SwapMath.sol";
import {FullMath} from "./lib/FullMath.sol";
import {FixedPoint128} from "./lib/FixedPoint128.sol";
import {TickBitmap} from "./lib/TickBitmap.sol";

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

function checkTicks(int24 tickLower, int24 tickUpper) pure {
    require(tickLower < tickUpper, "tickLower < tickUpper");
    require(tickLower >= TickMath.MIN_TICK, "tickLower < MIN_TICK");
    require(tickUpper <= TickMath.MAX_TICK, "tickUpper > MAX_TICK");
}

contract CLAMM {
    using SafeCast for uint256;
    using SafeCast for int256;
    using Position for mapping(bytes32 => Position.Info); // for get()
    using Position for Position.Info; // for update()
    using Tick for mapping(int24 => Tick.Info); // for update() and clear()
    using Tick for Tick.Info; // for cross()
    using TickBitmap for mapping(int16 => uint256); // for nextInitializedTickWithinOneWord()

    address private immutable TOKEN0;
    address private immutable TOKEN1;
    // 0.1% = 1000
    uint24 private immutable FEE;
    int24 private immutable TICK_SPACING;
    uint128 private immutable MAX_LIQUIDITY_PER_TICK;

    Slot0 public slot0;
    uint128 public currentLiquidity;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;
    mapping(int24 => Tick.Info) public ticks;
    mapping(int16 => uint256) public tickBitmap;
    mapping(bytes32 => Position.Info) public positions;

    struct ModifyPositionParams {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
    }

    modifier lock() {
        _lockBefore();
        _;
        _lockAfter();
    }

    function _lockBefore() private {
        require(slot0.unlocked, "locked");
        slot0.unlocked = false;
    }

    function _lockAfter() private {
        slot0.unlocked = true;
    }

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

    function _updatePosition(address owner, int24 tickLower, int24 tickUpper, int128 liquidityDelta, int24 tick)
        private
        returns (Position.Info storage position)
    {
        position = positions.get(owner, tickLower, tickUpper);

        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128;
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128;

        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                false,
                MAX_LIQUIDITY_PER_TICK
            );
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                true,
                MAX_LIQUIDITY_PER_TICK
            );

            if (flippedLower) {
                tickBitmap.flipTick(tickLower, TICK_SPACING);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, TICK_SPACING);
            }
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);

        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);
        position.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1X128;

        // Liquidity decreased and tick was flipped = liquidity after is 0
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    function _modifyPosition(ModifyPositionParams memory params)
        private
        returns (Position.Info storage position, int256 amount0, int256 amount1)
    {
        checkTicks(params.tickLower, params.tickUpper);

        Slot0 memory _slot0 = slot0;

        position = _updatePosition(params.owner, params.tickLower, params.tickUpper, params.liquidityDelta, _slot0.tick);

        // Get amount 0 and amount 1
        // token 1 | token 0
        // --------|---------
        //        tick
        if (params.liquidityDelta != 0) {
            if (_slot0.tick < params.tickLower) {
                // Calculate amount 0
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (_slot0.tick < params.tickUpper) {
                // Calculate amount 0 and amount 1
                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96, TickMath.getSqrtRatioAtTick(params.tickUpper), params.liquidityDelta
                );
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower), _slot0.sqrtPriceX96, params.liquidityDelta
                );

                currentLiquidity = params.liquidityDelta < 0
                    ? currentLiquidity - SafeCast.absAsUint128(params.liquidityDelta)
                    : currentLiquidity + SafeCast.toUint128(params.liquidityDelta);
            } else {
                // Calculate amount 1
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        require(amount > 0, "amount = 0");
        require(uint256(amount) <= uint256(int256(type(int128).max)), "liquidity overflow");

        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient,
                tickLower: tickLower,
                tickUpper: tickUpper,
                // amount bounded by int128.max require above
                // forge-lint: disable-next-line(unsafe-typecast)
                liquidityDelta: int128(int256(uint256(amount)))
            })
        );

        amount0 = amount0Int.toUint256();
        amount1 = amount1Int.toUint256();

        if (amount0 > 0) {
            require(IERC20(TOKEN0).transferFrom(msg.sender, address(this), amount0), "transfer0 failed");
        }
        if (amount1 > 0) {
            require(IERC20(TOKEN1).transferFrom(msg.sender, address(this), amount1), "transfer1 failed");
        }
    }

    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external lock returns (uint128 amount0, uint128 amount1) {
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

        // min(amount owed, amount request)
        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        // console.log("Amount 0", amount0, IERC20(token0).balanceOf(address(this)));
        // console.log("Amount 1", amount1, IERC20(token1).balanceOf(address(this)));

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            require(IERC20(TOKEN0).transfer(recipient, amount0), "transfer0 failed");
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            require(IERC20(TOKEN1).transfer(recipient, amount1), "transfer1 failed");
        }
    }

    function burn(int24 tickLower, int24 tickUpper, uint128 amount)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: msg.sender,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(amount)).toInt128()
            })
        );

        amount0 = amount0Int.negToUint256();
        amount1 = amount1Int.negToUint256();

        if (amount0 > 0) {
            position.tokensOwed0 = position.tokensOwed0 + amount0.toUint128();
            // IERC20(TOKEN0).transfer(msg.sender, amount0); todo
        }
        if (amount1 > 0) {
            position.tokensOwed1 = position.tokensOwed1 + amount1.toUint128();
            // IERC20(TOKEN1).transfer(msg.sender, amount1); todo
        }
    }

    struct SwapCache {
        uint128 liquidityStart;
    }

    struct SwapState {
        int256 amountSpecifiedRemaining;
        // amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
        // fee growth on input token
        uint256 feeGrowthGlobalX128;
        // current liquidity in range
        uint128 liquidity;
    }

    struct StepComputations {
        uint160 sqrtPriceStartX96;
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        lock
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified != 0);

        Slot0 memory slot0Start = slot0;

        // token 1 | token 0
        // --------|---------
        //        tick
        // <-- zero for one
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            "invalid sqrt price limit"
        );

        SwapCache memory cache = SwapCache({liquidityStart: currentLiquidity});

        // true = sell some specified amount of token in
        // false = buy some specified amount of token out
        bool exactInput = amountSpecified > 0;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0Start.sqrtPriceX96,
            tick: slot0Start.tick,
            // Fee on token in
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            liquidity: cache.liquidityStart
        });

        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            // Get next tick
            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                TICK_SPACING,
                // zero for one --> price decreases --> lte
                // one for zero --> price increases --> gt
                zeroForOne
            );

            // Bound tick next
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                // zero for one --> max(next, limit)
                // one for zero --> min(next, limit)
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                FEE
            );

            if (exactInput) {
                // Decreases to 0
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated -= step.amountOut.toInt256();
            } else {
                // Increases to 0
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated += (step.amountIn + step.feeAmount).toInt256();
            }

            if (state.liquidity > 0) {
                // fee growth += fee amount * (1 << 128) / liquidity
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);
            }

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                if (step.initialized) {
                    int128 liquidityNet = ticks.cross(
                        step.tickNext,
                        zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128,
                        zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128
                    );

                    if (zeroForOne) {
                        liquidityNet = -liquidityNet;
                    }

                    state.liquidity = liquidityNet < 0
                        ? state.liquidity - SafeCast.absAsUint128(liquidityNet)
                        : state.liquidity + SafeCast.toUint128(liquidityNet);
                }
                // zeroForOne = true --> tickNext <= state.tick
                // if tickNext = state.tick --> nextInitializedTick = tickNext, so -1 to get next tick
                // if tickNext < state.tick --> nextInitializedTick = tickNext, so -1 to get next tick
                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // state.sqrtPriceX96 is still in between 2 initialized ticks
                // Recompute tick
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // Update sqrtPriceX96 and tick
        if (state.tick != slot0Start.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        } else {
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // Update currentLiquidity
        if (cache.liquidityStart != state.liquidity) {
            currentLiquidity = state.liquidity;
        }

        // Update fee growth
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        }

        // Set amount0 and amount1
        // zero for one | exact input |
        //    true      |    true     | amount 0 = specified - remaining (> 0)
        //              |             | amount 1 = calculated            (< 0)
        //    false     |    false    | amount 0 = specified - remaining (< 0)
        //              |             | amount 1 = calculated            (> 0)
        //    false     |    true     | amount 0 = calculated            (< 0)
        //              |             | amount 1 = specified - remaining (> 0)
        //    true      |    false    | amount 0 = calculated            (> 0)
        //              |             | amount 1 = specified - remaining (< 0)
        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        // Transfer tokens
        if (zeroForOne) {
            if (amount1 < 0) {
                require(IERC20(TOKEN1).transfer(recipient, amount1.negToUint256()), "transfer1 failed");
                require(
                    IERC20(TOKEN0).transferFrom(msg.sender, address(this), amount0.toUint256()), "transferFrom0 failed"
                );
            }
        } else {
            if (amount0 < 0) {
                require(IERC20(TOKEN0).transfer(recipient, amount0.negToUint256()), "transfer0 failed");
                require(
                    IERC20(TOKEN1).transferFrom(msg.sender, address(this), amount1.toUint256()), "transferFrom1 failed"
                );
            }
        }
    }
}
