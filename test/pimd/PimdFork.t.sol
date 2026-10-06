// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {PimdToken} from "../../src/pimd/PimdToken.sol";
import {PimdHook, IPimdToken} from "../../src/pimd/PimdHook.sol";
import {PimdEngine} from "../../src/pimd/PimdEngine.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// The whole thing against live Robinhood Chain state: the real PoolManager and, more importantly, the **real
/// IMD contract**. A mock ERC-20 cannot prove how IMD itself behaves when V4 settles against it, and that is
/// the one piece of this build that is genuinely new rather than ported.
///
///   forge test --match-path test/pimd/PimdFork.t.sol --fork-url robinhood
contract PimdForkTest is Test {
    using PoolIdLibrary for PoolKey;

    // Defaults are Robinhood Chain; override to run the same suite against another chain's IMD.
    address POOL_MANAGER = vm.envOr("POOL_MANAGER", 0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address IMD = vm.envOr("IMD", 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127);
    int24 START_TICK = int24(vm.envOr("START_TICK", int256(147780)));
    int24 TICK_LOWER = int24(vm.envOr("TICK_LOWER", int256(101760)));
    int24 constant SPACING = 60;
    uint256 constant BPS = 10_000;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
    );

    IPoolManager manager;
    IERC20 imd;
    PoolSwapTest router;
    PimdToken token;
    PimdHook hook;
    PimdEngine engine;
    PoolKey key;

    address team = makeAddr("team");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC", vm.rpcUrl("robinhood")));
        manager = IPoolManager(POOL_MANAGER);
        imd = IERC20(IMD);
        require(POOL_MANAGER.code.length > 0, "no PoolManager on this fork");
        require(IMD.code.length > 0, "no IMD on this fork");

        router = new PoolSwapTest(manager);
        engine = new PimdEngine(
            PimdEngine.Config({
                poolManager: POOL_MANAGER,
                imd: IMD,
                team: team,
                binder: address(this),
                dripBpsPerPeriod: 400,
                minInterval: 2 minutes,
                minBalance: 100_000e18,
                fireTip: 0.01e18,
                tipPerHolder: 0.0001e18,
                maxCatchup: 6 hours
            })
        );

        PimdHook.Config memory hc = PimdHook.Config({
            launchCapSeconds: 600,
            launchCapBlocks: 6000,
            launchBuyCap: 25e18,
            burnThreshold: 1e18,
            burnCap: 100e18,
            callerTip: 0.01e18
        });

        bytes memory args = abi.encode(manager, IMD, address(engine), team, address(this), hc);
        (address hookAddr, bytes32 hookSalt) = HookMiner.find(address(this), FLAGS, type(PimdHook).creationCode, args);
        hook = new PimdHook{salt: hookSalt}(manager, IMD, address(engine), team, address(this), hc);
        require(address(hook) == hookAddr, "hook addr");

        bytes32 initHash = keccak256(abi.encodePacked(type(PimdToken).creationCode, abi.encode(hookAddr)));
        for (uint256 i; i < 100_000; ++i) {
            address predicted = vm.computeCreate2Address(bytes32(i), initHash, address(this));
            if (uint160(predicted) > uint160(IMD)) {
                token = new PimdToken{salt: bytes32(i)}(hookAddr);
                break;
            }
        }
        require(address(token) != address(0) && uint160(address(token)) > uint160(IMD), "token order");

        hook.launch(IPimdToken(address(token)), TICK_LOWER, START_TICK, SPACING);
        engine.bind(address(token), address(hook));
        key = hook.poolKey();

        vm.roll(block.number + 1); // past the init block
    }

    // ------------------------------------------------------------------ helpers
    function _fundImd(address who, uint256 amount) internal {
        deal(IMD, who, amount);
        assertGe(imd.balanceOf(who), amount, "real IMD could not be dealt; find a whale instead");
        vm.prank(who);
        imd.approve(address(router), type(uint256).max);
    }

    function _buy(address who, uint256 amount) internal returns (uint256 got) {
        _fundImd(who, amount);
        uint256 before = token.balanceOf(who);
        vm.prank(who, who);
        router.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        got = token.balanceOf(who) - before;
    }

    // ------------------------------------------------------------------ the tests
    function test_fork_launch_against_real_state() public view {
        assertTrue(hook.launched(), "launched on the real PoolManager");
        assertEq(Currency.unwrap(key.currency0), IMD, "real IMD is currency0");
        assertEq(Currency.unwrap(key.currency1), address(token), "PIMD is currency1");
        assertEq(token.balanceOf(POOL_MANAGER), token.totalSupply(), "whole supply seeded");
        assertEq(imd.decimals(), 18, "IMD is 18 decimals, as the tax maths assumes");
    }

    function test_fork_buy_takes_tax_in_real_imd() public {
        uint256 spend = 10e18;
        uint256 pmBefore = imd.balanceOf(POOL_MANAGER);
        uint256 got = _buy(alice, spend);

        assertGt(got, 0, "alice got PIMD");
        assertEq(hook.totalTaxed(), spend * 300 / BPS, "3% in real IMD");
        assertEq(hook.claimBalance(), hook.totalTaxed(), "held as claims against the real token");
        assertEq(imd.balanceOf(POOL_MANAGER) - pmBefore, spend, "every IMD of it settled into the manager");
    }

    function test_fork_sell_takes_tax_in_real_imd() public {
        _buy(alice, 20e18);
        uint256 taxed = hook.totalTaxed();
        uint256 bag = token.balanceOf(alice);

        vm.prank(alice);
        token.approve(address(router), type(uint256).max);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice, alice);
        router.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(bag / 2),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 received = imd.balanceOf(alice) - before;
        assertGt(received, 0, "alice got real IMD out");
        assertApproxEqRel(hook.totalTaxed() - taxed, received * 700 / 9300, 1e12, "7% in real IMD");
    }

    function test_fork_flush_moves_real_imd_and_burns_supply() public {
        vm.warp(block.timestamp + 601); // past the per-buyer cap window
        _buy(alice, 500e18);

        uint256 holders = hook.holdersOwed();
        uint256 supplyBefore = token.totalSupply();
        assertTrue(hook.burnReady(), "burn budget armed");

        vm.prank(keeper);
        (,,, uint256 burned) = hook.flush();

        assertEq(imd.balanceOf(address(engine)), holders, "engine holds real IMD");
        assertGt(imd.balanceOf(team), 0, "team paid in real IMD");
        assertGt(burned, 0, "PIMD bought back");
        assertEq(token.totalSupply(), supplyBefore - burned, "supply actually fell");
    }

    function test_fork_engine_drips_real_imd_to_a_holder() public {
        vm.warp(block.timestamp + 601);
        _buy(alice, 500e18);
        address[] memory a = new address[](1);
        a[0] = alice;
        engine.register(a);

        vm.warp(block.timestamp + 2 days);
        uint256 before = imd.balanceOf(alice);

        vm.startPrank(keeper);
        engine.fire();
        engine.tally(100);
        engine.pay(100);
        vm.stopPrank();

        uint256 paid = imd.balanceOf(alice) - before;
        assertGt(paid, 0, "a real IMD payout landed in a wallet");
        console2.log("IMD paid to one holder (wei)", paid);
        assertEq(uint8(engine.phase()), uint8(PimdEngine.Phase.Idle), "epoch closed");
    }

    function test_fork_imd_is_a_plain_erc20_with_no_transfer_fee() public {
        // If IMD took a fee on transfer, every payout and every settle would be short, and the hook's claim
        // accounting would drift. Prove it does not, against the live contract.
        deal(IMD, alice, 100e18);
        vm.prank(alice);
        imd.transfer(bob, 100e18);
        assertEq(imd.balanceOf(bob), 100e18, "IMD moves one for one");
    }
}
