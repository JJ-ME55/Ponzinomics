// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PimdBaseTest} from "./PimdBase.t.sol";
import {PimdEngine} from "../../src/pimd/PimdEngine.sol";
import {console2, stdError} from "forge-std/Test.sol";

/// Arithmetic-lens proofs. Scratch audit file.
contract ZZArith is PimdBaseTest {
    uint256 internal startTs; // storage, so solc cannot inline block.timestamp across vm.warp

    function _give(address who, uint256 amt) internal {
        token.transfer(who, amt);
    }

    function _seedPot(uint256 amt) internal {
        imd.mint(address(this), amt);
        imd.approve(address(engine), type(uint256).max);
        engine.seed(amt);
    }

    // ---------------------------------------------------------------- A: tally() indexes past holders.length
    function test_A_prune_during_tally_bricks_the_epoch() public {
        _pastInit();
        _give(alice, 1_000_000e18);
        _give(bob, 1_000_000e18);
        _give(carol, 1_000_000e18);
        _seedPot(100_000e18);

        address[] memory a = new address[](3);
        a[0] = alice;
        a[1] = bob;
        a[2] = carol;
        engine.register(a);
        assertEq(engine.holderCount(), 3);

        vm.warp(block.timestamp + 3 minutes);
        vm.prank(keeper);
        engine.fire();
        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Tally));
        assertEq(engine.epochCount(), 3);
        uint256 quoted = engine.epochQuote();
        assertGt(quoted, 0);

        // carol drops below minBalance; prune is explicitly permitted during Tally
        vm.prank(carol);
        token.transfer(address(0xdead1), 1_000_000e18);
        address[] memory p = new address[](1);
        p[0] = carol;
        engine.prune(p);
        assertEq(engine.holderCount(), 2);
        assertEq(engine.epochCount(), 3); // <-- stale snapshot, never clamped

        // tally loops i < epochCount == 3 over a 2-element array
        vm.expectRevert(stdError.indexOOBError);
        vm.prank(keeper);
        engine.tally(500);

        // the epoch is wedged: phase is Tally forever, epochQuote is frozen out of the pot
        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Tally));
        assertEq(engine.epochQuote(), quoted);
        vm.expectRevert(PimdEngine.WrongPhase.selector);
        vm.prank(keeper);
        engine.fire();
        vm.expectRevert(PimdEngine.WrongPhase.selector);
        vm.prank(keeper);
        engine.pay(500);
        console2.log("frozen epochQuote (wei IMD)", quoted);
    }

    // ---------------------------------------------------------------- B: tips with zero holders
    function test_B_fire_tips_forever_with_no_holders() public {
        _pastInit();
        _seedPot(100_000e18);
        uint256 pot0 = engine.pot();
        uint256 keeper0 = imd.balanceOf(keeper);
        startTs = block.timestamp;
        for (uint256 i; i < 10; ++i) {
            vm.warp(startTs + (i + 1) * 121);
            vm.prank(keeper);
            engine.fire();
        }
        assertEq(engine.epoch(), 0); // no epoch ever opened
        assertEq(engine.totalDripped(), 0); // nobody was paid anything
        uint256 leaked = imd.balanceOf(keeper) - keeper0;
        console2.log("pot before          ", pot0);
        console2.log("pot after 10 fires  ", engine.pot());
        console2.log("keeper gained (wei) ", leaked);
        assertEq(pot0 - engine.pot(), leaked);
        assertGt(leaked, 0);
    }

    // ---------------------------------------------------------------- C: tips while totalWeight == 0
    function test_C_tips_paid_while_nobody_is_eligible() public {
        _pastInit();
        _give(alice, 1_000_000e18);
        _give(bob, 1_000_000e18);
        _seedPot(100_000e18);
        address[] memory a = new address[](2);
        a[0] = alice;
        a[1] = bob;
        engine.register(a);

        uint256 pot0 = engine.pot();
        uint256 keeper0 = imd.balanceOf(keeper);
        // the whole first hour: tierBps == 0 for everyone, so every epoch returns its quote
        startTs = block.timestamp;
        for (uint256 i; i < 25; ++i) {
            vm.warp(startTs + (i + 1) * 121);
            vm.prank(keeper);
            engine.fire();
            if (engine.phase() == PimdEngine.Phase.Tally) {
                vm.prank(keeper);
                engine.tally(500);
            }
        }
        assertEq(engine.totalDripped(), 0);
        uint256 leaked = imd.balanceOf(keeper) - keeper0;
        console2.log("pot lost (wei)      ", pot0 - engine.pot());
        console2.log("keeper gained (wei) ", leaked);
        assertEq(pot0 - engine.pot(), leaked);
        assertGt(leaked, 0);
    }

    // ---------------------------------------------------------------- D: _released bounds
    function test_D_released_never_exceeds_pot_and_rounds_up() public {
        _pastInit();
        _seedPot(1_000_000e18);
        // one second of elapsed time still releases something (rounds up)
        vm.warp(block.timestamp + 1);
        uint256 d1 = engine.dripPreview();
        console2.log("1s drip on 1e24 pot ", d1);
        assertGt(d1, 0);
        // a decade of elapsed time is clamped to maxCatchup (6h) and never exceeds the pot
        vm.warp(block.timestamp + 3650 days);
        uint256 dMax = engine.dripPreview();
        console2.log("clamped drip        ", dMax);
        assertLe(dMax, engine.pot());
        // 6h at 4%/15min: keep = 0.96^24 = 0.3754 -> ~62.46% of the pot
        assertApproxEqRel(dMax, 624_600e18, 0.001e18);
    }

    // ---------------------------------------------------------------- E: tax rounds to zero on tiny swaps
    function test_E_small_swaps_pay_no_tax() public {
        _pastInit();
        _pastLaunchCap();
        uint256 taxed0 = hook.totalTaxed();
        _buy(alice, 41); // 41 * 240 / 10000 == 0
        console2.log("tax on a 41 wei buy ", hook.totalTaxed() - taxed0);
        assertEq(hook.totalTaxed(), taxed0);
    }

    // ---------------------------------------------------------------- F: team keeps the split dust
    function test_F_split_dust_goes_to_team() public {
        _pastInit();
        _pastLaunchCap();
        uint256 h0 = hook.holdersOwed();
        uint256 t0 = hook.teamOwed();
        _buy(alice, 10_000e18);
        uint256 fee = hook.totalTaxed();
        uint256 dh = hook.holdersOwed() - h0;
        uint256 dt = hook.teamOwed() - t0;
        console2.log("fee     ", fee);
        console2.log("holders ", dh);
        console2.log("team    ", dt);
        assertEq(dh + dt, fee); // no claim is created or lost
        assertEq(dh, fee * 7500 / 10000);
    }

    // ---------------------------------------------------------------- G: streak blend dilution is exact
    function test_G_blend_dilutes_age_proportionally() public {
        _pastInit();
        _give(alice, 1_000_000e18);
        _seedPot(100_000e18);
        _register(alice);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 14 days);
        // alice doubles her bag; the blend should halve her age
        _give(alice, 1_000_000e18);
        _runEpoch();
        (,, uint256 ss, uint256 tier,) = engine.holderInfo(alice);
        console2.log("age after doubling  ", block.timestamp - ss);
        console2.log("tier bps            ", tier);
        assertApproxEqAbs(block.timestamp - ss, 7 days, 2);
        // exactly 7 days lands in the 2x band, because the ladder tests `age < 7 days`
        assertEq(tier, 20_000);
    }
}
