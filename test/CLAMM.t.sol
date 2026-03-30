// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {CLAMM} from "../src/CLAMM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TickMath} from "../src/lib/TickMath.sol";

contract CLAMMTest is Test {
    MockERC20 internal token0;
    MockERC20 internal token1;
    CLAMM internal pool;

    address internal lp = address(this);
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    function setUp() public {
        MockERC20 a = new MockERC20("TokenA", "TA");
        MockERC20 b = new MockERC20("TokenB", "TB");
        // CLAMM requires canonical token0 < token1 by address.
        if (address(a) < address(b)) {
            token0 = a;
            token1 = b;
        } else {
            token0 = b;
            token1 = a;
        }
        pool = new CLAMM(address(token0), address(token1), FEE, TICK_SPACING);
        token0.mint(lp, 1_000_000 ether);
        token1.mint(lp, 1_000_000 ether);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
    }

    function _initializeAtTick(int24 tick) internal {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(tick);
        pool.initialize(sqrtP);
    }

    /* ========== constructor / immutables ========== */

    function test_Constructor_RevertZeroToken0() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "token 0 = zero address"));
        new CLAMM(address(0), address(token1), FEE, TICK_SPACING);
    }

    function test_Constructor_RevertTokenOrder() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "token 0 >= token 1"));
        new CLAMM(address(token1), address(token0), FEE, TICK_SPACING);
    }

    function test_Constructor_Immutables() public view {
        assertEq(pool.token0(), address(token0));
        assertEq(pool.token1(), address(token1));
        assertEq(pool.fee(), FEE);
        assertEq(pool.tickSpacing(), TICK_SPACING);
        assertGt(pool.maxLiquidityPerTick(), 0);
    }

    /* ========== initialize ========== */

    function test_Initialize_SetsPriceAndTick() public {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        pool.initialize(sqrtP);
        (uint160 sqrtPriceX96, int24 tick, bool unlocked) = pool.slot0();
        assertEq(sqrtPriceX96, sqrtP);
        assertEq(tick, int24(0));
        assertTrue(unlocked);
    }

    function test_Initialize_RevertTwice() public {
        _initializeAtTick(0);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "already initialized"));
        pool.initialize(TickMath.getSqrtRatioAtTick(1));
    }

    /* ========== mint / tick alignment ========== */

    function test_Mint_RevertWhenNotInitialized() public {
        vm.expectRevert();
        pool.mint(lp, -60, 60, 1e18);
    }

    function test_Mint_RevertZeroAmount() public {
        _initializeAtTick(0);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "amount = 0"));
        pool.mint(lp, -60, 60, 0);
    }

    function test_Mint_RevertMisalignedTick() public {
        _initializeAtTick(0);
        vm.expectRevert();
        pool.mint(lp, -61, 60, 1e18);
    }

    function test_Mint_RevertTickOrder() public {
        _initializeAtTick(0);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "tickLower < tickUpper"));
        pool.mint(lp, 60, -60, 1e18);
    }

    function test_Mint_InRange_IncreasesLiquidityAndPullsTokens() public {
        _initializeAtTick(0);
        uint128 L = 1e18;
        uint256 b0Before = token0.balanceOf(lp);
        uint256 b1Before = token1.balanceOf(lp);

        pool.mint(lp, -60, 60, L);

        assertEq(pool.currentLiquidity(), L);
        assertGt(b0Before - token0.balanceOf(lp), 0);
        assertGt(b1Before - token1.balanceOf(lp), 0);
    }

    function test_Mint_PriceBelowRange_OnlyToken0() public {
        _initializeAtTick(0);
        uint128 L = 1e18;
        uint256 b0Before = token0.balanceOf(lp);
        uint256 b1Before = token1.balanceOf(lp);
        // tickCurrent < tickLower: only token0
        pool.mint(lp, 600, 1200, L);
        assertGt(b0Before - token0.balanceOf(lp), 0);
        assertEq(token1.balanceOf(lp), b1Before);
        assertEq(pool.currentLiquidity(), 0);
    }

    function test_Mint_PriceAboveRange_OnlyToken1() public {
        _initializeAtTick(0);
        uint128 L = 1e18;
        uint256 b0Before = token0.balanceOf(lp);
        uint256 b1Before = token1.balanceOf(lp);
        // tickCurrent >= tickUpper: only token1
        pool.mint(lp, -1200, -600, L);
        assertEq(token0.balanceOf(lp), b0Before);
        assertGt(b1Before - token1.balanceOf(lp), 0);
        assertEq(pool.currentLiquidity(), 0);
    }

    /* ========== burn + collect ========== */

    function test_Burn_AccruesTokensOwed() public {
        _initializeAtTick(0);
        uint128 L = 1e18;
        pool.mint(lp, -60, 60, L);
        uint256 pool0 = token0.balanceOf(address(pool));
        uint256 pool1 = token1.balanceOf(address(pool));

        pool.burn(-60, 60, L / 2);

        (uint128 liq,,,,) = _position(lp, -60, 60);
        assertEq(liq, L / 2);
        assertEq(pool.currentLiquidity(), L / 2);
        // Pool still holds principal until collect
        assertEq(token0.balanceOf(address(pool)), pool0);
        assertEq(token1.balanceOf(address(pool)), pool1);
    }

    function test_Collect_AfterBurn() public {
        _initializeAtTick(0);
        uint128 L = 1e18;
        pool.mint(lp, -60, 60, L);
        (uint128 o0Before, uint128 o1Before) = _owed(lp, -60, 60);

        pool.burn(-60, 60, L / 4);
        (uint128 o0After, uint128 o1After) = _owed(lp, -60, 60);
        assertGe(o0After, o0Before);
        assertGe(o1After, o1Before);

        uint256 recv0 = token0.balanceOf(lp);
        uint256 recv1 = token1.balanceOf(lp);
        pool.collect(lp, -60, 60, type(uint128).max, type(uint128).max);
        assertGe(token0.balanceOf(lp), recv0);
        assertGe(token1.balanceOf(lp), recv1);
    }

    /* ========== swap ========== */

    function test_Swap_ExactInputZeroForOne_MovesPriceAndTransfers() public {
        _initializeAtTick(0);
        pool.mint(lp, -600, 600, 1_000_000 ether);

        address trader = address(0xBEEF);
        token0.mint(trader, 100_000 ether);
        vm.startPrank(trader);
        token0.approve(address(pool), type(uint256).max);

        uint160 sqrtLimit = TickMath.getSqrtRatioAtTick(-120);
        int256 amountIn = 10 ether;
        uint256 t0Before = token0.balanceOf(trader);
        uint256 t1Before = token1.balanceOf(trader);

        pool.swap(trader, true, amountIn, sqrtLimit);

        assertLt(token0.balanceOf(trader), t0Before);
        assertGt(token1.balanceOf(trader), t1Before);
        (uint160 sqrtPriceX96, int24 tick,) = pool.slot0();
        assertLt(sqrtPriceX96, TickMath.getSqrtRatioAtTick(0));
        assertLt(tick, int24(0));
        vm.stopPrank();
    }

    function test_Swap_ExactInputOneForZero() public {
        _initializeAtTick(0);
        pool.mint(lp, -600, 600, 1_000_000 ether);

        address trader = address(0xCAFE);
        token1.mint(trader, 100_000 ether);
        vm.startPrank(trader);
        token1.approve(address(pool), type(uint256).max);

        uint160 sqrtLimit = TickMath.getSqrtRatioAtTick(120);
        uint256 t0Before = token0.balanceOf(trader);
        uint256 t1Before = token1.balanceOf(trader);

        pool.swap(trader, false, 10 ether, sqrtLimit);

        assertGt(token0.balanceOf(trader), t0Before);
        assertLt(token1.balanceOf(trader), t1Before);
        vm.stopPrank();
    }

    function test_Swap_RevertInvalidSqrtLimit() public {
        _initializeAtTick(0);
        pool.mint(lp, -60, 60, 1e18);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "invalid sqrt price limit"));
        pool.swap(lp, true, 1 ether, TickMath.getSqrtRatioAtTick(0));
    }

    function test_Swap_RevertZeroAmountSpecified() public {
        _initializeAtTick(0);
        vm.expectRevert();
        pool.swap(lp, true, 0, TickMath.MIN_SQRT_RATIO + 1);
    }

    function test_FeeGrowth_IncreasesAfterSwap() public {
        _initializeAtTick(0);
        pool.mint(lp, -600, 600, 1_000_000 ether);
        uint256 g0Before = pool.feeGrowthGlobal0X128();

        address trader = address(0xBEE);
        token0.mint(trader, 50_000 ether);
        vm.startPrank(trader);
        token0.approve(address(pool), type(uint256).max);
        pool.swap(trader, true, 5 ether, TickMath.getSqrtRatioAtTick(-120));
        vm.stopPrank();

        assertGe(pool.feeGrowthGlobal0X128(), g0Before);
    }

    /* ========== lock ========== */

    function test_Lock_RevertOnReentrancy() public {
        MockERC20 t1r = new MockERC20("T1R", "T1R");
        ReentrantERC20 t0r = new ReentrantERC20();
        for (uint256 i; i < 64 && address(t0r) >= address(t1r); i++) {
            t0r = new ReentrantERC20();
        }
        require(address(t0r) < address(t1r), "deploy order");

        CLAMM p2 = new CLAMM(address(t0r), address(t1r), FEE, TICK_SPACING);
        t0r.setPool(p2);
        t0r.mint(lp, 1e30);
        t1r.mint(lp, 1e30);
        t0r.approve(address(p2), type(uint256).max);
        t1r.approve(address(p2), type(uint256).max);
        p2.initialize(TickMath.getSqrtRatioAtTick(0));
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "locked"));
        p2.mint(lp, -60, 60, 1e18);
    }

    /* ========== helpers ========== */

    function _position(address owner, int24 tl, int24 tu)
        internal
        view
        returns (uint128 liquidity, uint256 fg0, uint256 fg1, uint128 owed0, uint128 owed1)
    {
        bytes32 key = keccak256(abi.encodePacked(owner, tl, tu));
        (liquidity, fg0, fg1, owed0, owed1) = pool.positions(key);
    }

    function _owed(address owner, int24 tl, int24 tu) internal view returns (uint128 o0, uint128 o1) {
        (,,, o0, o1) = _position(owner, tl, tu);
    }
}

/// @dev When the pool pulls token0 via transferFrom, attempts a nested mint to hit the reentrancy lock.
contract ReentrantERC20 is MockERC20 {
    CLAMM public pool;

    constructor() MockERC20("R0", "R0") {}

    function setPool(CLAMM p) external {
        pool = p;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        if (msg.sender == address(pool)) {
            pool.mint(from, -60, 60, 1);
        }
        _transferFromCore(from, to, amount);
        return true;
    }
}
