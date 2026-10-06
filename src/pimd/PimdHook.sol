// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {L2Block} from "../libraries/L2Block.sol";

interface IPimdToken {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function burn(uint256) external;
}

interface IERC20Quote {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @title PimdHook
/// @notice The Ponzinomics ($PIMD) hook. PIMD is paired with **IMD**, and every trade pays a tax **in IMD**:
/// 3% on buys, 7% on sells. The tax is held as ERC-6909 claims inside the PoolManager and split three ways:
///
///   * 60% to holders, pushed to the engine, which drips it into wallets by hold-streak,
///   * 20% to a burn budget, which buys PIMD off this pool and destroys it,
///   * 20% to the team.
///
/// The pool is launched single-sided: all one billion PIMD goes into one range above the opening price, so the
/// launch needs no capital and the first buy is what puts IMD into the pool.
///
/// @dev This is PULSE v1's hook with the quote asset changed from native ETH to an ERC-20, and the emissions
/// removed. Three things follow from the ERC-20 quote and are the reason this file deserves an audit's
/// attention: fee claims are minted against `uint256(uint160(IMD))` rather than currency id 0; paying IMD out
/// means burning claims and `take`-ing; and the pool only behaves like v1's if **IMD sorts below PIMD**, which
/// the deploy script guarantees by mining the token's CREATE2 salt. `launch` refuses to run if it does not.
///
/// What is deliberately absent, because we are not using it and every line is audit surface: minting of any
/// kind, the decaying launch tax (the engine's 0x first hour does that job), the burn party, and the
/// large-sell booster. There is no owner. The team wallet, the engine and the launcher are fixed at
/// construction and cannot be changed afterwards.
contract PimdHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------ constants
    uint256 public constant BPS = 10_000;
    uint256 public constant BUY_TAX_BPS = 300; // 3%
    uint256 public constant SELL_TAX_BPS = 700; // 7%
    uint256 public constant HOLDERS_BPS = 6_000; // 60% of the tax
    uint256 public constant BURN_BPS = 2_000; // 20% of the tax; the team gets the remaining 20%
    /// @dev Fail-open bound on the block-based launch cap. On Arbitrum Orbit `block.number` is the L1 block, so
    /// if the ArbSys precompile ever stopped answering, the block test alone would keep the cap on forever.
    uint256 public constant LAUNCH_CAP_MAX_SECONDS = 1 hours;

    uint8 private constant ACTION_SEED = 1;
    uint8 private constant ACTION_FLUSH = 2;
    uint8 private constant ACTION_PAYOUTS = 3;

    uint256 private constant _FEE_SLOT = uint256(keccak256("pimd.hook.fee")) - 1;
    uint256 private constant _UNLOCK_SLOT = uint256(keccak256("pimd.hook.unlocking")) - 1;
    uint256 private constant _INSWAP_SLOT = uint256(keccak256("pimd.hook.inswap")) - 1;

    struct Config {
        uint32 launchCapSeconds; // how long the per-buyer cap applies
        uint32 launchCapBlocks; // and the block-count bound on the same window
        uint128 launchBuyCap; // IMD one tx.origin may spend during that window (0 = no cap)
        uint128 burnThreshold; // burn budget that arms the buy-and-burn
        uint128 burnCap; // most IMD one buy-and-burn may spend
        uint128 callerTip; // IMD paid to whoever calls flush, taken from the team's slice only
    }

    // ------------------------------------------------------------------ immutables
    IPoolManager public immutable poolManager;
    Currency public immutable quote; // IMD
    uint256 public immutable quoteId; // the ERC-6909 id of IMD claims
    address public immutable engine; // receives the holders' slice as real IMD
    address public immutable team;
    address public immutable launcher;
    uint32 public immutable launchCapSeconds;
    uint32 public immutable launchCapBlocks;
    uint128 public immutable launchBuyCap;
    uint128 public immutable burnThreshold;
    uint128 public immutable burnCap;
    uint128 public immutable callerTip;

    // ------------------------------------------------------------------ state
    IPimdToken public token;
    PoolKey internal _key;
    bool public launched;
    uint64 public initBlock;
    uint64 public launchStart;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public seededLiquidity;

    uint256 public holdersOwed; // IMD claims waiting to go to the engine
    uint256 public burnBudget; // IMD claims waiting to buy PIMD back
    uint256 public teamOwed; // IMD claims waiting for the team

