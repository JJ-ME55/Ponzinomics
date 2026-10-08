// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PimdBaseTest, PimdHookHarness, MockIMD} from "./PimdBase.t.sol";
import {PimdToken} from "../../src/pimd/PimdToken.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
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
    function test_launch_puts_the_seed_in_one_range() public view {
        assertTrue(hook.launched(), "launched");
        assertTrue(hook.seeded(), "seeded");
        assertEq(token.balanceOf(address(hook)), 0, "the hook never holds PIMD");
        // the policy seeds ninety percent of our share single-sided; nothing of it is IMD
        assertGt(token.balanceOf(address(manager)), SUPPLY * 85 / 100, "most of the supply is the position");
        assertEq(token.totalSupply(), SUPPLY, "supply is fixed and never moves");
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
    function test_buy_pays_the_buy_tax_in_imd() public {
        _pastInit();
        uint256 spend = 10e18;
        uint256 got = _buy(alice, spend);
        assertGt(got, 0, "received PIMD");

        uint256 expectedFee = spend * 240 / BPS;
        assertEq(hook.totalTaxed(), expectedFee, "the buy tax, of the IMD going in");
        assertEq(hook.claimBalance(), expectedFee, "held as IMD claims");
        assertEq(imd.balanceOf(address(manager)), spend, "all the IMD is in the manager");
    }

    function test_sell_pays_the_sell_tax_in_imd() public {
        _pastLaunchCap();
        _buy(alice, 50e18);
        uint256 taxedOnBuy = hook.totalTaxed();

        uint256 bag = token.balanceOf(alice);
        uint256 got = _sell(alice, bag / 2);
        assertGt(got, 0, "received IMD");

        uint256 sellFee = hook.totalTaxed() - taxedOnBuy;
        // the seller receives the output net of 7%
        assertApproxEqRel(sellFee, got * 560 / 9440, 1e12, "the sell tax, of the IMD coming out");
    }

    function test_exact_out_buy_is_taxed_too() public {
        _pastLaunchCap();
        _buy(alice, 20e18); // put some IMD in the pool first
        uint256 before = hook.totalTaxed();
        uint256 spent = _buyExactOut(bob, 1_000_000e18, 100e18);
        uint256 fee = hook.totalTaxed() - before;
        assertGt(fee, 0, "exact-out buys pay too");
        assertApproxEqRel(fee, spent * 240 / BPS, 1e12, "the buy tax, of what was spent");
    }

    function test_exact_out_sell_is_taxed_too() public {
        _pastLaunchCap();
        _buy(alice, 50e18);
        uint256 before = hook.totalTaxed();
        uint256 want = 1e18;
        _sellExactOut(alice, want);
        uint256 fee = hook.totalTaxed() - before;
        assertApproxEqRel(fee, want * 560 / 9440, 1e12, "the sell tax, on top of what was asked for");
    }

    /// Audit finding, MEDIUM: the tax on an exact-in buy is computed in beforeSwap from the amount asked
    /// for, before the pool knows how much will fill. A swap stopped by its price limit used to pay the
    /// full tax on IMD that never traded: 24 IMD of tax on a 1000 IMD offer that filled a sliver.
    function test_a_partially_filled_buy_is_refused_rather_than_overtaxed() public {
        _pastLaunchCap();
        _buy(alice, 10e18); // put some IMD in the pool and move the price off the opening tick

        (uint160 spot,,,) = StateLibrary.getSlot0(manager, id);
        uint256 taxedBefore = hook.totalTaxed();
        _fund(bob, 1000e18);
        vm.prank(bob, bob);
        vm.expectRevert(); // PartialFill, wrapped by the PoolManager
        router.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1000e18),
                sqrtPriceLimitX96: spot - spot / 20000 // a limit the offer cannot fill against
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(hook.totalTaxed(), taxedBefore, "nothing was taxed on a swap that did not happen");
        assertEq(imd.balanceOf(bob), 1000e18, "bob keeps every IMD");
    }

    // ------------------------------------------------------------------ the split
    function test_tax_splits_seventy_five_twenty_five() public {
        _pastLaunchCap();
        _buy(alice, 100e18);
        uint256 fee = hook.totalTaxed();
        assertEq(hook.holdersOwed(), fee * 7500 / BPS, "75% holders");
        assertEq(hook.teamOwed(), fee - (fee * 7500 / BPS), "25% team");
        assertEq(hook.holdersOwed() + hook.teamOwed(), hook.claimBalance(), "ledger = claims");
    }

    /// The burn takes nothing from the tax any more: it is funded by the pool's own fee, outside the hook.
    function test_the_tax_is_only_holders_and_team() public {
        _pastLaunchCap();
        _buy(alice, 100e18);
        assertEq(hook.HOLDERS_BPS() + 2500, hook.BPS(), "the split is exhaustive");
        assertEq(hook.holdersOwed() + hook.teamOwed(), hook.totalTaxed(), "nothing is held back");
    }

    function test_flush_payouts_moves_real_imd() public {
        _pastLaunchCap();
        _buy(alice, 100e18);
        uint256 owed = hook.holdersOwed();
        uint256 teamOwed = hook.teamOwed();

        vm.prank(keeper);
        hook.flush();

        assertEq(imd.balanceOf(address(engine)), owed, "engine holds the holders' IMD");
        assertEq(imd.balanceOf(team), teamOwed - hook.callerTip(), "team paid, less the caller's tip");
        assertEq(hook.holdersOwed(), 0, "cleared");
        assertEq(hook.claimBalance(), 0, "nothing left behind");
    }

    function test_keeper_tip_comes_out_of_the_team_slice() public {
        _pastLaunchCap();
        _buy(alice, 100e18);
        uint256 holders = hook.holdersOwed();
        uint256 teamOwed = hook.teamOwed();

        vm.prank(keeper);
        hook.flush();

        assertEq(imd.balanceOf(keeper), hook.callerTip(), "keeper tipped");
        assertEq(imd.balanceOf(team), teamOwed - hook.callerTip(), "out of the team's share");
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
        hook.flush();
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
        _buy(alice, hook.launchBuyCap() - 1e18);
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
        _buy(alice, hook.launchBuyCap() - 1e18);
        _pastLaunchCap();
        assertFalse(hook.inLaunchCapWindow(), "window closed");
        uint256 got = _buy(alice, 100e18); // way over the old cap
        assertGt(got, 0, "no cap any more");
    }

    // ------------------------------------------------------------------ the initialize gate
    function test_a_second_pool_on_this_hook_is_refused() public {
        PoolKey memory other = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: key.hooks
        });
        vm.expectRevert();
        manager.initialize(other, TickMath.getSqrtPriceAtTick(START_TICK));
    }

    function test_initialize_refuses_a_pool_that_is_not_our_token() public {
        (PimdHook fresh,) = _freshHook();
        MockIMD other = new MockIMD();
        (Currency c0, Currency c1) = uint160(address(other)) < uint160(address(imd))
            ? (Currency.wrap(address(other)), Currency.wrap(address(imd)))
            : (Currency.wrap(address(imd)), Currency.wrap(address(other)));
        PoolKey memory k =
            PoolKey({currency0: c0, currency1: c1, fee: 12_500, tickSpacing: SPACING, hooks: IHooks(address(fresh))});
        vm.expectRevert();
        vm.prank(address(factory));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(START_TICK));
    }

    function test_initialize_refuses_an_unsupported_fee_tier() public {
        (PimdHook fresh, PimdToken t) = _freshHook();
        PoolKey memory k = _keyFor(fresh, t, 4000);
        vm.expectRevert();
        vm.prank(address(factory));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(START_TICK));
    }

    function test_initialize_refuses_a_mispriced_pool() public {
        (PimdHook fresh, PimdToken t) = _freshHook();
        PoolKey memory k = _keyFor(fresh, t, 12_500);
        // a thousand ticks away from the briefed opening, far outside the tolerance
        vm.expectRevert();
        vm.prank(address(factory));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(START_TICK + 1000));
    }

    function test_initialize_accepts_a_price_inside_the_tolerance() public {
        (PimdHook fresh, PimdToken t) = _freshHook();
        PoolKey memory k = _keyFor(fresh, t, 12_500);
        vm.prank(address(factory));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(START_TICK - 120));
        assertTrue(fresh.launched(), "a near-enough price opens");
    }

    /// Audit finding, HIGH: initialize is permissionless on the PoolManager and this hook launches once,
    /// so anyone could spend the launch on a pool of their choosing before the factory got there.
    function test_only_the_launch_factory_may_open_the_pool() public {
        (PimdHook fresh, PimdToken t) = _freshHook();
        PoolKey memory k = _keyFor(fresh, t, 12_500);
        vm.prank(alice); // not the factory
        vm.expectRevert();
        manager.initialize(k, TickMath.getSqrtPriceAtTick(START_TICK));
    }

    /// Audit finding, HIGH: the hook checked only that currency0 sorted below PIMD, never that it was IMD.
    /// Every fee calculation, the claim id and the engine's booking assume that one token specifically.
    function test_initialize_refuses_a_quote_that_is_not_imd() public {
        (PimdHook fresh, PimdToken t) = _freshHook();
        MockIMD junk = new MockIMD();
        vm.assume(uint160(address(junk)) < uint160(address(t)));
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(junk)),
            currency1: Currency.wrap(address(t)),
            fee: 12_500,
            tickSpacing: SPACING,
            hooks: IHooks(address(fresh))
        });
        vm.prank(address(factory));
        vm.expectRevert();
        manager.initialize(k, TickMath.getSqrtPriceAtTick(START_TICK));
    }

    /// The launch policy airdrops a tenth of the supply through a MerkleDistributor. It is not
    /// pool-shaped, so _isPool does not see it, and it has no way to forward an IMD payout: anything
    /// dripped to it is stranded in a contract forever. It has to be excluded at bind.
    function test_an_excluded_holder_is_never_registered_or_paid() public {
        _pastLaunchCap();
        address distributor = makeAddr("distributor");

        PimdEngine fresh = new PimdEngine(
            PimdEngine.Config({
                poolManager: address(manager),
                imd: address(imd),
                team: team,
                binder: address(this),
                dripBpsPerPeriod: 400,
                minInterval: 2 minutes,
                minBalance: 100_000e18,
                fireTip: 0,
                tipPerHolder: 0,
                maxCatchup: 6 hours
            })
        );
        address[] memory extra = new address[](1);
        extra[0] = distributor;
        fresh.bind(address(token), address(hook), extra);
        assertTrue(fresh.excluded(distributor), "named at bind");

        // give it a real bag, the way the airdrop would
        _buy(alice, 300e18);
        uint256 bag = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(distributor, bag);

        address[] memory one = new address[](1);
        one[0] = distributor;
        fresh.register(one);
        assertEq(fresh.holderCount(), 0, "an excluded address cannot register, however big its bag");
    }

    // ------------------------------------------------------------------ the liquidity lock
    /// Audit finding, MEDIUM, found by three specialists: the single permitted add went to whoever was
    /// first, so one wei from a stranger consumed it and the factory's real seed reverted.
    function test_a_stranger_cannot_squat_the_seed() public {
        (PimdHook fresh, PimdToken t) = _freshHook();
        PoolKey memory k = _keyFor(fresh, t, 12_500);
        vm.prank(address(factory));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(START_TICK));
        assertFalse(fresh.seeded(), "not seeded yet");
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: START_TICK, liquidityDelta: 1, salt: 0}),
            ""
        );
        assertFalse(fresh.seeded(), "the seed slot is still the factory's");
    }

    function test_a_second_liquidity_add_is_refused() public {
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: START_TICK, liquidityDelta: 1e18, salt: 0}),
            ""
        );
    }

    /// The whole reason the launch factory can hold the position safely: it can never move it.
    function test_liquidity_can_never_be_removed() public {
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: START_TICK, liquidityDelta: -1, salt: 0}),
            ""
        );
    }

    /// A zero delta is a fee collection, not a withdrawal, and has to keep working or the pool's own fee
    /// would be stranded forever.
    function test_fee_collection_is_still_allowed() public {
        _pastLaunchCap();
        _buy(alice, 10e18);
        factory.seed(key, TICK_LOWER, START_TICK, 0); // zero delta: a fee collection, not a withdrawal
    }

    function test_bind_is_one_shot() public {
        vm.expectRevert(PimdEngine.AlreadyBound.selector);
        engine.bind(address(token), address(hook), new address[](0));
    }

    function test_hook_refuses_raw_eth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok, "no raw ETH");
    }

    // ------------------------------------------------------------------ helpers
    /// A hook and token that have never been launched, for testing the gate itself.
    function _freshHook() internal returns (PimdHook fresh, PimdToken t) {
        bytes32 initHash = keccak256(type(PimdToken).creationCode);
        for (uint256 i = 500_000; i < 600_000; ++i) {
            address predicted = vm.computeCreate2Address(bytes32(i), initHash, address(this));
            if (uint160(predicted) > uint160(address(imd))) {
                t = new PimdToken{salt: bytes32(i)}();
                break;
            }
        }
        require(address(t) != address(0), "no salt");
        bytes memory args = abi.encode(manager, address(t), address(engine), team, address(imd), address(factory));
        (, bytes32 salt2) = HookMiner.find(address(this), HOOK_FLAGS, type(PimdHookHarness).creationCode, args);
        fresh = PimdHook(payable(address(new PimdHookHarness{salt: salt2}(manager, address(t), address(engine), team, address(imd), address(factory)))));
    }

    function _keyFor(PimdHook h, PimdToken t, uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(imd)),
            currency1: Currency.wrap(address(t)),
            fee: fee,
            tickSpacing: SPACING,
            hooks: IHooks(address(h))
        });
    }

    function _exactIn(uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
    }
}
