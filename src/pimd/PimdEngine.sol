// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IExttload} from "v4-core/src/interfaces/IExttload.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IPimdHookLike {
    function flush() external returns (uint256, uint256);
    function holdersOwed() external view returns (uint256);
}

interface IPairLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @title PimdEngine
/// @notice Where the holders' 60% ends up. The hook pushes IMD here; this contract releases it on a time curve
/// and pushes it into holders' wallets, weighted by PIMD balance times hold-streak tier:
///
///   under an hour 0x · to a day 0.5x · to three days 1x · to a week 1.5x · to two weeks 2x · after that 3x
///
/// Selling or sending PIMD out restarts the clock; buying more blends it by size, so fresh tokens never inherit
/// an old streak. Payouts are pushed, never claimed, and are paid in IMD, so a holder's PIMD balance is
/// untouched by being paid and the streak keeps running.
///
/// @dev No owner. The `binder` named at construction may call `bind` exactly once; after that nothing about this
/// contract can change. It is a constructor argument rather than msg.sender on purpose: the contracts are built
/// to survive being deployed by somebody else (the IMD swarm deploys from its own wallet), so the one-shot
/// power belongs to the address the deploy names, not to whoever sent the deployment transaction.
/// Weights are read from `balanceOf` on chain, so a keeper can suggest which addresses to process but never how
/// much anybody gets.
///
/// Two things here exist because of the adversarial pass on this design, and both matter:
///
/// 1. `fire`, `tally` and `pay` refuse to run while the PoolManager is unlocked. Inside an unlock a flash
///    borrower can hold an enormous PIMD balance for the length of one callback, and weights are read from
///    balances. v1 was exposed to exactly this. Outside an unlock the borrow cannot exist.
/// 2. Every IMD transfer is a gas-capped low-level call whose failure is caught. IMD is somebody else's token
///    and its owner's powers are not public; if it ever refuses one address, that address is skipped and its
///    share returns to the pot rather than stalling the whole batch.
contract PimdEngine is ReentrancyGuard {
    // ------------------------------------------------------------------ constants
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PERIOD = 15 minutes;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SEND_GAS = 60_000;
    uint256 internal constant PROBE_GAS = 30_000;
    uint256 internal constant TIP_BUDGET_BPS = 500; // keeper tips never exceed 5% of an epoch's drip
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @dev bytes32(uint256(keccak256("Unlocked")) - 1), the PoolManager's transient unlock flag.
    bytes32 internal constant IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    // ------------------------------------------------------------------ immutable config
    IPoolManager public immutable poolManager;
    IERC20Min public immutable imd; // the payout asset
    address public immutable team;
    address public immutable binder; // may call bind() exactly once, then it is spent
    uint256 public immutable dripBpsPerPeriod; // share of the pot released per 15 minutes, pro-rated by time
    uint256 public immutable minInterval; // floor between epochs
    uint256 public immutable minBalance; // smallest bag that gets paid (and may register)
    uint256 public immutable fireTip; // IMD paid to whoever fires an epoch
    uint256 public immutable tipPerHolder; // IMD paid per holder processed in tally/pay
    /// @notice The most elapsed time one epoch's release may account for. Without it a long gap between epochs
    /// (a dead keeper, mostly) would hand the entire accumulated pot to whoever happened to be holding at the
    /// moment it restarted. Set it to roughly the intended epoch cadence: too low and a slow cadence can never
    /// release the pot, too high and a gap becomes a payday.
    uint256 public immutable maxCatchup;

    struct Config {
        address poolManager;
        address imd;
        address team;
        address binder; // who may call bind() once; not necessarily whoever deploys
        uint256 dripBpsPerPeriod;
        uint256 minInterval;
        uint256 minBalance;
        uint256 fireTip;
        uint256 tipPerHolder;
        uint256 maxCatchup;
    }

    // ------------------------------------------------------------------ bound state
    bool public bound;
    address public token; // PIMD
    IPimdHookLike public hook;
    mapping(address => bool) public excluded;

    // ------------------------------------------------------------------ IMD ledger: pot + epochQuote <= balance
    uint256 public pot; // IMD waiting to be dripped
    uint256 public epochQuote; // IMD reserved for the epoch being paid out

    // ------------------------------------------------------------------ lifetime stats (read by the site)
    uint256 public totalIncome;
    uint256 public totalSeeded;
    uint256 public totalDripped;
    uint256 public totalPayouts; // number of individual payouts made

    // ------------------------------------------------------------------ holders + epochs
    struct Holder {
        uint128 lastBal; // PIMD balance at the last tally
        uint64 streakStart; // blended hold clock
        uint64 index1; // 1-based index into `holders`; 0 = not registered
        uint128 weight; // this epoch's weight, set in tally and cleared in pay
        uint128 received; // lifetime IMD received from this engine
    }

    enum Phase {
        Idle,
        Tally,
        Pay
    }

    mapping(address => Holder) internal _holder;
    address[] internal holders;

    Phase public phase;
    uint256 public epoch;
    uint256 public lastFire;
    uint256 public cursor;
    uint256 public epochCount; // holders snapshot for the running epoch
    uint256 public totalWeight;
    uint256 internal epochPaidHolders;
    uint256 internal epochPaidQuote; // IMD actually paid out so far this epoch
    uint256 public tipBudget; // what is left of this epoch's keeper tips

    // ------------------------------------------------------------------ events
    event Bound(address indexed token, address indexed hook);
    event Seeded(address indexed from, uint256 amount);
    event Income(uint256 amount);
    event Fired(uint256 indexed epoch, uint256 imdForHolders, uint256 holderCount);
    event EpochPaid(uint256 indexed epoch, uint256 imdPaid, uint256 holdersPaid);
    event PayoutFailed(address indexed holder, uint256 amount);
    event Registered(address indexed holder);
    event Pruned(address indexed holder);

    // ------------------------------------------------------------------ errors
    error NotBinder();
    error AlreadyBound();
    error NotBound();
    error WrongPhase();
    error TooSoon();
    error BadConfig();
    error PoolUnlocked();

    constructor(Config memory c) {
        if (c.poolManager == address(0) || c.imd == address(0) || c.team == address(0) || c.binder == address(0)) {
            revert BadConfig();
        }
        if (c.dripBpsPerPeriod == 0 || c.dripBpsPerPeriod > 5_000) revert BadConfig();
        if (c.maxCatchup < PERIOD || c.maxCatchup > 7 days) revert BadConfig();
        poolManager = IPoolManager(c.poolManager);
        imd = IERC20Min(c.imd);
        team = c.team;
        binder = c.binder;
        dripBpsPerPeriod = c.dripBpsPerPeriod;
        minInterval = c.minInterval;
        minBalance = c.minBalance;
        fireTip = c.fireTip;
        tipPerHolder = c.tipPerHolder;
        maxCatchup = c.maxCatchup;
    }

    // ================================================================== one-time setup
    /// @notice Links the engine to its token and hook. Callable once, by the binder named at construction, after the hook
    /// has launched the pool with this engine as its payout target.
    function bind(address token_, address hook_) external {
        if (msg.sender != binder) revert NotBinder();
        if (bound) revert AlreadyBound();
        if (token_ == address(0) || hook_ == address(0)) revert BadConfig();
        bound = true;
        token = token_;
        hook = IPimdHookLike(hook_);
        lastFire = block.timestamp;

        address[6] memory ex = [hook_, address(poolManager), address(this), team, address(0), DEAD];
        for (uint256 i; i < ex.length; ++i) {
            excluded[ex[i]] = true;
        }
        emit Bound(token_, hook_);
    }

    /// @notice Adds IMD straight to the payout pot. Anyone may top up the holders' pot; nothing can take it out
    /// except the drip.
    function seed(uint256 amount) external nonReentrant {
        require(imd.transferFrom(msg.sender, address(this), amount));
        pot += amount;
        totalSeeded += amount;
        emit Seeded(msg.sender, amount);
    }

    // ================================================================== holders
    /// @notice Registers addresses for drips. Anyone may call; addresses that are excluded, already registered,
    /// below the minimum bag, or pool-like contracts holding PIMD are skipped.
    function register(address[] calldata accounts) external {
        if (!bound) revert NotBound();
        for (uint256 i; i < accounts.length; ++i) {
            address a = accounts[i];
            if (excluded[a] || _holder[a].index1 != 0) continue;
            uint256 bal = IERC20Min(token).balanceOf(a);
            if (bal < minBalance || _isPool(a)) continue;
            holders.push(a);
            Holder storage h = _holder[a];
            h.index1 = uint64(holders.length);
            h.lastBal = uint128(bal);
            h.streakStart = uint64(block.timestamp); // the clock starts at registration, never earlier
            emit Registered(a);
        }
    }

    /// @notice Removes registered holders whose bag has fallen below the minimum, keeping the tally loop lean.
    /// Only between epochs, so a running epoch's snapshot never moves.
    function prune(address[] calldata accounts) external {
        if (phase != Phase.Idle) revert WrongPhase();
        for (uint256 i; i < accounts.length; ++i) {
            address a = accounts[i];
            uint256 idx1 = _holder[a].index1;
            if (idx1 == 0 || IERC20Min(token).balanceOf(a) >= minBalance) continue;
            address last = holders[holders.length - 1];
            holders[idx1 - 1] = last;
            _holder[last].index1 = uint64(idx1);
            holders.pop();
            delete _holder[a];
            emit Pruned(a);
        }
    }

    // ================================================================== the epoch
    /// @notice Pulls whatever the hook is holding, books it as income, releases this epoch's slice of the pot
    /// and opens a distribution. Permissionless; pays `fireTip` to the caller out of the epoch's tip budget.
    function fire() external nonReentrant {
        if (!bound) revert NotBound();
        if (phase != Phase.Idle) revert WrongPhase();
        if (block.timestamp < lastFire + minInterval) revert TooSoon();
        _requireLocked();

        // Best effort: a hook-side problem may delay income but must never block a drip.
        if (hook.holdersOwed() != 0) {
            try hook.flush() {} catch {}
        }
        _book();

        uint256 elapsed = block.timestamp - lastFire;
        uint256 drip = _released(pot, elapsed);
        lastFire = block.timestamp;
        tipBudget = (drip * TIP_BUDGET_BPS) / BPS;

        uint256 n = holders.length;
        emit Fired(epoch + 1, drip, n);
        if (drip != 0 && n != 0) {
            pot -= drip;
            epochQuote = drip;
            epoch += 1;
            phase = Phase.Tally;
            cursor = 0;
            epochCount = n;
            totalWeight = 0;
            epochPaidHolders = 0;
        }
        _tip(fireTip);
    }

    /// @notice First pass: reads each holder's PIMD balance, updates the hold streak, records this epoch's weight.
    function tally(uint256 maxHolders) external nonReentrant {
        if (phase != Phase.Tally) revert WrongPhase();
        _requireLocked();
        uint256 start = cursor;
        uint256 end = start + maxHolders;
        if (end > epochCount) end = epochCount;
        uint256 tw = totalWeight;
        uint256 nowTs = block.timestamp;
        for (uint256 i = start; i < end; ++i) {
            address a = holders[i];
            Holder storage h = _holder[a];
            uint256 bal = IERC20Min(token).balanceOf(a);
            uint256 last = h.lastBal;
            if (bal < last) {
                h.streakStart = uint64(nowTs); // sold or sent out: the clock restarts
            } else if (bal > last) {
                // bought or received: blend by size, so fresh tokens never inherit an old streak
                h.streakStart = uint64((last * h.streakStart + (bal - last) * nowTs) / bal);
            }
            h.lastBal = uint128(bal);
            uint256 w;
            if (bal >= minBalance && !_isPool(a)) w = (bal * tierBps(nowTs - h.streakStart)) / BPS;
            h.weight = uint128(w);
            tw += w;
        }
        totalWeight = tw;
        cursor = end;
        if (end == epochCount) {
            cursor = 0;
            if (tw == 0) {
                // nobody eligible yet (the first hour, typically): the IMD goes back and waits
                pot += epochQuote;
                epochQuote = 0;
                phase = Phase.Idle;
            } else {
                phase = Phase.Pay;
            }
        }
        _tip(tipPerHolder * (end - start));
    }

    /// @notice Second pass: pays each holder their share of this epoch's IMD.
    function pay(uint256 maxHolders) external nonReentrant {
        if (phase != Phase.Pay) revert WrongPhase();
        _requireLocked();
        uint256 start = cursor;
        uint256 end = start + maxHolders;
        if (end > epochCount) end = epochCount;
        // The epoch's total and its weight denominator are both frozen, so a holder's share does not depend on
        // which page it lands in, or on whether an earlier payout failed.
        uint256 total = epochQuote;
        uint256 tw = totalWeight;
        uint256 paid;
        uint256 paidHolders;
        for (uint256 i = start; i < end; ++i) {
            address a = holders[i];
            Holder storage h = _holder[a];
            uint256 w = h.weight;
            if (w == 0) continue;
            h.weight = 0;
            uint256 amt = FullMath.mulDiv(total, w, tw);
            if (amt == 0) continue;
            if (_send(a, amt)) {
                h.received += uint128(amt);
                paid += amt;
                ++paidHolders;
            } else {
                // IMD refused this address. Its share is simply not paid, and falls into the leftover below.
                emit PayoutFailed(a, amt);
            }
        }
        epochPaidQuote += paid;
        totalDripped += paid;
        totalPayouts += paidHolders;
        epochPaidHolders += paidHolders;
        cursor = end;
        if (end == epochCount) {
            cursor = 0;
            phase = Phase.Idle;
            // whatever floor division left behind, plus anything a refused address did not take
            uint256 leftover = total - epochPaidQuote;
            if (leftover != 0) pot += leftover;
            epochQuote = 0;
            epochPaidQuote = 0;
            emit EpochPaid(epoch, epochPaidHolders == 0 ? 0 : total - leftover, epochPaidHolders);
        }
        _tip(tipPerHolder * (end - start));
    }

    // ================================================================== views
    /// @notice The hold-streak ladder, in bps. 10_000 is 1x.
    function tierBps(uint256 age) public pure returns (uint256) {
        if (age < 1 hours) return 0;
        if (age < 1 days) return 5_000;
        if (age < 3 days) return 10_000;
        if (age < 7 days) return 15_000;
        if (age < 14 days) return 20_000;
        return 30_000;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function holderAt(uint256 i) external view returns (address) {
        return holders[i];
    }

    /// @return registered_ whether the address is registered
    /// @return lastBal_ PIMD balance at the last tally
    /// @return streakStart_ blended hold-clock start
    /// @return tierBps_ current tier in bps (10_000 = 1x)
    /// @return received_ lifetime IMD received from this engine
    function holderInfo(address a)
        external
        view
        returns (bool registered_, uint256 lastBal_, uint256 streakStart_, uint256 tierBps_, uint256 received_)
    {
        Holder memory h = _holder[a];
        registered_ = h.index1 != 0;
        lastBal_ = h.lastBal;
        streakStart_ = h.streakStart;
        tierBps_ = registered_ ? tierBps(block.timestamp - h.streakStart) : 0;
        received_ = h.received;
    }

    function nextFireAt() external view returns (uint256) {
        return lastFire + minInterval;
    }

    /// @notice IMD the pot would release if an epoch fired right now, before any new income.
    function dripPreview() external view returns (uint256) {
        return _released(pot, block.timestamp - lastFire);
    }

    /// @notice IMD sitting at the hook that the next fire will pull in.
    function pendingAtHook() external view returns (uint256) {
        return bound ? hook.holdersOwed() : 0;
    }

    // ================================================================== internals
    /// Books every IMD that arrived since the last look as income to the pot.
    function _book() internal {
        uint256 tracked = pot + epochQuote;
        uint256 bal = imd.balanceOf(address(this));
        if (bal <= tracked) return;
        uint256 income = bal - tracked;
        pot += income;
        totalIncome += income;
        emit Income(income);
    }

    /// Weights come from balances, and inside a PoolManager unlock a balance can be borrowed for one callback.
    function _requireLocked() internal view {
        if (IExttload(address(poolManager)).exttload(IS_UNLOCKED_SLOT) != bytes32(0)) revert PoolUnlocked();
    }

    /// amount x (1 - (1 - r)^(elapsed / 15 min)): whole periods compound, the partial period is linear.
    function _released(uint256 p, uint256 elapsed) internal view returns (uint256) {
        if (p == 0 || elapsed == 0) return 0;
        if (elapsed > maxCatchup) elapsed = maxCatchup; // a gap never becomes a payday
        uint256 keepPerPeriod = WAD - (dripBpsPerPeriod * WAD) / BPS;
        uint256 keep = _pow(keepPerPeriod, elapsed / PERIOD);
        uint256 frac = elapsed % PERIOD;
        keep = (keep * (WAD - (dripBpsPerPeriod * WAD * frac) / (BPS * PERIOD))) / WAD;
        return p - FullMath.mulDiv(p, keep, WAD);
    }

    function _pow(uint256 base, uint256 n) internal pure returns (uint256 r) {
        r = WAD;
        while (n != 0) {
            if (n & 1 != 0) r = (r * base) / WAD;
            base = (base * base) / WAD;
            n >>= 1;
        }
    }

    /// A gas-capped IMD transfer whose failure is survivable: IMD is not our contract, and an address it
    /// refuses must not be able to stall everyone else's payout.
    function _send(address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) =
            address(imd).call{gas: SEND_GAS}(abi.encodeCall(IERC20Min.transfer, (to, amount)));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }

    /// Pays the caller from the pot, but only out of this epoch's tip budget (5% of what the epoch released),
    /// so a quiet market or a spammy caller can never turn keeper tips into a drain on holders.
    function _tip(uint256 amt) internal {
        uint256 budget = tipBudget;
        if (amt > budget) amt = budget;
        if (amt == 0 || pot < amt) return;
        tipBudget = budget - amt;
        pot -= amt;
        if (!_send(msg.sender, amt)) {
            pot += amt;
            tipBudget = budget;
        }
    }

    /// True for a contract that reports PIMD as either side of a pair: a rogue V2/V3-style pool must not collect
    /// drips that its LPs would then capture.
    /// @dev Runs inside the tally loop, so a hostile holder contract must not be able to stall an epoch: each
    /// probe is a gas-capped staticcall that reads at most one word of return data.
    function _isPool(address a) internal view returns (bool) {
        if (a.code.length == 0) return false;
        address t = token;
        return _probe(a, IPairLike.token0.selector) == t || _probe(a, IPairLike.token1.selector) == t;
    }

    function _probe(address a, bytes4 sel) internal view returns (address out) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, sel)
            let ok := staticcall(PROBE_GAS, a, ptr, 4, ptr, 32)
            if and(ok, gt(returndatasize(), 31)) { out := mload(ptr) }
        }
    }
}
