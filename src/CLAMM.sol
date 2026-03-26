// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.27;

import {Tick} from "./lib/Tick.sol";
import {TickMath} from "./lib/TickMath.sol";
import {Position} from "./lib/Position.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SafeCast} from "./lib/SafeCast.sol";
import {SqrtPriceMath} from "./lib/SqrtPriceMath.sol";

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

    address private immutable TOKEN0;
    address private immutable TOKEN1;
    // 0.1% = 1000
    uint24 private immutable FEE;
    int24 private immutable TICK_SPACING;
    uint128 private immutable MAX_LIQUIDITY_PER_TICK;

    Slot0 public slot0;
    mapping(bytes32 => Position.Info) public positions;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;
    mapping(int24 => Tick.Info) public ticks;
    uint128 public currentLiquidity;

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
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);

        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

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
                    ? currentLiquidity - uint128(-params.liquidityDelta)
                    : currentLiquidity + uint128(params.liquidityDelta);
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

        // forge-lint: disable-next-line(unsafe-typecast)
        amount0 = uint256(amount0Int);
        // forge-lint: disable-next-line(unsafe-typecast)
        amount1 = uint256(amount1Int);

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
            IERC20(TOKEN0).transfer(recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            IERC20(TOKEN1).transfer(recipient, amount1);
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

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0) {
            position.tokensOwed0 = position.tokensOwed0 + uint128(amount0);
            // IERC20(TOKEN0).transfer(msg.sender, amount0); todo
        }
        if (amount1 > 0) {
            position.tokensOwed1 = position.tokensOwed1 + uint128(amount1);
            // IERC20(TOKEN1).transfer(msg.sender, amount1); todo
        }
    }
}
