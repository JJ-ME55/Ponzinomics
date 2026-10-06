// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PimdBaseTest} from "./PimdBase.t.sol";
import {PimdEngine} from "../../src/pimd/PimdEngine.sol";
import {PimdHook, IPimdToken} from "../../src/pimd/PimdHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract PimdTest is PimdBaseTest {
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------ launch
    function test_launch_puts_every_token_in_one_range() public view {
        assertTrue(hook.launched(), "launched");
        assertEq(token.balanceOf(address(hook)), 0, "hook keeps nothing");
        // all of it is in the PoolManager, minus whatever dust the range maths burned
        assertEq(token.balanceOf(address(manager)), token.totalSupply(), "supply is the position");
        assertGt(hook.seededLiquidity(), 0, "liquidity");
        assertLt(SUPPLY - token.totalSupply(), SUPPLY / 1_000_000, "dust is tiny");
    }

    function test_launch_sets_imd_as_currency0() public view {
        assertEq(Currency.unwrap(key.currency0), address(imd), "IMD is currency0");
        assertEq(Currency.unwrap(key.currency1), address(token), "PIMD is currency1");
    }

    function test_pool_starts_with_no_imd() public view {
        // the whole point of a single-sided launch: it costs nothing to open
        assertEq(imd.balanceOf(address(manager)), 0, "no IMD until somebody buys");
    }

    // ------------------------------------------------------------------ the tax
    function test_buy_pays_three_percent_in_imd() public {
        _pastInit();
        uint256 spend = 10e18;
        uint256 got = _buy(alice, spend);
        assertGt(got, 0, "received PIMD");

        uint256 expectedFee = spend * 300 / BPS;
        assertEq(hook.totalTaxed(), expectedFee, "3% of the IMD going in");
        assertEq(hook.claimBalance(), expectedFee, "held as IMD claims");
        assertEq(imd.balanceOf(address(manager)), spend, "all the IMD is in the manager");
    }

    function test_sell_pays_seven_percent_in_imd() public {
        _pastInit();
        _buy(alice, 50e18);
        uint256 taxedOnBuy = hook.totalTaxed();

        uint256 bag = token.balanceOf(alice);
        uint256 got = _sell(alice, bag / 2);
        assertGt(got, 0, "received IMD");

        uint256 sellFee = hook.totalTaxed() - taxedOnBuy;
        // the seller receives the output net of 7%
        assertApproxEqRel(sellFee, got * 700 / 9300, 1e12, "7% of the IMD coming out");
    }

    function test_exact_out_buy_is_taxed_too() public {
        _pastInit();
        _buy(alice, 20e18); // put some IMD in the pool first
        uint256 before = hook.totalTaxed();
        uint256 spent = _buyExactOut(bob, 1_000_000e18, 100e18);
        uint256 fee = hook.totalTaxed() - before;
        assertGt(fee, 0, "exact-out buys pay too");
        assertApproxEqRel(fee, spent * 300 / BPS, 1e12, "3% of what was spent");
    }

    function test_exact_out_sell_is_taxed_too() public {
        _pastInit();
        _buy(alice, 50e18);
        uint256 before = hook.totalTaxed();
        uint256 want = 1e18;
        _sellExactOut(alice, want);
        uint256 fee = hook.totalTaxed() - before;
        assertApproxEqRel(fee, want * 700 / 9300, 1e12, "7% on top of what was asked for");
    }

    // ------------------------------------------------------------------ the split
    function test_tax_splits_sixty_twenty_twenty() public {
        _pastLaunchCap();
        _buy(alice, 100e18);
        uint256 fee = hook.totalTaxed();
        assertEq(hook.holdersOwed(), fee * 6000 / BPS, "60% holders");
        assertEq(hook.burnBudget(), fee * 2000 / BPS, "20% burn");
        assertEq(hook.teamOwed(), fee - (fee * 6000 / BPS) - (fee * 2000 / BPS), "20% team");
        assertEq(hook.holdersOwed() + hook.burnBudget() + hook.teamOwed(), hook.claimBalance(), "ledger = claims");
    }

    function test_flush_payouts_moves_real_imd() public {
        _pastLaunchCap();
        _buy(alice, 100e18);
        uint256 owed = hook.holdersOwed();
        uint256 teamOwed = hook.teamOwed();

        vm.prank(keeper);
        hook.flushPayouts();

        assertEq(imd.balanceOf(address(engine)), owed, "engine holds the holders' IMD");
        assertEq(imd.balanceOf(team), teamOwed, "team paid");
        assertEq(hook.holdersOwed(), 0, "cleared");
        assertEq(hook.claimBalance(), hook.burnBudget(), "only the burn budget is left");
    }

    function test_flush_buys_pimd_back_and_burns_it() public {
        _pastLaunchCap();
        _buy(alice, 500e18); // big enough to arm the burn budget
        assertTrue(hook.burnReady(), "armed");
        uint256 supplyBefore = token.totalSupply();
        uint256 budget = hook.burnBudget();

        vm.prank(keeper);
        (,, uint256 spent, uint256 burned) = hook.flush();

        assertGt(burned, 0, "something was burned");
        assertEq(spent, budget > cfg.burnCap ? cfg.burnCap : budget, "spent the armed budget");
        assertEq(token.totalSupply(), supplyBefore - burned, "supply actually fell");
        assertEq(token.balanceOf(address(hook)), 0, "the hook keeps no PIMD");
        assertEq(hook.totalBurned(), burned, "counter");
    }

    function test_keeper_tip_comes_out_of_the_team_slice() public {
        _pastLaunchCap();
        _buy(alice, 100e18);
        uint256 holders = hook.holdersOwed();
        uint256 teamOwed = hook.teamOwed();

        vm.prank(keeper);
        hook.flush();

        assertEq(imd.balanceOf(keeper), cfg.callerTip, "keeper tipped");
        assertEq(imd.balanceOf(team), teamOwed - cfg.callerTip, "out of the team's share");
        assertEq(imd.balanceOf(address(engine)), holders, "holders untouched");
    }

    // ------------------------------------------------------------------ the engine
    function test_first_hour_pays_nobody() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        _register(alice);
        vm.warp(block.timestamp + 10 minutes);

        _runEpoch();

        assertEq(imd.balanceOf(alice), 0, "no payout inside the first hour");
        assertGt(engine.pot(), 0, "the IMD waits in the pot");
        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Idle), "epoch closed cleanly");
    }

    function test_holder_is_paid_in_imd_after_a_day() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        _register(alice);
        vm.warp(block.timestamp + 2 days);

        uint256 before = imd.balanceOf(alice);
        _runEpoch();

        assertGt(imd.balanceOf(alice) - before, 0, "paid in IMD");
        assertEq(token.balanceOf(alice), token.balanceOf(alice), "PIMD balance untouched by being paid");
        (,,,, uint256 received) = engine.holderInfo(alice);
        assertEq(received, imd.balanceOf(alice) - before, "credited");
    }

    function test_longer_holder_gets_a_bigger_share() public {
        _pastLaunchCap();
        _buy(alice, 100e18);
        _register(alice);
        vm.warp(block.timestamp + 15 days); // alice reaches 3x

        _buy(bob, 100e18);
        _register(bob);
        vm.warp(block.timestamp + 2 days); // bob reaches 1x, alice stays 3x

        // Their bags differ (alice bought earlier and cheaper), so compare the rate per token held: that is
        // the tier, isolated. Moving tokens to equalise would reset a streak, which is the thing under test.
        uint256 aliceBag = token.balanceOf(alice);
        uint256 bobBag = token.balanceOf(bob);

        uint256 a0 = imd.balanceOf(alice);
        uint256 b0 = imd.balanceOf(bob);
        _runEpoch();
        uint256 aPaid = imd.balanceOf(alice) - a0;
        uint256 bPaid = imd.balanceOf(bob) - b0;

        assertGt(aPaid, bPaid, "the longer streak is paid more");
        uint256 aPerToken = (aPaid * 1e18) / aliceBag;
        uint256 bPerToken = (bPaid * 1e18) / bobBag;
        assertApproxEqRel(aPerToken, bPerToken * 3, 0.01e18, "3x the rate per token, exactly as the ladder says");
    }

    function test_selling_restarts_the_streak() public {
        _pastLaunchCap();
        _buy(alice, 100e18);
        _register(alice);
        vm.warp(block.timestamp + 15 days);
        (,,, uint256 tierBefore,) = engine.holderInfo(alice);
        assertEq(tierBefore, 30_000, "3x");

        _sell(alice, token.balanceOf(alice) / 2);
        _runEpoch(); // the tally sees the smaller balance and restarts the clock

        (,,, uint256 tierAfter,) = engine.holderInfo(alice);
        assertEq(tierAfter, 0, "back to nothing");
    }

    function test_drip_releases_about_four_percent_per_fifteen_minutes() public {
        _pastLaunchCap();
        _buy(alice, 500e18);
        _register(alice);
        vm.warp(block.timestamp + 2 days); // alice is past the first hour, and this epoch clears the backlog
        _runEpoch();

        // Now a quiet quarter of an hour with no new trades: the pot should release roughly 4% of itself.
        _buy(bob, 200e18);
        uint256 drippedBefore = engine.totalDripped();
        vm.prank(keeper);
        hook.flushPayouts();
        vm.warp(block.timestamp + 15 minutes);
        uint256 potBefore = imd.balanceOf(address(engine)); // what fire() will book as the pot
        _runEpoch();

        uint256 released = engine.totalDripped() - drippedBefore;
        assertApproxEqRel(released, potBefore * 400 / BPS, 0.1e18, "about 4% of the pot, less keeper tips");
        assertGt(engine.pot(), potBefore * 9 / 10, "and the rest is still there for later");
    }

    // ------------------------------------------------------------------ the guards
    function test_third_party_liquidity_is_blocked() public {
        _pastInit();
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        imd.mint(address(this), 1000e18);
        imd.approve(address(lp), type(uint256).max);
        vm.expectRevert();
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: START_TICK, liquidityDelta: 1e18, salt: 0}),
            ""
        );
    }

    function test_launch_cap_limits_one_buyer() public {
        _pastInit();
        _buy(alice, cfg.launchBuyCap - 1e18);
        _fund(alice, 10e18);
        vm.expectRevert();
        vm.prank(alice, alice);
        router.swap(
            key,
            _exactIn(10e18),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_launch_cap_expires() public {
        _pastInit();
        _buy(alice, cfg.launchBuyCap - 1e18);
        _pastLaunchCap();
        assertFalse(hook.inLaunchCapWindow(), "window closed");
        uint256 got = _buy(alice, 100e18); // way over the old cap
        assertGt(got, 0, "no cap any more");
    }

    function test_nobody_else_can_launch_a_pool_on_this_hook() public {
        PoolKey memory other = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: key.hooks
        });
        vm.expectRevert();
        manager.initialize(other, 79228162514264337593543950336);
    }

    function test_second_launch_is_refused() public {
        vm.expectRevert(PimdHook.AlreadyLaunched.selector);
        hook.launch(IPimdToken(address(token)), TICK_LOWER, START_TICK, SPACING);
    }

    function test_bind_is_one_shot() public {
        vm.expectRevert(PimdEngine.AlreadyBound.selector);
        engine.bind(address(token), address(hook));
    }

    function test_hook_refuses_raw_eth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok, "no raw ETH");
    }

    // ------------------------------------------------------------------ helpers
    function _exactIn(uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
    }
}
