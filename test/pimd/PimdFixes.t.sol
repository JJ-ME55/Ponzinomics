// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PimdBaseTest} from "./PimdBase.t.sol";
import {PimdEngine} from "../../src/pimd/PimdEngine.sol";
import {PimdHook} from "../../src/pimd/PimdHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

/// Drives register/prune from inside a PoolManager unlock, which is where a flash borrower sits.
contract UnlockedCaller is IUnlockCallback {
    IPoolManager immutable manager;
    PimdEngine immutable engine;
    uint8 public what; // 1 register, 2 prune
    address public subject;

    constructor(IPoolManager m, PimdEngine e) {
        manager = m;
        engine = e;
    }

    function run(uint8 w, address who) external {
        what = w;
        subject = who;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        address[] memory a = new address[](1);
        a[0] = subject;
        if (what == 1) engine.register(a);
        if (what == 2) engine.prune(a);
        return "";
    }
}

/// Every test here corresponds to a finding from the adversarial review. Each one is written to fail if its
/// fix is removed, because the review's main lesson was that the three tests guarding the liquidity lock all
/// passed for reasons unrelated to the lock.
contract PimdFixesTest is PimdBaseTest {
    // ================================================================= the brick
    /// Review C1. `fire` freezes `epochCount`; the whole-set `tally` walks `holders` to that snapshot;
    /// `prune` used to be allowed during Tally and does swap-and-pop. One permissionless call shortened the
    /// array under the running tally, so the loop read past the end and reverted for ever, with `fire` and
    /// `pay` both refusing to run outside their phase. There was no way back and no owner to find one.
    function test_prune_cannot_brick_a_running_epoch() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        _buy(bob, 200e18);
        _buy(carol, 200e18);
        _register(alice);
        _register(bob);
        _register(carol);
        // bob's bag goes away, so he is genuinely prunable and the call would do real work
        uint256 bobBag = token.balanceOf(bob);
        vm.prank(bob);
        token.transfer(alice, bobBag);

        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(keeper);
        engine.fire();
        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Tally), "mid-epoch");

        address[] memory one = new address[](1);
        one[0] = bob;
        vm.expectRevert(PimdEngine.WrongPhase.selector);
        engine.prune(one);

        // and the epoch still completes, which is the thing the brick took away
        vm.startPrank(keeper);
        engine.tally(500);
        engine.pay(500);
        vm.stopPrank();
        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Idle), "the epoch finished");
    }

    function test_prune_is_refused_during_pay_too() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        _register(alice);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.startPrank(keeper);
        engine.fire();
        engine.tally(500);
        vm.stopPrank();
        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Pay), "paying");

        address[] memory one = new address[](1);
        one[0] = alice;
        vm.expectRevert(PimdEngine.WrongPhase.selector);
        engine.prune(one);
    }

    function test_prune_still_works_between_epochs() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        _buy(bob, 200e18);
        _register(alice);
        _register(bob);
        assertEq(engine.holderCount(), 2, "two registered");

        uint256 bag = token.balanceOf(bob);
        vm.prank(bob);
        token.transfer(alice, bag);

        address[] memory one = new address[](1);
        one[0] = bob;
        engine.prune(one); // Idle
        assertEq(engine.holderCount(), 1, "the empty wallet is gone");
    }

    // ================================================================= the free flash loan
    /// Review C3. `register` and `prune` were the only state-changing entry points with neither guard, so
    /// `PoolManager.take` handed an attacker the pool's entire PIMD balance for the length of one callback:
    /// enough to register unlimited addresses, or to prune, at no capital cost.
    function test_register_refuses_while_the_pool_is_unlocked() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        UnlockedCaller u = new UnlockedCaller(manager, engine);
        vm.expectRevert();
        u.run(1, alice);
        assertEq(engine.holderCount(), 0, "nothing registered from inside an unlock");
    }

    function test_prune_refuses_while_the_pool_is_unlocked() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        _register(alice);
        UnlockedCaller u = new UnlockedCaller(manager, engine);
        vm.expectRevert();
        u.run(2, alice);
    }

    // ================================================================= the gas ceiling
    /// Review C2. The whole-set tally has no bound unless registration enforces one, and nothing could
    /// shrink an over-large set mid-epoch, so the first `fire` past the gas ceiling wedged the engine
    /// permanently. Registration is permissionless, so anyone could cause it for the price of the gas.
    function test_the_holder_set_is_bounded() public {
        _pastLaunchCap();
        address[] memory list = new address[](3);
        for (uint256 i; i < 3; ++i) {
            list[i] = address(uint160(0x20000 + i));
            _buy(list[i], 20e18);
            _register(list[i]);
        }
        assertEq(engine.holderCount(), 3, "at the bound");

        // A full set skips the address rather than reverting the batch, so that `_reclaimSlot`'s cursor
        // write survives the call. The bound is still absolute: all three entries are live, so there is
        // nothing to reclaim and nothing gets in.
        address extra = address(uint160(0x30000));
        _buy(extra, 20e18);
        address[] memory one = new address[](1);
        one[0] = extra;
        engine.register(one);
        assertEq(engine.holderCount(), 3, "still at the bound");
        (bool registered,,,,) = engine.holderInfo(extra);
        assertFalse(registered, "and the extra address did not get in");
    }

    // ================================================================= audit over 0fc1ff2
    /// Finding 1, medium. `fire` pulls the hook through `flush`, which pays a caller tip out of the team's
    /// slice to msg.sender -- and on that path msg.sender is the engine, which books whatever it receives
    /// as holder income. So every fire quietly moved up to 20% of the team's accrued slice into the
    /// holders' pot, while the hook's `totalToTeam` still recorded it as paid to the team.
    function test_fire_does_not_tip_the_engine_out_of_the_team_slice() public {
        _pastLaunchCap();
        _buy(carol, 300e18);
        _register(carol);
        _buy(alice, 1e18);

        uint256 owedTeam = hook.teamOwed();
        uint256 owedHolders = hook.holdersOwed();
        assertGt(owedTeam, 0, "the team is owed something");
        uint256 teamBefore = imd.balanceOf(team);

        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(keeper);
        engine.fire();

        assertEq(imd.balanceOf(team) - teamBefore, owedTeam, "the team did not receive its whole slice");
        assertEq(engine.totalIncome(), owedHolders, "and nothing extra was booked as holder income");
        assertEq(hook.totalToTeam(), owedTeam, "stats agree with the balance");
    }

    /// Finding 2, medium. A slot was claimed on the balance of one instant and then held for ever, so one
    /// minimum bag walked through fresh addresses filled the set and locked everybody out of registering,
    /// permanently, with no owner to undo it. A full set now gives up a slot held by an entry that no
    /// longer qualifies, so padding is a cost the attacker keeps paying rather than one they pay once.
    function test_a_walked_bag_cannot_lock_the_holder_set_for_ever() public {
        _pastLaunchCap();
        _buy(alice, 300e18);
        uint256 bag = token.balanceOf(alice);

        // the attacker walks one bag through fresh addresses, registering each while it holds it
        address[] memory ghosts = new address[](3); // _maxHolders() is 3 here
        address prev = alice;
        for (uint256 i; i < 3; ++i) {
            ghosts[i] = address(uint160(0xDEAD00 + i));
            vm.prank(prev);
            token.transfer(ghosts[i], bag);
            _register(ghosts[i]);
            prev = ghosts[i];
        }
        assertEq(engine.holderCount(), 3, "the set is full of ghosts");
        assertLt(token.balanceOf(ghosts[0]), engine.minBalance(), "and the first one is empty");

        // an honest holder with a real bag can still get in, by reclaiming a dead slot
        address honest = makeAddr("honest");
        vm.prank(prev);
        token.transfer(honest, bag);
        _register(honest);
        (bool registered,,,,) = engine.holderInfo(honest);
        assertTrue(registered, "the honest holder got a slot");
        assertEq(engine.holderCount(), 3, "and the set is still bounded");
    }

    /// Finding 3, medium. The launch factory owns the only liquidity position, so the pool's own 1.25% fee
    /// accrues to it in PIMD. Left out of the exclusion list, anyone could register it and strand a share
    /// of every drip in a contract that cannot forward IMD, with prune unable to touch it.
    function test_the_launch_factory_and_precompiles_can_never_register() public {
        _pastLaunchCap();
        address fac = hook.launchFactory();
        assertTrue(engine.excluded(fac), "the launch factory is excluded at bind");

        _buy(alice, 300e18);
        uint256 bag = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(fac, bag);
        _register(fac);
        (bool facReg,,,,) = engine.holderInfo(fac);
        assertFalse(facReg, "the factory did not register");

        // and a precompile, which answers no probe and can forward nothing, is refused on its own account
        address pre = address(uint160(1));
        vm.prank(fac);
        token.transfer(pre, bag);
        assertGe(token.balanceOf(pre), engine.minBalance(), "the precompile holds a registerable bag");
        _register(pre);
        (bool preReg,,,,) = engine.holderInfo(pre);
        assertFalse(preReg, "the precompile did not register");
        assertEq(engine.holderCount(), 0, "nothing got in");
    }

    /// Finding 7, low. maxHolders exists so the whole-set tally fits one transaction. The budget is not the
    /// 2^50 in the block header, which is an Arbitrum placeholder, but ArbOS's maxTxGasLimit: 32,000,000 on
    /// this chain. At the measured cost a bound of 1,200 could never have been weighed.
    /// Round 2 finding 7. The budget is ArbOS's maxTxGasLimit, 32,000,000 on this chain, not the 2^50
    /// placeholder in the block header. And the cost that matters is the one with balances moving between
    /// tallies -- 37-38k a weighted holder -- not the 34.6k Gas.t.sol measures when nothing has changed,
    /// which is what put the first version of this ceiling at an unweighable 900.
    function test_the_holder_bound_fits_the_chains_per_transaction_budget() public {
        uint256 ARBOS_MAX_TX_GAS = 32_000_000;
        uint256 worstCasePerHolder = 38_000; // balances changed since the last tally

        vm.expectRevert(PimdEngine.BadConfig.selector);
        new PimdEngine(_cfg(801));
        PimdEngine ok = new PimdEngine(_cfg(800));
        assertEq(ok.maxHolders(), 800, "800 is the hard ceiling");
        assertLt(800 * worstCasePerHolder, ARBOS_MAX_TX_GAS, "the ceiling is weighable at the worst cost");
        assertGt(900 * worstCasePerHolder, ARBOS_MAX_TX_GAS, "900 was not");
        assertGt(1_200 * worstCasePerHolder, ARBOS_MAX_TX_GAS, "nor was the original 1,200");
    }

    function _cfg(uint256 maxHolders_) internal view returns (PimdEngine.Config memory) {
        return PimdEngine.Config({
            poolManager: address(manager),
            imd: address(imd),
            team: team,
            binder: address(this),
            dripBpsPerPeriod: 400,
            minInterval: 2 minutes,
            minBalance: 100_000e18,
            fireTip: 0.01e18,
            tipPerHolder: 0.0001e18,
            maxCatchup: 6 hours,
            maxHolders: maxHolders_
        });
    }

    function _maxHolders() internal view override returns (uint256) {
        return 3;
    }

    // ================================================================= the escape hatch
    /// Review C1/C2 both ended in an epoch that could not finish and an engine with no way out. The hatch is
    /// the general answer: whatever goes wrong, after a day anyone can put the IMD back and start again.
    function test_a_stuck_epoch_can_be_abandoned_and_the_imd_comes_back() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        _register(alice);
        vm.warp(vm.getBlockTimestamp() + 2 days);

        vm.prank(keeper);
        engine.fire();
        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Tally), "open");
        uint256 reserved = engine.epochQuote();
        uint256 potBefore = engine.pot();
        assertGt(reserved, 0, "an epoch's worth is reserved");

        vm.expectRevert(PimdEngine.TooSoon.selector);
        engine.abortEpoch();

        vm.warp(vm.getBlockTimestamp() + 1 days);
        engine.abortEpoch();

        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Idle), "back to idle");
        assertEq(engine.epochQuote(), 0, "nothing still reserved");
        assertEq(engine.pot(), potBefore + reserved, "every wei of it returned to the pot");

        // and the engine works again afterwards, which is the entire point
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _runEpoch();
        assertGt(imd.balanceOf(alice), 0, "a later epoch paid normally");
    }

    function test_abort_is_refused_when_no_epoch_is_open() public {
        _pastLaunchCap();
        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Idle), "idle");
        vm.expectRevert(PimdEngine.WrongPhase.selector);
        engine.abortEpoch();
    }

    // ================================================================= borrowed weight
    /// Review H1. Weights were read from live balances and the only flash guard watched Uniswap V4's unlock
    /// flag, so a loan from anywhere else stood outside it. A wallet is now weighed on the smaller of what
    /// it holds and what it held at the previous tally, so a bag that arrived since then carries nothing.
    function test_a_bag_that_arrives_just_before_the_tally_carries_no_weight() public {
        _pastLaunchCap();
        // alice and carol hold identical bags, registered together, so honestly they must be paid identically
        _buy(alice, 100e18);
        _buy(carol, 100e18);
        _register(alice);
        _register(carol);

        // bob buys a large bag and lends it to alice across the tally, which is where weights are read.
        // Returning it before `pay` is what a flash loan does inside a single transaction; the weight is
        // already frozen by then, so this is the strongest version of the attack the test can stage.
        _buy(bob, 400e18);
        uint256 loan = token.balanceOf(bob);
        assertGt(loan, token.balanceOf(alice) * 3, "the loan dwarfs her own bag");
        vm.prank(bob);
        token.transfer(alice, loan);

        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.startPrank(keeper);
        engine.fire();
        engine.tally(500);
        vm.stopPrank();

        vm.prank(alice);
        token.transfer(bob, loan); // loan repaid, weights already frozen

        vm.prank(keeper);
        engine.pay(500);

        assertGt(imd.balanceOf(carol), 0, "carol was paid");
        assertLe(
            imd.balanceOf(alice),
            (imd.balanceOf(carol) * 101) / 100,
            "a borrowed bag earns nothing: alice is paid no more than carol, who borrowed nothing"
        );
        // The streak blend also dilutes on receipt, so a borrower is actively worse off than if it had not
        // borrowed at all. That is the right direction, and worth pinning so it is not 'fixed' later.
        assertLt(imd.balanceOf(alice), imd.balanceOf(carol), "and is in fact penalised for it");
    }

    /// The deliberate cost of that rule, stated as a test so it cannot drift silently: new tokens earn from
    /// the epoch after they arrive, not the one they arrive in.
    function test_a_fresh_buy_earns_from_the_next_epoch() public {
        _pastLaunchCap();
        _buy(alice, 100e18);
        _register(alice);
        uint256 first = token.balanceOf(alice);

        // past the top of the ladder, so the tier is a constant 3x and weight tracks balance alone
        vm.warp(vm.getBlockTimestamp() + 15 days);
        vm.startPrank(keeper);
        engine.fire();
        engine.tally(500);
        uint256 weightOnFirstBag = engine.totalWeight();
        engine.pay(500);
        vm.stopPrank();
        assertEq(weightOnFirstBag, (first * 30_000) / 10_000, "weighed on the bag she held, at 3x");

        // she doubles her bag, then an epoch runs immediately
        _buy(alice, 100e18);
        assertGt(token.balanceOf(alice), first, "she holds more now");
        vm.warp(vm.getBlockTimestamp() + 15 days);
        vm.startPrank(keeper);
        engine.fire();
        engine.tally(500);
        uint256 weightRightAfterBuying = engine.totalWeight();
        engine.pay(500);
        vm.stopPrank();
        assertEq(weightRightAfterBuying, weightOnFirstBag, "the new tokens do not count yet");

        // and the epoch after that, they do
        uint256 held = token.balanceOf(alice);
        vm.warp(vm.getBlockTimestamp() + 15 days);
        vm.startPrank(keeper);
        engine.fire();
        engine.tally(500);
        uint256 weightLater = engine.totalWeight();
        vm.stopPrank();
        assertEq(weightLater, (held * 30_000) / 10_000, "now the whole bag counts");
        assertGt(weightLater, weightRightAfterBuying, "which is more than the epoch before");
    }

    // ================================================================= keeper tips
    /// Review M4. `tipBudget` was set, and the fire tip paid, before the check for whether an epoch actually
    /// opened, so a caller could draw the tip out of the pot repeatedly by firing into an empty holder set.
    function test_firing_into_an_empty_holder_set_pays_no_tip() public {
        _pastLaunchCap();
        _buy(alice, 200e18); // income exists, so there is a pot to drip from
        vm.prank(keeper);
        hook.flush();
        // the IMD has reached the engine but is only booked into `pot` by `fire`
        assertGt(imd.balanceOf(address(engine)), 0, "the engine is holding IMD");
        assertEq(engine.holderCount(), 0, "but nobody is registered");

        uint256 before = imd.balanceOf(keeper);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(keeper);
        engine.fire();

        assertGt(engine.pot(), 0, "the income was still booked");
        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Idle), "no epoch opened");
        assertEq(engine.epoch(), 0, "and none was counted");
        assertEq(engine.tipBudget(), 0, "no tip budget was armed");
        assertEq(imd.balanceOf(keeper), before, "and the caller was paid nothing");
    }

    /// Review M1. `callerTip` is a flat 0.01 IMD clamped only by what the team was owed, so on any flush
    /// where less than ~1.7 IMD of buys had accrued the caller took the team's entire slice.
    function test_the_keeper_tip_cannot_take_the_whole_team_slice() public {
        _pastLaunchCap();
        _buy(alice, 1e18); // small trade: the team's cut is far below the flat tip

        uint256 owedToTeam = hook.teamOwed();
        assertGt(owedToTeam, 0, "the team is owed something");
        assertLt(owedToTeam, 0.01e18, "and it is less than the flat tip, which is the dangerous case");

        vm.prank(keeper);
        hook.flush();

        uint256 toKeeper = imd.balanceOf(keeper);
        uint256 toTeam = imd.balanceOf(team);
        assertGt(toTeam, 0, "the team is no longer paid nothing");
        assertEq(toKeeper + toTeam, owedToTeam, "the slice is split, not consumed");
        assertLe(toKeeper * 10_000 / owedToTeam, hook.TIP_MAX_BPS(), "the caller is held to its share");
    }

    // ================================================================= the flush hatch
    /// Review M2. `flushHolders` was built so a team wallet that refuses IMD could not halt the drip, then
    /// never wired in: the engine's hook interface did not declare it and `fire` only ever called `flush`.
    function test_a_refused_team_transfer_does_not_stop_the_drip() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        _register(alice);
        assertGt(hook.holdersOwed(), 0, "the hook is holding the holders' IMD");

        // IMD refuses the team wallet, so the combined flush cannot complete
        vm.mockCallRevert(address(imd), abi.encodeWithSignature("transfer(address,uint256)", team), "blacklisted");

        vm.warp(vm.getBlockTimestamp() + 2 days);
        _runEpoch();

        assertEq(hook.holdersOwed(), 0, "the holders' side was pulled anyway");
        assertGt(imd.balanceOf(alice), 0, "and a holder was paid");
        assertGt(hook.teamOwed(), 0, "the team's slice simply waits at the hook");
    }

    // ================================================================= bind
    /// Review M5. `bind` checked the hook's engine, quote and pool manager, but never that the token it was
    /// being pointed at was the token the hook taxes. bind is one-shot and there is no owner.
    function test_bind_refuses_a_token_the_hook_does_not_tax() public {
        PimdEngine fresh = new PimdEngine(
            PimdEngine.Config({
                poolManager: address(manager),
                imd: address(imd),
                team: team,
                binder: address(this),
                dripBpsPerPeriod: 400,
                minInterval: 2 minutes,
                minBalance: 100_000e18,
                fireTip: 0.01e18,
                tipPerHolder: 0.0001e18,
                maxCatchup: 6 hours,
                maxHolders: 800
            })
        );
        // the live hook names the engine from setUp, so this one cannot bind to it at all
        vm.expectRevert(PimdEngine.BadConfig.selector);
        fresh.bind(address(token), address(hook), new address[](0));
        // and the engine under test, which the hook does name, still refuses a foreign token
        assertTrue(engine.bound(), "already bound in setUp");
    }

    // ================================================================= config
    /// The bound has to be a number somebody chose, so a deploy cannot leave it off or set it absurdly.
    function test_an_unbounded_holder_set_cannot_be_configured() public {
        PimdEngine.Config memory c = PimdEngine.Config({
            poolManager: address(manager),
            imd: address(imd),
            team: team,
            binder: address(this),
            dripBpsPerPeriod: 400,
            minInterval: 2 minutes,
            minBalance: 100_000e18,
            fireTip: 0.01e18,
            tipPerHolder: 0.0001e18,
            maxCatchup: 6 hours,
            maxHolders: 0
        });
        vm.expectRevert(PimdEngine.BadConfig.selector);
        new PimdEngine(c);

        c.maxHolders = 5_001;
        vm.expectRevert(PimdEngine.BadConfig.selector);
        new PimdEngine(c);
    }
}

