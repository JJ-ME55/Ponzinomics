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
/// 2.4% on buys, 5.6% on sells. The tax is held as ERC-6909 claims inside the PoolManager and split two ways:
///
///   * 75% to holders, pushed to the engine, which drips it into wallets by hold-streak,
///   * 25% to the team, always in IMD, so the team never has to sell PIMD to be paid.
///
/// The burn takes nothing from the tax. The launch policy makes the pool charge 1.25% of every trade and pays
/// it to the launch's paying wallet; all of that buys PIMD and burns it, outside this contract. A trade
/// therefore costs 3.65% to buy and 6.85% to sell, and holders and the team receive the same share of a trade
/// they would have under the old 3%/7% with a 60/20/20 split.
///
/// The pool is opened and seeded by the IMD launch factory, not by this contract, single-sided in PIMD. This
/// hook's job at launch is to refuse a pool that would be wrong: `beforeInitialize` is the only gate, and it
/// checks the caller, the pairing, the quote currency, the fee tier and the opening price.
///
/// @dev This is PULSE v1's hook with the quote asset changed from native ETH to an ERC-20, the emissions
/// removed, and the launch handed to the factory. Things that deserve an audit's attention: fee claims are
/// minted against `uint256(uint160(IMD))` rather than currency id 0; paying IMD out means burning claims and
/// `take`-ing; every fee calculation assumes **IMD is currency0**, which `beforeInitialize` enforces rather
/// than assumes; and liquidity can never leave this pool, because `beforeRemoveLiquidity` refuses every
/// negative delta from every caller forever, which is what makes it safe for the factory to hold the position.
///
/// What is deliberately absent, because we are not using it and every line is audit surface: minting of any
/// kind, the decaying launch tax (the engine's 0x first hour does that job), the burn party, the large-sell
/// booster, and the buy-and-burn that used to live here. There is no owner, no admin and no launcher: the team
/// wallet, the engine, the quote and the factory are written into the source and cannot be changed.
contract PimdHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------ constants
    uint256 public constant BPS = 10_000;
    uint256 public constant BUY_TAX_BPS = 240; // 2.4%, and the pool charges 1.25% on top
    uint256 public constant SELL_TAX_BPS = 560; // 5.6%, likewise
    uint256 public constant HOLDERS_BPS = 7_500; // 75% of the tax; the team gets the remaining 25%
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
    uint8 private constant ACTION_HOLDERS = 4;

    uint256 private constant _FEE_SLOT = uint256(keccak256("pimd.hook.fee")) - 1;
    uint256 private constant _UNLOCK_SLOT = uint256(keccak256("pimd.hook.unlocking")) - 1;
    uint256 private constant _SPEC_SLOT = uint256(keccak256("pimd.hook.specified")) - 1;

    // ------------------------------------------------------------------ fixed wiring
    /// @dev The launch factory constructs this hook with the pool manager and the token and nothing else, so
    /// everything else it needs is written here rather than passed in. Both are read through `virtual`
    /// getters purely so tests can point them at local doubles; the production path returns these constants.
    address internal constant TEAM_WALLET = 0x0960E8Bd80462e3842Bb6620c7C5289A44c4559B;
    /// @dev The engine is deployed by us before the launch request goes out, and its address written here.
    address internal constant ENGINE_ADDRESS = 0xB64F3007CF10741DbB61052ADBFa3274C8D616b8;
    /// @dev IMD on Robinhood Chain. Every fee calculation, the ERC-6909 claim id and the engine's booking all
    /// assume the quote is this token specifically, so the pool is refused if it is anything else.
    address internal constant QUOTE_TOKEN = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    /// @dev The launch factory, the only address allowed to open this pool and to seed it. PoolManager's
    /// initialize is permissionless and this hook launches exactly once, so without this a stranger can
    /// spend the launch on a pool of their choosing, or squat the single seed and brick the real one.
    address internal constant LAUNCH_FACTORY = 0xA25B02A1e93903b790E6aaf7dA1b8B8d50294645;

    uint32 public constant launchCapSeconds = 600;
    uint32 public constant launchCapBlocks = 6_000;
    uint128 public constant launchBuyCap = 25e18; // IMD one tx.origin may spend in the launch window
    uint128 public constant callerTip = 0.01e18; // paid to whoever calls flush, out of the team's slice only
    /// @notice The most of the team's slice one flush may pay the caller, in bps. Keeps the flat `callerTip`
    /// from swallowing the whole slice when little has accrued since the last flush.
    uint256 public constant TIP_MAX_BPS = 2_000; // 20%

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

    /// @notice The only currency this pool may be quoted in.
    function quoteToken() public view virtual returns (address) {
        return QUOTE_TOKEN;
    }

    /// @notice The only address that may open this pool and seed it.
    function launchFactory() public view virtual returns (address) {
        return LAUNCH_FACTORY;
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
    error PartialFill(uint256 wanted, uint256 filled);
    error NotLaunchFactory();
    error WrongQuoteCurrency(address got);
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
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (launched) revert AlreadyLaunched();
        // initialize is permissionless on the PoolManager and this hook launches exactly once, so anyone
        // could otherwise spend the launch on a pool of their own choosing before the factory gets there.
        if (sender != launchFactory()) revert NotLaunchFactory();
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
        // Not merely "something that sorts below PIMD": the tax is taken in this token, the claim id is
        // derived from it and the engine only ever books this token, so anything else is unrecoverable.
        if (c0 != quoteToken()) revert WrongQuoteCurrency(c0);

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
        if (L2Block.number() == initBlock) revert InitBlockSwap();

        uint256 fee;
        // The IMD side is the *specified* amount on an exact-in buy and an exact-out sell. Take the tax there.
        if ((params.amountSpecified < 0) == params.zeroForOne) {
            uint256 amt =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 bps = params.zeroForOne ? BUY_TAX_BPS : SELL_TAX_BPS;
            fee = params.amountSpecified < 0 ? amt * bps / BPS : amt * bps / (BPS - bps);
            if (fee > 0) poolManager.mint(address(this), quoteId, fee);
            // Remember what was asked for. The fee is computed here, before the pool decides how much it
            // can actually fill, so afterSwap has to check the two were the same.
            _tstore(_SPEC_SLOT, amt);
        }
        _tstore(_FEE_SLOT, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        uint256 fee = _tload(_FEE_SLOT);
        uint256 specified = _tload(_SPEC_SLOT);
        _tstore(_FEE_SLOT, 0);
        _tstore(_SPEC_SLOT, 0);
        int128 hookDeltaUnspecified;

        // When IMD is the specified side the tax was taken in beforeSwap, against the amount asked for,
        // before the pool knew how much of it would fill. A swap stopped by its price limit or by the end
        // of the range would then pay the full tax on IMD that never traded. Refusing it is the only
        // honest option here: V4 lets afterSwap return a delta on the unspecified side only, so the
        // overcharge cannot be handed back in IMD. The swapper loses nothing and simply tries again.
        if (specified != 0) {
            int128 a0q = delta.amount0();
            uint256 movedQuote = a0q < 0 ? uint256(uint128(-a0q)) : uint256(uint128(a0q));
            uint256 wanted = params.amountSpecified < 0 ? specified - fee : specified + fee;
            if (movedQuote != wanted) revert PartialFill(wanted, movedQuote);
        }

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
    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        // The seed belongs to the factory. Without this, a stranger adding one wei first consumes the only
        // permitted add and the factory's real seed reverts.
        if (sender != launchFactory()) revert NotLaunchFactory();
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
    /// @notice Pays the holders' slice to the engine and nothing else. `flush` pays the engine, the team
    /// and the caller's tip in one unlock, so if IMD ever refused the team wallet the holders' IMD would be
    /// stranded here with it. This path cannot be blocked by anything the team wallet does, and anyone can
    /// call it.
    function flushHolders() external nonReentrant returns (uint256 toHolders) {
        if (!launched) revert NotLaunched();
        toHolders = holdersOwed;
        if (toHolders == 0) revert NothingPending();
        holdersOwed = 0;

        _tstore(_UNLOCK_SLOT, 1);
        poolManager.unlock(abi.encode(ACTION_HOLDERS, toHolders));
        _tstore(_UNLOCK_SLOT, 0);

        totalToHolders += toHolders;
        emit Flushed(msg.sender, toHolders, 0, 0);
    }

    /// @notice Permissionless. Pushes the holders' IMD to the engine and the team's to the team wallet.
    /// It never touches the pool, so a pool that cannot be swapped against can never stop the drip. The
    /// caller's tip comes out of the team's slice, never out of holders.
    function flush() external nonReentrant returns (uint256 toHolders, uint256 toTeam) {
        if (!launched) revert NotLaunched();
        toHolders = holdersOwed;
        toTeam = teamOwed;
        if (toHolders == 0 && toTeam == 0) revert NothingPending();
        // The tip is capped both absolutely and as a share of what the team is owed. Without the second
        // cap a bot flushing after every small trade took the whole team slice: below 1.667 IMD of buys
        // or 0.714 IMD of sells the flat tip exceeded the team's cut, so `toTeam - tip` was zero every
        // time. The team now always keeps the large majority of its slice, whatever the trade size.
        // The engine calls this on its own income path, and whatever it is paid it books as holder
        // income. Tipping it would therefore move the tip out of the team's slice and into the holders'
        // pot on every fire, while `totalToTeam` still recorded it as paid to the team. The fire keeper is
        // already paid from the engine's own tip budget, so no one needed that payment.
        uint256 tip = msg.sender == engine() ? 0 : callerTip;
        uint256 cap = (toTeam * TIP_MAX_BPS) / BPS;
        if (tip > cap) tip = cap;
        holdersOwed = 0;
        teamOwed = 0;

        _tstore(_UNLOCK_SLOT, 1);
        poolManager.unlock(abi.encode(ACTION_FLUSH, toHolders, toTeam - tip, msg.sender, tip));
        _tstore(_UNLOCK_SLOT, 0);

        totalToHolders += toHolders;
        // Net of the tip, because that is what the team actually received. Booking the gross overstated
        // it by every outside caller's tip, compounding on every flush, and the engine's own path was
        // only the loud half of that. The `Flushed` event still carries both numbers.
        totalToTeam += toTeam - tip;
        emit Flushed(msg.sender, toHolders, toTeam, tip);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (_tload(_UNLOCK_SLOT) != 1) revert NotUnlocking();
        uint8 action = abi.decode(data, (uint8));

        if (action == ACTION_HOLDERS) {
            (, uint256 toHolders) = abi.decode(data, (uint8, uint256));
            _payOut(engine(), toHolders);
            return "";
        }

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