    uint256 public totalTaxed; // lifetime IMD taken as tax
    uint256 public totalToHolders; // lifetime IMD pushed to the engine
    uint256 public totalToTeam;
    uint256 public totalBurnSpent; // lifetime IMD spent buying PIMD back
    uint256 public totalBurned; // lifetime PIMD destroyed

    mapping(address => uint256) public launchBuys;

    uint256 private _lock = 1;

    // ------------------------------------------------------------------ errors
    error NotPoolManager();
    error NotLauncher();
    error AlreadyLaunched();
    error NotLaunched();
    error HookNotImplemented();
    error OnlyHookMayInitialize();
    error InitBlockSwap();
    error LaunchBuyCap();
    error Reentrancy();
    error NotUnlocking();
    error SeedNeedsQuote();
    error NothingPending();
    error BadConfig();
    error BadCurrencyOrder();
    error NoRawEth();

    // ------------------------------------------------------------------ events
    event Launched(PoolId indexed id, uint128 liquidity, uint256 seeded);
    event FeeTaken(bool indexed buy, uint256 fee);
    event Flushed(address indexed caller, uint256 toHolders, uint256 toTeam, uint256 burnSpent, uint256 burned);
    event PayoutsPushed(uint256 toHolders, uint256 toTeam);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(IPoolManager pm, address quote_, address engine_, address team_, address launcher_, Config memory c) {
        if (quote_ == address(0) || engine_ == address(0) || team_ == address(0) || launcher_ == address(0)) {
            revert BadConfig();
        }
        if (c.burnCap == 0) revert BadConfig();
        poolManager = pm;
        quote = Currency.wrap(quote_);
        quoteId = uint256(uint160(quote_));
        engine = engine_;
        team = team_;
        launcher = launcher_;
        launchCapSeconds = c.launchCapSeconds;
        launchCapBlocks = c.launchCapBlocks;
        launchBuyCap = c.launchBuyCap;
        burnThreshold = c.burnThreshold;
        burnCap = c.burnCap;
        callerTip = c.callerTip;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // nobody but this hook may open a pool with it
            afterInitialize: true,
            beforeAddLiquidity: true, // third-party liquidity is blocked; the hook's own seed skips it (noSelfCall)
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------ launch
    /// @notice Opens the PIMD/IMD pool and puts the whole supply into one range above the opening price.
    /// @param token_ the PIMD token, whose entire supply must already sit on this hook
    /// @param tickLower_ bottom of the single range
    /// @param startTick the opening price, and the top of the range
    /// @param tickSpacing the pool's tick spacing
    function launch(IPimdToken token_, int24 tickLower_, int24 startTick, int24 tickSpacing) external nonReentrant {
        if (msg.sender != launcher) revert NotLauncher();
        if (launched || initBlock != 0) revert AlreadyLaunched();
        if (tickLower_ >= startTick) revert BadConfig();
        // Everything below assumes IMD is currency0 and PIMD currency1, exactly as ETH/PULSE was in v1. The
        // deploy script mines the token's salt to make that true; refuse to launch if it somehow is not.
        if (uint160(address(token_)) <= uint160(Currency.unwrap(quote))) revert BadCurrencyOrder();

        token = token_;
        _key = PoolKey({
            currency0: quote,
            currency1: Currency.wrap(address(token_)),
            fee: 0,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });
        tickLower = tickLower_;
        tickUpper = startTick;
        poolManager.initialize(_key, TickMath.getSqrtPriceAtTick(startTick));
        initBlock = uint64(L2Block.number());
        launchStart = uint64(block.timestamp);

        uint256 supply = token_.balanceOf(address(this));
        _tstore(_UNLOCK_SLOT, 1);
        bytes memory res = poolManager.unlock(abi.encode(ACTION_SEED, supply));
        _tstore(_UNLOCK_SLOT, 0);
        uint256 seeded = abi.decode(res, (uint256));
        uint256 dust = token_.balanceOf(address(this));
        if (dust > 0) token_.burn(dust); // the range maths never takes the last wei; nobody should keep it
        launched = true;
        emit Launched(_key.toId(), seededLiquidity, seeded);
    }

    // ------------------------------------------------------------------ hook callbacks
    function beforeInitialize(address sender, PoolKey calldata, uint160) external view onlyPoolManager returns (bytes4) {
        // Our own initialize never reaches here (V4 skips hook calls when the caller is the hook itself), so
        // anything that does get here is somebody else trying to open a second pool on this hook.
        if (sender != address(this)) revert OnlyHookMayInitialize();
        revert AlreadyLaunched();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (initBlock == 0) revert NotLaunched();
        if (_tload(_INSWAP_SLOT) == 1) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        if (L2Block.number() == initBlock) revert InitBlockSwap();

        uint256 fee;
        // The IMD side is the *specified* amount on an exact-in buy and an exact-out sell. Take the tax there.
        if ((params.amountSpecified < 0) == params.zeroForOne) {
            uint256 amt =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 bps = params.zeroForOne ? BUY_TAX_BPS : SELL_TAX_BPS;
            fee = params.amountSpecified < 0 ? amt * bps / BPS : amt * bps / (BPS - bps);
            if (fee > 0) poolManager.mint(address(this), quoteId, fee);
        }
        _tstore(_FEE_SLOT, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (_tload(_INSWAP_SLOT) == 1) return (IHooks.afterSwap.selector, 0);
        uint256 fee = _tload(_FEE_SLOT);
        _tstore(_FEE_SLOT, 0);
        int128 hookDeltaUnspecified;

        // The other two cases: the IMD side is the *unspecified* amount, known only now.
        if ((params.amountSpecified < 0) != params.zeroForOne) {
            int128 a0 = delta.amount0();
            uint256 quoteAmt = a0 < 0 ? uint256(uint128(-a0)) : uint256(uint128(a0));
            uint256 bps = params.zeroForOne ? BUY_TAX_BPS : SELL_TAX_BPS;
            fee = params.zeroForOne ? quoteAmt * bps / (BPS - bps) : quoteAmt * bps / BPS;
            if (fee > 0) poolManager.mint(address(this), quoteId, fee);
            hookDeltaUnspecified = int128(uint128(fee));
        }

        // Opening at a five thousand dollar market cap, one wallet could otherwise take the whole range in the
        // first seconds. The cap is per tx.origin, applies for a short window, and is bounded by both blocks
        // and time so it can never get stuck on.
        if (params.zeroForOne && launchBuyCap > 0) {
            if (
                L2Block.number() < uint256(initBlock) + launchCapBlocks
                    && block.timestamp < uint256(launchStart) + launchCapSeconds
                    && block.timestamp < uint256(launchStart) + LAUNCH_CAP_MAX_SECONDS
            ) {
                uint256 spent = uint256(uint128(-delta.amount0())) + fee;
                uint256 total = launchBuys[tx.origin] + spent;
                if (total > launchBuyCap) revert LaunchBuyCap();
                launchBuys[tx.origin] = total;
            }
        }

        if (fee > 0) _split(fee, params.zeroForOne);
        return (IHooks.afterSwap.selector, hookDeltaUnspecified);
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ------------------------------------------------------------------ moving the money
    /// @notice Permissionless. Pushes the holders' IMD to the engine, pays the team, and if the burn budget is
    /// armed, buys PIMD off the pool with it and destroys it. The caller's tip comes out of the team's slice,
    /// never out of holders or burns.
    function flush() external nonReentrant returns (uint256 toHolders, uint256 toTeam, uint256 spent, uint256 burned) {
        if (!launched) revert NotLaunched();
        toHolders = holdersOwed;
        toTeam = teamOwed;
        spent = burnBudget >= burnThreshold ? (burnBudget > burnCap ? burnCap : burnBudget) : 0;
        if (toHolders == 0 && toTeam == 0 && spent == 0) revert NothingPending();
        uint256 tip = callerTip;
        if (tip > toTeam) tip = toTeam;
        holdersOwed = 0;
        teamOwed = 0;
        burnBudget -= spent;

        _tstore(_UNLOCK_SLOT, 1);
        bytes memory res = poolManager.unlock(abi.encode(ACTION_FLUSH, toHolders, toTeam - tip, spent, msg.sender, tip));
        _tstore(_UNLOCK_SLOT, 0);
        burned = abi.decode(res, (uint256));

        if (burned > 0) {
            token.burn(burned);
            totalBurned += burned;
            totalBurnSpent += spent;
        }
        totalToHolders += toHolders;
        totalToTeam += toTeam;
        emit Flushed(msg.sender, toHolders, toTeam, spent, burned);
    }

    /// @notice Permissionless, and deliberately separate: it pays holders and the team without touching the
    /// pool, so a pool that cannot be swapped against (empty, or paused by something upstream) can never stop
    /// the drip.
    function flushPayouts() external nonReentrant returns (uint256 toHolders, uint256 toTeam) {
        toHolders = holdersOwed;
        toTeam = teamOwed;
        if (toHolders == 0 && toTeam == 0) revert NothingPending();
        holdersOwed = 0;
        teamOwed = 0;
        _tstore(_UNLOCK_SLOT, 1);
        poolManager.unlock(abi.encode(ACTION_PAYOUTS, toHolders, toTeam));
        _tstore(_UNLOCK_SLOT, 0);
        totalToHolders += toHolders;
        totalToTeam += toTeam;
        emit PayoutsPushed(toHolders, toTeam);
    }

    // ------------------------------------------------------------------ unlock callback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (_tload(_UNLOCK_SLOT) != 1) revert NotUnlocking();
        uint8 action = abi.decode(data, (uint8));

        if (action == ACTION_SEED) {
            (, uint256 amount) = abi.decode(data, (uint8, uint256));
            uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, amount);
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                _key,
                ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: 0
                }),
                ""
            );
            // A single-sided range above the opening price owes PIMD only. If it asks for IMD, the ticks are wrong.
            if (d.amount0() != 0) revert SeedNeedsQuote();
            uint256 owed1 = uint256(uint128(-d.amount1()));
            poolManager.sync(_key.currency1);
            token.transfer(address(poolManager), owed1);
            poolManager.settle();
            seededLiquidity = liquidity;
            return abi.encode(owed1);
        }

        if (action == ACTION_FLUSH) {
            (, uint256 toHolders, uint256 toTeam, uint256 spend, address tipTo, uint256 tip) =
                abi.decode(data, (uint8, uint256, uint256, uint256, address, uint256));
            uint256 bought;
            if (spend > 0) bought = _swapBuy(spend);
            _payOut(engine, toHolders);
            _payOut(team, toTeam);
            _payOut(tipTo, tip);
            return abi.encode(bought);
        }

        if (action == ACTION_PAYOUTS) {
            (, uint256 toHolders, uint256 toTeam) = abi.decode(data, (uint8, uint256, uint256));
            _payOut(engine, toHolders);
            _payOut(team, toTeam);
            return "";
        }

        revert HookNotImplemented();
    }

    // ------------------------------------------------------------------ views
    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function poolId() external view returns (PoolId) {
        return _key.toId();
    }

    /// @notice IMD claims this hook holds inside the PoolManager. Equals holdersOwed + burnBudget + teamOwed.
    function claimBalance() external view returns (uint256) {
        return poolManager.balanceOf(address(this), quoteId);
    }

    function taxBps(bool buy) external pure returns (uint256) {
        return buy ? BUY_TAX_BPS : SELL_TAX_BPS;
    }

    function burnReady() external view returns (bool) {
        return launched && burnBudget >= burnThreshold;
    }

    function inLaunchCapWindow() external view returns (bool) {
        return launchBuyCap > 0 && initBlock != 0 && L2Block.number() < uint256(initBlock) + launchCapBlocks
            && block.timestamp < uint256(launchStart) + launchCapSeconds
            && block.timestamp < uint256(launchStart) + LAUNCH_CAP_MAX_SECONDS;
    }

    // ------------------------------------------------------------------ internals
    function _split(uint256 fee, bool isBuy) internal {
        uint256 toHolders = fee * HOLDERS_BPS / BPS;
        uint256 toBurn = fee * BURN_BPS / BPS;
        holdersOwed += toHolders;
        burnBudget += toBurn;
        teamOwed += fee - toHolders - toBurn;
        totalTaxed += fee;
        emit FeeTaken(isBuy, fee);
    }

    /// @dev Burns `amount` of our IMD claims and sends the real IMD to `to`. Inside an unlock.
    function _payOut(address to, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.burn(address(this), quoteId, amount);
        poolManager.take(quote, to, amount);
    }

    /// @dev Spends `spend` IMD claims buying PIMD off our own pool, leaving the PIMD on this hook.
    function _swapBuy(uint256 spend) internal returns (uint256 bought) {
        _tstore(_INSWAP_SLOT, 1);
        BalanceDelta d = poolManager.swap(
            _key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(spend),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        _tstore(_INSWAP_SLOT, 0);
        uint256 owed0 = uint256(uint128(-d.amount0()));
        poolManager.burn(address(this), quoteId, owed0);
        bought = uint256(uint128(d.amount1()));
        poolManager.take(_key.currency1, address(this), bought);
        if (owed0 < spend) burnBudget += (spend - owed0); // anything the pool could not absorb goes back
    }

    function _tstore(uint256 slot, uint256 value) private {
        assembly {
            tstore(slot, value)
        }
    }

    function _tload(uint256 slot) private view returns (uint256 value) {
        assembly {
            value := tload(slot)
        }
    }

    receive() external payable {
        revert NoRawEth();
    }
}
