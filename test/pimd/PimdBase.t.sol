// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {PimdToken} from "../../src/pimd/PimdToken.sol";
import {PimdHook, IPimdToken} from "../../src/pimd/PimdHook.sol";
import {PimdEngine} from "../../src/pimd/PimdEngine.sol";

/// A stand-in for IMD: a plain 18-decimal ERC-20, which is what IMD is on Robinhood Chain.
contract MockIMD is ERC20("Identity.md", "IMD", 18) {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockArbSys {
    uint256 public n = 1_000_000;

    function arbBlockNumber() external view returns (uint256) {
        return n;
    }

    function set(uint256 v) external {
        n = v;
    }
}

/// Full-protocol base for the IMD build: deploys the PoolManager and a mock IMD, deploys the engine, mines the
/// hook address for its permission bits, mines the token's CREATE2 salt so PIMD sorts **above** IMD (which is
/// what keeps IMD as currency0 and every bit of v1's tax maths valid), launches single-sided, and binds.
abstract contract PimdBaseTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
    );
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant BPS = 10_000;
    /// ~2.37M PIMD per IMD: a one billion supply opening around five thousand dollars with IMD near $12.
    int24 constant START_TICK = 146760;
    int24 constant TICK_LOWER = 100740; // ~100x of range below the open
    int24 constant SPACING = 60;
    address constant ARBSYS = address(100);

    IPoolManager manager;
    PoolSwapTest router;
    MockIMD imd;
    PimdToken token;
    PimdHook hook;
    PimdEngine engine;
    PoolKey key;
    PoolId id;

    address team = makeAddr("team");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address keeper = makeAddr("keeper");

    MockArbSys sys;
    PimdHook.Config cfg;

    function setUp() public virtual {
        vm.etch(ARBSYS, address(new MockArbSys()).code);
        sys = MockArbSys(ARBSYS);
        sys.set(1_000_000);

        manager = IPoolManager(address(new PoolManager(address(this))));
        router = new PoolSwapTest(manager);
        imd = new MockIMD();

        engine = new PimdEngine(
            PimdEngine.Config({
                poolManager: address(manager),
                imd: address(imd),
                team: team,
                binder: address(this),
                dripBpsPerPeriod: 400, // 4% of the pot per 15 minutes
                minInterval: 2 minutes,
                minBalance: 100_000e18, // 0.01% of supply
                fireTip: 0.02e18, // IMD
                tipPerHolder: 0.0005e18,
                maxCatchup: 6 hours
            })
        );

        cfg = PimdHook.Config({
            launchCapSeconds: 600,
            launchCapBlocks: 6000, // ~10 minutes at ~10 blocks/s
            launchBuyCap: 50e18, // 50 IMD per buyer while the window is open
            burnThreshold: 1e18,
            burnCap: 100e18,
            callerTip: 0.01e18
        });

        bytes memory args = abi.encode(manager, address(imd), address(engine), team, address(this), cfg);
        (address hookAddr, bytes32 hookSalt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(PimdHook).creationCode, args);
        hook = new PimdHook{salt: hookSalt}(manager, address(imd), address(engine), team, address(this), cfg);
        require(address(hook) == hookAddr, "hook addr");

        token = PimdToken(_deployTokenAbove(address(imd), hookAddr));
        require(uint160(address(token)) > uint160(address(imd)), "currency order");

        hook.launch(IPimdToken(address(token)), TICK_LOWER, START_TICK, SPACING);
        engine.bind(address(token), address(hook));
        key = hook.poolKey();
        id = key.toId();
    }

    /// Mines a CREATE2 salt so the token's address sorts above IMD. The deploy script does the same thing.
    function _deployTokenAbove(address imd_, address receiver) internal returns (address) {
        bytes32 initHash = keccak256(abi.encodePacked(type(PimdToken).creationCode, abi.encode(receiver)));
        for (uint256 i; i < 100_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = vm.computeCreate2Address(salt, initHash, address(this));
            if (uint160(predicted) > uint160(imd_)) {
                PimdToken t = new PimdToken{salt: salt}(receiver);
                require(address(t) == predicted, "create2");
                return address(t);
            }
        }
        revert("no salt");
    }

    // ---- time / block helpers ----
    function _mineL2(uint256 n) internal {
        sys.set(sys.n() + n);
    }

    function _pastInit() internal {
        _mineL2(1);
    }

    function _pastLaunchCap() internal {
        _mineL2(cfg.launchCapBlocks + 1);
        vm.warp(block.timestamp + cfg.launchCapSeconds + 1);
    }

    // ---- trading ----
    function _fund(address who, uint256 amount) internal {
        imd.mint(who, amount);
        vm.prank(who);
        imd.approve(address(router), type(uint256).max);
    }

    /// Exact-in buy: spends `amount` IMD, receives PIMD.
    function _buy(address who, uint256 amount) internal returns (uint256 got) {
        _fund(who, amount);
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

    /// Exact-in sell: spends `amount` PIMD, receives IMD.
    function _sell(address who, uint256 amount) internal returns (uint256 got) {
        vm.prank(who);
        token.approve(address(router), type(uint256).max);
        uint256 before = imd.balanceOf(who);
        vm.prank(who, who);
        router.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        got = imd.balanceOf(who) - before;
    }

    /// Exact-out buy: receives exactly `want` PIMD, spends whatever IMD it costs.
    function _buyExactOut(address who, uint256 want, uint256 maxIn) internal returns (uint256 spent) {
        _fund(who, maxIn);
        uint256 before = imd.balanceOf(who);
        vm.prank(who, who);
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: int256(want), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        spent = before - imd.balanceOf(who);
    }

    /// Exact-out sell: receives exactly `want` IMD, spends whatever PIMD it costs.
    function _sellExactOut(address who, uint256 want) internal returns (uint256 spent) {
        vm.prank(who);
        token.approve(address(router), type(uint256).max);
        uint256 before = token.balanceOf(who);
        vm.prank(who, who);
        router.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: int256(want), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        spent = before - token.balanceOf(who);
    }

    // ---- engine helpers ----
    function _register(address who) internal {
        address[] memory a = new address[](1);
        a[0] = who;
        engine.register(a);
    }

    function _runEpoch() internal {
        vm.prank(keeper);
        engine.fire();
        if (engine.phase() == PimdEngine.Phase.Tally) {
            vm.prank(keeper);
            engine.tally(500);
        }
        if (engine.phase() == PimdEngine.Phase.Pay) {
            vm.prank(keeper);
            engine.pay(500);
        }
    }
}
