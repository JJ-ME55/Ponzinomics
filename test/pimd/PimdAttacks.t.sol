// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PimdBaseTest} from "./PimdBase.t.sol";
import {PimdEngine} from "../../src/pimd/PimdEngine.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

/// Calls the engine from inside a PoolManager unlock, which is where a flash borrower would be sitting.
contract Unlocker is IUnlockCallback {
    IPoolManager immutable manager;
    PimdEngine immutable engine;
    uint8 public what; // 1 fire, 2 tally, 3 pay

    constructor(IPoolManager m, PimdEngine e) {
        manager = m;
        engine = e;
    }

    function run(uint8 w) external {
        what = w;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (what == 1) engine.fire();
        if (what == 2) engine.tally(100);
        if (what == 3) engine.pay(100);
        return "";
    }
}

contract PimdAttacksTest is PimdBaseTest {
    // ------------------------------------------------------------------ the flash-borrow weight attack
    // Weights are read from balances. Inside an unlock, anyone can hold an enormous PIMD balance for the length
    // of one callback. v1 was exposed to this. Here every state-changing entry point refuses to run while the
    // PoolManager is unlocked, so the borrowed balance can never be standing when weights are read.
    function test_fire_refuses_while_the_pool_is_unlocked() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        _register(alice);
        vm.warp(block.timestamp + 2 days);

        Unlocker u = new Unlocker(manager, engine);
        vm.expectRevert();
        u.run(1);
    }

    function test_tally_refuses_while_the_pool_is_unlocked() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        _register(alice);
        vm.warp(block.timestamp + 2 days);
        vm.prank(keeper);
        engine.fire();
        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Tally), "mid-epoch");

        Unlocker u = new Unlocker(manager, engine);
        vm.expectRevert();
        u.run(2);

        // and the honest path still works
        vm.prank(keeper);
        engine.tally(100);
        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Pay), "tally completed normally");
    }

    function test_pay_refuses_while_the_pool_is_unlocked() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        _register(alice);
        vm.warp(block.timestamp + 2 days);
        vm.startPrank(keeper);
        engine.fire();
        engine.tally(100);
        vm.stopPrank();

        Unlocker u = new Unlocker(manager, engine);
        vm.expectRevert();
        u.run(3);

        vm.prank(keeper);
        engine.pay(100);
        assertGt(imd.balanceOf(alice), 0, "paid normally");
    }

    // ------------------------------------------------------------------ one holder cannot stall the batch
    // IMD is somebody else's contract and its owner's powers are not public. If it ever refuses one address,
    // that address is skipped, its share goes back to the pot, and everyone else is still paid.
    function test_one_refused_holder_does_not_stop_the_others() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        _buy(bob, 200e18);
        _buy(carol, 200e18);
        _register(alice);
        _register(bob);
        _register(carol);
        vm.warp(block.timestamp + 2 days);

        // IMD refuses every transfer to bob, whatever the amount
        vm.mockCallRevert(address(imd), abi.encodeWithSignature("transfer(address,uint256)", bob), "blacklisted");

        uint256 potBefore = imd.balanceOf(address(engine)) + engine.pendingAtHook(); // still at the hook until fire()
        _runEpoch();

        assertGt(imd.balanceOf(alice), 0, "alice paid");
        assertGt(imd.balanceOf(carol), 0, "carol paid");
        assertEq(imd.balanceOf(bob), 0, "bob could not be paid");
        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Idle), "the epoch still finished");
        // bob's share was not burned or stranded: it is back in the pot
        assertEq(imd.balanceOf(address(engine)), engine.pot(), "engine's IMD is all accounted for");
        assertLt(engine.totalDripped(), potBefore, "only what was actually paid counts as dripped");
    }

    // ------------------------------------------------------------------ paging
    function test_many_holders_weigh_whole_and_pay_across_pages() public {
        _pastLaunchCap();
        uint256 n = 120;
        address[] memory list = new address[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = address(uint160(0x10000 + i));
            _buy(list[i], 2e18);
        }
        engine.register(list);
        assertEq(engine.holderCount(), n, "all registered");
        vm.warp(block.timestamp + 2 days);

        vm.startPrank(keeper);
        engine.fire();
        // Weighing is whole or nothing: a page boundary is the window a sybil moves a bag through.
        vm.expectRevert(abi.encodeWithSelector(PimdEngine.TallyMustBeWhole.selector, n));
        engine.tally(50);
        engine.tally(n);
        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Pay), "weighed in one call");
        // Paying is still paged: the weights are frozen, so nothing a payee does can change them.
        engine.pay(50);
        engine.pay(50);
        engine.pay(50);
        vm.stopPrank();

        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Idle), "paid in pages");
        uint256 paidCount;
        for (uint256 i; i < n; ++i) {
            if (imd.balanceOf(list[i]) > 0) ++paidCount;
        }
        assertEq(paidCount, n, "every holder got IMD");
    }

    /// Audit finding, HIGH, found independently by two specialists: tally read live balances per page, so
    /// moving one bag between pages had it weighed once per wallet it passed through. With N wallets a
    /// sybil took N/(N+1) of every epoch out of the honest holders' share.
    function test_one_bag_cannot_be_weighed_twice_across_wallets() public {
        _pastLaunchCap();
        _buy(alice, 400e18);
        uint256 bag = token.balanceOf(alice) / 2;
        vm.prank(alice);
        token.transfer(carol, bag); // identical bags, so an honest pair would be paid identically

        // register alice and carol honestly, then let bob register on the strength of alice's bag and
        // hand it straight back: three registered wallets, two bags between them
        address[] memory two = new address[](2);
        (two[0], two[1]) = (alice, carol);
        engine.register(two);
        vm.prank(alice);
        token.transfer(bob, bag);
        address[] memory one = new address[](1);
        one[0] = bob;
        engine.register(one);
        vm.prank(bob);
        token.transfer(alice, bag);
        assertEq(engine.holderCount(), 3, "three wallets registered on two bags");

        vm.warp(block.timestamp + 2 days);
        vm.prank(keeper);
        engine.fire();

        // the attack needed a page boundary to move the bag through. There is no longer one.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PimdEngine.TallyMustBeWhole.selector, 3));
        engine.tally(2);

        vm.startPrank(keeper);
        engine.tally(3);
        engine.pay(10);
        vm.stopPrank();

        uint256 honest = imd.balanceOf(carol);
        assertGt(honest, 0, "carol was paid");
        assertEq(imd.balanceOf(bob), 0, "the empty sybil wallet earns nothing");
        assertApproxEqRel(
            imd.balanceOf(alice) + imd.balanceOf(bob),
            honest,
            0.01e18,
            "one bag earns one share, however many wallets it was registered through"
        );
    }

    // ------------------------------------------------------------------ rogue pools and dust
    function test_a_pool_like_contract_is_not_paid() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        _register(alice);

        FakePair pair = new FakePair(address(token));
        uint256 half = token.balanceOf(alice) / 2; // read first: a call inside the argument eats the prank
        vm.prank(alice);
        token.transfer(address(pair), half);
        address[] memory list = new address[](1);
        list[0] = address(pair);
        engine.register(list);

        vm.warp(block.timestamp + 2 days);
        _runEpoch();
        assertEq(imd.balanceOf(address(pair)), 0, "a pair holding PIMD collects nothing");
    }

    /// A pair cannot register, but it can be registered before it exists. CREATE2 lets the attacker pick the
    /// address: fund it with PIMD, register it while it is still codeless -- `_isPool` passes a codeless
    /// address without probing it -- let the streak mature, and only then deploy the pair code. `tally`
    /// deliberately does not re-probe, so nothing takes the weight back off it, and the balance test in
    /// `prune` never fires because a pooled bag does not fall. So `prune` has to be able to take it out on
    /// the shape rather than the size, or the pair holds a matured dividend claim on pooled PIMD for good.
    function test_a_holder_that_turns_pool_shaped_is_prunable() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        _register(alice);

        // an address the attacker picked, funded and registered while it still has no code
        address lair = address(uint160(0xBEEF00));
        uint256 half = token.balanceOf(alice) / 2; // read first: a call inside the argument eats the prank
        vm.prank(alice);
        token.transfer(lair, half);
        _register(lair);
        assertEq(engine.holderCount(), 2, "a codeless address registers fine");

        // the streak matures, and then the pair code lands on it
        vm.warp(block.timestamp + 2 days);
        vm.etch(lair, address(new FakePair(address(token))).code);
        vm.store(lair, bytes32(0), bytes32(uint256(uint160(address(token)))));
        assertEq(FakePair(lair).token0(), address(token), "it reports PIMD as token0 now");
        assertGe(token.balanceOf(lair), engine.minBalance(), "and its bag never fell below the minimum");

        address[] memory one = new address[](1);
        one[0] = lair;
        engine.prune(one);
        assertEq(engine.holderCount(), 1, "the pool was pruned despite its bag");
        (bool registered,,,,) = engine.holderInfo(lair);
        assertFalse(registered, "and its record is gone");

        // It has to cut one way only. `prune` reads nothing but the address it is handed, so it cannot be
        // aimed at a healthy holder, nor at a contract that is a pair for some other token.
        FakePair other = new FakePair(address(0xdead));
        _buy(bob, 200e18);
        uint256 bobBag = token.balanceOf(bob); // read first: a call inside the argument eats the prank
        vm.prank(bob);
        token.transfer(address(other), bobBag);
        _register(address(other));
        assertEq(engine.holderCount(), 2, "a pair for some other token is a normal holder");

        address[] memory two = new address[](2);
        two[0] = alice;
        two[1] = address(other);
        engine.prune(two);
        assertEq(engine.holderCount(), 2, "neither a healthy holder nor an unrelated pair is prunable");
    }

    function test_dust_holder_is_skipped_and_prunable() public {
        _pastLaunchCap();
        _buy(alice, 200e18);
        _register(alice);
        vm.prank(alice);
        token.transfer(bob, 1e18); // below the 100,000 PIMD minimum

        address[] memory list = new address[](1);
        list[0] = bob;
        engine.register(list);
        assertEq(engine.holderCount(), 1, "dust never registers");
    }

    // ------------------------------------------------------------------ a gap is not a payday
    // If the keeper dies for days, the pot keeps growing. The release curve is clamped so the epoch that
    // restarts it cannot hand the whole pot to whoever happens to be holding at that moment.
    function test_a_long_gap_still_releases_only_a_slice() public {
        _pastLaunchCap();
        _buy(alice, 500e18);
        _register(alice);
        vm.warp(block.timestamp + 2 days);
        vm.prank(keeper);
        hook.flush();

        uint256 potBefore = imd.balanceOf(address(engine));
        vm.warp(block.timestamp + 30 days); // keeper has been dead for a month
        _runEpoch();

        // The clamp is set to 6 hours at deploy, and the curve releases 4% per 15 minutes, so the most any one
        // epoch can ever release is 1 - 0.96^24 = 62.5% of the pot, no matter how long the keeper was dead.
        uint256 released = engine.totalDripped();
        assertLt(released, (potBefore * 6300) / BPS, "a month's gap cannot release more than the clamp allows");
        assertGt(released, (potBefore * 5500) / BPS, "and it does release the full clamped slice");
        assertGt(engine.pot(), (potBefore * 3300) / BPS, "a third of the pot still pays out later");
    }

    // ------------------------------------------------------------------ somebody else deploying it
    // The IMD swarm launches from its own wallet, and whatever it deploys that has an owner, it owns. Ours has
    // no owner at all, and the one-shot powers belong to the address the deploy names rather than to whoever
    // sent the transaction. So a stranger can deploy the whole thing and still hold nothing.
    function test_a_stranger_can_deploy_it_and_hold_nothing() public {
        address stranger = makeAddr("swarmLaunchWallet");
        vm.prank(stranger);
        PimdEngine fresh = new PimdEngine(
            PimdEngine.Config({
                poolManager: address(manager),
                imd: address(imd),
                team: team,
                binder: address(this), // us, not the stranger who deploys it
                dripBpsPerPeriod: 400,
                minInterval: 2 minutes,
                minBalance: 100_000e18,
                fireTip: 0.01e18,
                tipPerHolder: 0.0001e18,
                maxCatchup: 6 hours,
                maxHolders: 1_200
            })
        );

        assertEq(fresh.binder(), address(this), "the deploy names who may bind");
        vm.prank(stranger);
        vm.expectRevert(PimdEngine.NotBinder.selector);
        fresh.bind(address(token), address(hook), new address[](0));

        // And the binder cannot bind it to a hook that pays somebody else: the live hook names the
        // engine deployed in setUp, not this one.
        vm.expectRevert(PimdEngine.BadConfig.selector);
        fresh.bind(address(token), address(hook), new address[](0));
        assertFalse(fresh.bound(), "an engine no hook pays stays unbound");
        assertEq(fresh.team(), team, "fees still point at our wallet, whoever deployed");
    }

    function test_team_is_excluded_from_drips() public view {
        assertTrue(engine.excluded(team), "the team does not farm the holder pot");
        assertTrue(engine.excluded(address(hook)), "nor does the hook");
        assertTrue(engine.excluded(address(manager)), "nor the pool");
    }
}

contract FakePair {
    address public token0;
    address public token1;

    constructor(address t) {
        token0 = t;
        token1 = address(0xdead);
    }
}