/// Round 2 finding 2, medium, and a mistake of mine. `_reclaimSlot` advances its cursor when it finds
/// nothing, but `register` used to revert on a miss, and a revert undoes the write. So the sweep re-read
/// the same eight entries for ever and a dead slot behind eight live ones was never reclaimed, which
/// brought back the lockout the reclaim was written to stop for the price of registering eight real bags.
///
/// This needs its own bound: with a set smaller than RECLAIM_PROBES the sweep wraps and finds the dead
/// entry inside one call, so the cursor is never load-bearing and the bug hides. Ten entries with the
/// first eight live is the smallest shape that forces a second call to resume where the first stopped.
contract PimdReclaimCursorTest is PimdBaseTest {
    function _maxHolders() internal view override returns (uint256) {
        return 10;
    }

    function test_a_dead_slot_behind_eight_live_ones_is_still_reclaimed() public {
        _pastLaunchCap();
        _buy(alice, 400e18);
        uint256 min = engine.minBalance();
        assertGe(token.balanceOf(alice), min * 11, "alice can fund eleven minimum bags");

        // indices 0..7: live holders, each with a bag that stays
        for (uint256 i; i < 8; ++i) {
            address live = address(uint160(0x50000 + i));
            vm.prank(alice);
            token.transfer(live, min);
            _register(live);
        }
        // indices 8..9: one bag walked through two addresses, then moved on
        address g0 = address(uint160(0x60000));
        address g1 = address(uint160(0x60001));
        vm.prank(alice);
        token.transfer(g0, min);
        _register(g0);
        vm.prank(g0);
        token.transfer(g1, min);
        _register(g1);
        assertEq(engine.holderCount(), 10, "the set is full");
        assertEq(engine.reclaimCursor(), 0, "and the sweep has not moved");
        assertLt(token.balanceOf(g0), min, "the dead slot is at index 8, behind eight live ones");

        // an honest holder with a real bag: the first call cannot reach index 8 in eight probes, so the
        // cursor has to survive that miss for the second call to get there
        address honest = makeAddr("honestFar");
        vm.prank(g1);
        token.transfer(honest, min);
        address[] memory one = new address[](1);
        one[0] = honest;
        engine.register(one);
        engine.register(one);
        engine.register(one);

        (bool registered,,,,) = engine.holderInfo(honest);
        assertTrue(registered, "the honest holder got in, so the sweep reached past the live head");
        assertEq(engine.holderCount(), 10, "the set is still bounded");
    }
}
