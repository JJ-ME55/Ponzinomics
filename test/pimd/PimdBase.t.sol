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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
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

/// The production hook writes the engine and the team wallet into its source. This points them at the
/// doubles a test deploys, and changes nothing else: every other line executed is the real contract's.
/// Stands in for the IMD launch factory: one address that opens the pool and makes the single seeding
/// add, which is what the hook now insists on. Production does both from the factory contract too, so
/// this is closer to the real flow than driving the add through a test router.
contract MockLaunchFactory is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function open(PoolKey memory key, uint160 sqrtPriceX96) external {
        manager.initialize(key, sqrtPriceX96);
    }

    function seed(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        manager.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, uint128));
        (BalanceDelta d,) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            ""
        );
        // Settle whatever is owed and take whatever is due, so the same path serves both the seeding add
        // and a zero-delta fee collection.
        if (d.amount1() < 0) {
            manager.sync(key.currency1);
            IERC20Like(Currency.unwrap(key.currency1)).transfer(address(manager), uint256(uint128(-d.amount1())));
            manager.settle();
        } else if (d.amount1() > 0) {
            manager.take(key.currency1, address(this), uint256(uint128(d.amount1())));
        }
        if (d.amount0() < 0) {
            manager.sync(key.currency0);
            IERC20Like(Currency.unwrap(key.currency0)).transfer(address(manager), uint256(uint128(-d.amount0())));
            manager.settle();
        } else if (d.amount0() > 0) {
            manager.take(key.currency0, address(this), uint256(uint128(d.amount0())));
        }
        return "";
    }
}

interface IERC20Like {
    function transfer(address, uint256) external returns (bool);
}

contract PimdHookHarness is PimdHook {
    address private immutable _engine;
    address private immutable _team;
    address private immutable _quote;
    address private immutable _factory;

    constructor(IPoolManager pm, address token_, address engine_, address team_, address quote_, address factory_)
        PimdHook(pm, token_)
    {
        _engine = engine_;
        _team = team_;
        _quote = quote_;
        _factory = factory_;
    }

    function engine() public view override returns (address) {
        return _engine;
    }

    function team() public view override returns (address) {
        return _team;
    }

    function quoteToken() public view override returns (address) {
        return _quote;
    }

    function launchFactory() public view override returns (address) {
        return _factory;
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
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant BPS = 10_000;
    /// The tick the launch policy's 2,500 IMD opening cap implies on a one billion supply, which is what
    /// the hook refuses to open outside of.
    int24 constant START_TICK = 129000;
    int24 constant TICK_LOWER = 82980; // ~100x of range below the open
    int24 constant SPACING = 60;
    address constant ARBSYS = address(100);

    IPoolManager manager;
    PoolSwapTest router;
    PoolModifyLiquidityTest lpRouter;
    MockLaunchFactory factory;
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
    /// Stands in for the launch factory's airdrop distributor, excluded at bind.
    address distributor = makeAddr("distributor");

    MockArbSys sys;

    function setUp() public virtual {
        vm.etch(ARBSYS, address(new MockArbSys()).code);
        sys = MockArbSys(ARBSYS);
        sys.set(1_000_000);

        manager = IPoolManager(address(new PoolManager(address(this))));
        router = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        factory = new MockLaunchFactory(manager);
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

        // The factory deploys the token first and holds the supply, so the token takes no constructor
        // argument. Its salt is still mined so PIMD sorts above IMD: the hook refuses the other ordering.
        token = PimdToken(_deployTokenAbove(address(imd)));

        bytes memory args = abi.encode(manager, address(token), address(engine), team, address(imd), address(factory));
        (address hookAddr, bytes32 hookSalt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(PimdHookHarness).creationCode, args);
        hook = PimdHook(payable(address(new PimdHookHarness{salt: hookSalt}(manager, address(token), address(engine), team, address(imd), address(factory)))));
        require(address(hook) == hookAddr, "hook addr");

        _openPoolAsFactory();
        address[] memory neverPay = new address[](1);
        neverPay[0] = distributor;
        engine.bind(address(token), address(hook), neverPay);
        key = hook.poolKey();
        id = key.toId();
    }

    /// Opens the pool and seeds it exactly as the launch factory does: an outside party initializes through
    /// the PoolManager at the briefed price, then makes one single-sided liquidity add. Nothing the hook
    /// does here is special-cased for the caller.
    function _openPoolAsFactory() internal {
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(imd)),
            currency1: Currency.wrap(address(token)),
            fee: 12_500,
            tickSpacing: SPACING,
            hooks: IHooks(address(hook))
        });
        factory.open(k, TickMath.getSqrtPriceAtTick(START_TICK));

        uint256 amount = token.balanceOf(address(this)) * 9 / 10; // the policy seeds 90% of our share
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(TICK_LOWER), TickMath.getSqrtPriceAtTick(START_TICK), amount
        );
        token.transfer(address(factory), amount); // the factory holds the supply it seeds, as in production
        factory.seed(k, TICK_LOWER, START_TICK, liquidity);
    }

    /// Mines a CREATE2 salt so the token's address sorts above IMD, which is what keeps IMD as currency0.
    function _deployTokenAbove(address imd_) internal returns (address) {
        bytes32 initHash = keccak256(type(PimdToken).creationCode);
        for (uint256 i; i < 100_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = vm.computeCreate2Address(salt, initHash, address(this));
            if (uint160(predicted) > uint160(imd_)) {
                PimdToken t = new PimdToken{salt: salt}();
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
        _mineL2(hook.launchCapBlocks() + 1);
        vm.warp(block.timestamp + hook.launchCapSeconds() + 1);
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
