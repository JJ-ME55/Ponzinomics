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
    uint256 public constant BUY_TAX_BPS = 240; // 2.4%, and the pool charges 1.25% on top
    uint256 public constant SELL_TAX_BPS = 560; // 5.6%, likewise
    uint256 public constant HOLDERS_BPS = 7_500; // 75% of the tax; the team gets the remaining 25%
    /// @dev The burn takes nothing from the tax any more. It is funded by the pool's own 1.25% fee, which
    /// pays the launch's paying wallet: the PIMD half is burned as it arrives, the IMD half buys PIMD and
    /// burns that. Holders and the team keep exactly the share of a trade they had before.
    /// @dev Fail-open bound on the block-based launch cap. On Arbitrum Orbit `block.number` is the L1 block, so
    /// if the ArbSys precompile ever stopped answering, the block test alone would keep the cap on forever.
    uint256 public constant LAUNCH_CAP_MAX_SECONDS = 1 hours;
    /// @notice The tick the launch policy's 2,500 IMD opening cap implies on a one billion supply, with PIMD
    /// as currency1: 2.5e-6 IMD per PIMD. Initialization is refused outside the tolerance, so a mispriced
    /// pool fails loudly instead of opening.
    int24 public constant LAUNCH_TICK = 129_000;
    int24 public constant LAUNCH_TICK_TOLERANCE = 300;
    /// @notice Fee tiers the launch factory is allowed to open this pool with.
    uint24 internal constant FEE_TIER_LOW = 500;
    uint24 internal constant FEE_TIER_MID = 3_000;
    uint24 internal constant FEE_TIER_HIGH = 10_000;
    uint24 internal constant FEE_TIER_LAUNCH = 12_500;

    uint8 private constant ACTION_FLUSH = 2;

    uint256 private constant _FEE_SLOT = uint256(keccak256("pimd.hook.fee")) - 1;
    uint256 private constant _UNLOCK_SLOT = uint256(keccak256("pimd.hook.unlocking")) - 1;
    uint256 private constant _INSWAP_SLOT = uint256(keccak256("pimd.hook.inswap")) - 1;

    // ------------------------------------------------------------------ fixed wiring
    /// @dev The launch factory constructs this hook with the pool manager and the token and nothing else, so
    /// everything else it needs is written here rather than passed in. Both are read through `virtual`
    /// getters purely so tests can point them at local doubles; the production path returns these constants.
    address internal constant TEAM_WALLET = 0x0960E8Bd80462e3842Bb6620c7C5289A44c4559B;
    /// @dev The engine is deployed by us before the launch request goes out, and its address written here.
    address internal constant ENGINE_ADDRESS = 0x0000000000000000000000000000000000000000;

    uint32 public constant launchCapSeconds = 600;
    uint32 public constant launchCapBlocks = 6_000;
    uint128 public constant launchBuyCap = 25e18; // IMD one tx.origin may spend in the launch window
    uint128 public constant callerTip = 0.01e18; // paid to whoever calls flush, out of the team's slice only

    // ------------------------------------------------------------------ immutables
    IPoolManager public immutable poolManager;
    IPimdToken public immutable token;

    /// @notice The paired currency, learned from the pool key when the factory opens the pool.
    Currency public quote; // IMD
    uint256 public quoteId; // the ERC-6909 id of IMD claims

    /// @notice Receives the holders' slice as real IMD.
    function engine() public view virtual returns (address) {
        return ENGINE_ADDRESS;
    }

    /// @notice Receives the team's slice, always in IMD. It never holds or sells PIMD.
    function team() public view virtual returns (address) {
        return TEAM_WALLET;
    }

    // ------------------------------------------------------------------ state
    PoolKey internal _key;
    bool public launched;
    bool public seeded; // the factory's one liquidity add has happened
    uint64 public initBlock;
    uint64 public launchStart;

    uint256 public holdersOwed; // IMD claims waiting to go to the engine
    uint256 public teamOwed; // IMD claims waiting for the team

    uint256 public totalTaxed; // lifetime IMD taken as tax
    uint256 public totalToHolders; // lifetime IMD pushed to the engine
    uint256 public totalToTeam;

    mapping(address => uint256) public launchBuys;

    uint256 private _lock = 1;

    // ------------------------------------------------------------------ errors
    error NotPoolManager();
    error AlreadyLaunched();
    error UnsupportedFeeTier(uint24 fee);
    error PoolMustPairToken();
    error WrongStartingPrice(int24 got, int24 expected);
    error LiquidityIsLocked();
    error NotLaunched();
    error HookNotImplemented();
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
    event Launched(PoolId indexed id, int24 tick);
    event FeeTaken(bool indexed buy, uint256 fee);
    event Flushed(address indexed caller, uint256 toHolders, uint256 toTeam, uint256 tip);

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

    /// @param pm the pool manager, passed by the launch factory as $poolManager
    /// @param token_ the PIMD token, passed by the launch factory as $token
    constructor(IPoolManager pm, address token_) {
        if (address(pm) == address(0) || token_ == address(0)) revert BadConfig();
        poolManager = pm;
        token = IPimdToken(token_);
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // the pool must pair PIMD with IMD, at the briefed price
            afterInitialize: true,
            beforeAddLiquidity: true, // the factory seeds once; nobody adds after that
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true, // a withdrawal is refused forever; a zero delta is a fee collection
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

    // ------------------------------------------------------------------ hook callbacks
    /// @notice The launch factory opens the pool. This is the only chance to refuse a pool that would be
    /// wrong, so it checks everything the tax maths depends on and reverts rather than let a bad one open.
    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (launched) revert AlreadyLaunched();
        if (engine() == address(0) || team() == address(0)) revert BadConfig();
        if (
            key.fee != FEE_TIER_LAUNCH && key.fee != FEE_TIER_LOW && key.fee != FEE_TIER_MID
                && key.fee != FEE_TIER_HIGH
        ) revert UnsupportedFeeTier(key.fee);

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        // Every fee calculation in this contract assumes IMD is currency0 and PIMD currency1, exactly as
        // ETH/PULSE was in v1. We no longer mine the token's address, so refuse the other ordering instead
        // of opening a pool whose tax would be read backwards.
        if (c1 != address(token)) revert PoolMustPairToken();
        if (c0 == address(token) || c0 == address(0)) revert BadCurrencyOrder();

        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        if (tick < LAUNCH_TICK - LAUNCH_TICK_TOLERANCE || tick > LAUNCH_TICK + LAUNCH_TICK_TOLERANCE) {
            revert WrongStartingPrice(tick, LAUNCH_TICK);
        }

        quote = key.currency0;
        quoteId = uint256(uint160(c0));
        _key = key;
        launched = true;
        initBlock = uint64(L2Block.number());
        launchStart = uint64(block.timestamp);
        emit Launched(key.toId(), tick);
        return IHooks.beforeInitialize.selector;
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

    /// @notice The factory seeds the pool once, at launch. Nobody adds liquidity to this pool after that.
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (seeded) revert LiquidityIsLocked();
        seeded = true;
        return IHooks.beforeAddLiquidity.selector;
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

    /// @notice Liquidity can never leave this pool. V4 routes both a withdrawal and a fee collection here:
    /// a negative delta is a withdrawal and is refused forever, from anybody, including whoever owns the
    /// position. A zero delta is the pool's own fee being collected, which is allowed, so the fee still
    /// reaches the wallets it is owed to.
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (params.liquidityDelta < 0) revert LiquidityIsLocked();
        return IHooks.beforeRemoveLiquidity.selector;
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
    /// @notice Permissionless. Pushes the holders' IMD to the engine and the team's to the team wallet.
    /// It never touches the pool, so a pool that cannot be swapped against can never stop the drip. The
    /// caller's tip comes out of the team's slice, never out of holders.
    function flush() external nonReentrant returns (uint256 toHolders, uint256 toTeam) {
        if (!launched) revert NotLaunched();
        toHolders = holdersOwed;
        toTeam = teamOwed;
        if (toHolders == 0 && toTeam == 0) revert NothingPending();
        uint256 tip = callerTip;
        if (tip > toTeam) tip = toTeam;
        holdersOwed = 0;
        teamOwed = 0;

        _tstore(_UNLOCK_SLOT, 1);
        poolManager.unlock(abi.encode(ACTION_FLUSH, toHolders, toTeam - tip, msg.sender, tip));
        _tstore(_UNLOCK_SLOT, 0);

        totalToHolders += toHolders;
        totalToTeam += toTeam;
        emit Flushed(msg.sender, toHolders, toTeam, tip);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (_tload(_UNLOCK_SLOT) != 1) revert NotUnlocking();
        uint8 action = abi.decode(data, (uint8));

        if (action == ACTION_FLUSH) {
            (, uint256 toHolders, uint256 toTeam, address tipTo, uint256 tip) =
                abi.decode(data, (uint8, uint256, uint256, address, uint256));
            _payOut(engine(), toHolders);
            _payOut(team(), toTeam);
            _payOut(tipTo, tip);
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

    /// @notice IMD claims this hook holds inside the PoolManager. Equals holdersOwed + teamOwed.
    function claimBalance() external view returns (uint256) {
        return poolManager.balanceOf(address(this), quoteId);
    }

    function taxBps(bool buy) external pure returns (uint256) {
        return buy ? BUY_TAX_BPS : SELL_TAX_BPS;
    }



    function inLaunchCapWindow() external view returns (bool) {
        return launchBuyCap > 0 && initBlock != 0 && L2Block.number() < uint256(initBlock) + launchCapBlocks
            && block.timestamp < uint256(launchStart) + launchCapSeconds
            && block.timestamp < uint256(launchStart) + LAUNCH_CAP_MAX_SECONDS;
    }

    // ------------------------------------------------------------------ internals
    function _split(uint256 fee, bool isBuy) internal {
        uint256 toHolders = fee * HOLDERS_BPS / BPS;
        holdersOwed += toHolders;
        teamOwed += fee - toHolders;
        totalTaxed += fee;
        emit FeeTaken(isBuy, fee);
    }

    /// @dev Burns `amount` of our IMD claims and sends the real IMD to `to`. Inside an unlock.
    function _payOut(address to, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.burn(address(this), quoteId, amount);
        poolManager.take(quote, to, amount);
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
