# 02 — Swap accounting and fee maths

**Baseline:** `src/` at HEAD `e9d2da4` (verified byte-identical to the working tree at the time of writing; a
concurrent mutation-testing lane transiently injected `// MUTANT` edits into `PimdHook.beforeAddLiquidity`,
`PimdHook.beforeRemoveLiquidity`, `PimdEngine._requireLocked` and `PimdEngine._isPool` during this pass and
reverted them. All line numbers below are HEAD `e9d2da4`.)

**Lens:** every wei that moves on the swap path — `beforeSwap`, `afterSwap`, the `BeforeSwapDelta` /
`hookDeltaUnspecified` sign conventions, the new `PartialFill` guard, the mint↔book invariant,
`flush`/`flushHolders`/`unlockCallback`/`_split`/`_payOut`, rounding, and the launch cap.

**V4 semantics were verified against the vendored source**, not from memory:
`lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol` (`beforeSwap`, `afterSwap`),
`.../PoolManager.sol` (`swap`, `_swap`, `mint`, `burn`, `take`), `.../libraries/Pool.sol` (`swap`),
`.../libraries/SwapMath.sol` (`computeSwapStep`), `.../types/BeforeSwapDelta.sol`.

---

## Summary

| # | Severity | Where | What |
|---|---|---|---|
| 1 | **Medium** | `PimdHook.sol:105,432-433,461` | The fixed `callerTip` lets any permissionless flusher capture up to **100 %** of the team's 25 % slice. Unfixable post-deploy (`constant`, no owner). |
| 2 | **Medium** | `PimdEngine.sol:273-275` + `PimdHook.sol:407` | The fix for prior-audit #5 is **not wired in**: `fire()` still calls `flush()`, not `flushHolders()`, and `IPimdHookLike` does not even declare it. The stranding scenario the fix was written for still halts the automated drip, silently. |
| 3 | **Low** | `PimdHook.sol:281,310-311` | Exact-out sells can never withdraw the last **5.6 %** of the pool's IMD — they revert `PartialFill`. Front-runnable into a free grief. |
| 4 | **Low** | `PimdHook.sol:334-336` | `launchBuys` keyed on `tx.origin`: ~free to bypass with N EOAs, and it collapses every user behind one relayer / ERC-4337 bundler into a single 25 IMD cap that an attacker can burn deliberately. (`spent` itself is **correct**.) |
| 5 | **Low** | `PimdHook.sol:442`, `:478`, `PimdEngine.sol:29` | Three accounting/doc defects: `totalToTeam` includes the tip the team never got; the documented `claimBalance() == holdersOwed + teamOwed` invariant is breakable by anyone donating ERC-6909 claims (permanently stranded); engine NatSpec still says "the holders' 60 %". |
| 6 | **Info** | `PimdHook.sol:283-287` | `_SPEC_SLOT` is written only inside the specified-side branch while `_FEE_SLOT` is written unconditionally. Safe today only because `afterSwap` always runs and always zeroes both. One early return away from stale-slot double-booking — the `_INSWAP_SLOT` branch removed in `e9d2da4` was exactly that shape. |

**Cross-reference, not re-reported:** the `prune`-during-`Tally` → `tally` array-out-of-bounds brick
introduced by commit `f5d85fc` is already found, reproduced and asserted by three other lanes
(`test/pimd/ZzAuditLifecycle.t.sol::test_F1_*`, `ZZArith.t.sol::test_A_*`, `AuditProbe06.t.sol::test_probe_*`).
I confirm it independently: `prune` pops from `holders` while `fire()` froze `epochCount` at the old length,
and `tally`'s `for (i = start; i < epochCount; ++i) { holders[i] }` (`PimdEngine.sol:312-315`) then panics
`0x32` forever. The commit message claims it *un*-bricks the atomic tally; it cannot, because pruning never
reduces `epochCount`, so the set `tally` iterates is unchanged in size. **A wrong fix, and the headline
finding of this audit overall** — it just is not mine to re-litigate.

---

## Finding 1 — Medium: the fixed `callerTip` lets a bot take 100 % of the team's slice

`src/pimd/PimdHook.sol:105`, `:432-433`, `:438`, `:461`

```solidity
uint128 public constant callerTip = 0.01e18; // paid to whoever calls flush, out of the team's slice only
...
uint256 tip = callerTip;
if (tip > toTeam) tip = toTeam;
...
poolManager.unlock(abi.encode(ACTION_FLUSH, toHolders, toTeam - tip, msg.sender, tip));
```

The tip is an **absolute** amount, not a fraction, and `flush()` is permissionless and callable after any
single taxed trade (`NothingPending` only fires when *both* ledgers are zero). So the caller takes
`min(0.01 IMD, teamOwed)` on every call, and `teamOwed` can be made arbitrarily small by calling early.

### Arithmetic

Team slice per trade of gross IMD leg `V`:

* buy: `V · 240/10_000 · 2_500/10_000 = 0.006·V`
* sell: `V · 560/10_000 · 2_500/10_000 = 0.014·V`

Break-even, where the tip is the *entire* team slice:

* buy: `0.006·V = 0.01` → **V = 1.6667 IMD**
* sell: `0.014·V = 0.01` → **V = 0.7143 IMD**

**Every buy under 1.667 IMD and every sell under 0.714 IMD pays the team exactly zero** if a bot flushes
after it: `tip = toTeam`, so `_payOut(team(), toTeam - tip)` is `_payOut(team, 0)`, which returns at
`PimdHook.sol:505` without moving a wei.

### Exploit, step by step with numbers

The pool opens at a 2,500 IMD market cap with a 25 IMD-per-origin launch cap, so launch-window trades are
*structurally* in the 0.1–25 IMD band — exactly the band where this bites hardest.

1. Attacker runs a bot on the sequencer feed, watching `FeeTaken`.
2. Alice buys **1 IMD** of PIMD, exact-in.
   `fee = 1e18 · 240 / 10_000 = 2.4e16`.
   `_split` (`:496-498`): `toHolders = 2.4e16 · 7_500/10_000 = 1.8e16`; `teamOwed += 2.4e16 − 1.8e16 = 6e15`.
3. Bot calls `flush()`. `toHolders = 1.8e16`, `toTeam = 6e15`, `tip = min(1e16, 6e15) = 6e15`.
   `unlockCallback` pays engine `1.8e16`, team `6e15 − 6e15 = 0`, bot `6e15`.
   **Team revenue for that trade: 0 wei. Bot revenue: 0.006 IMD.**
4. Repeat per trade.

Launch-day scenario — 3,000 trades, median 2 IMD, 60 % buys:

| | team slice, no bot | with bot |
|---|---|---|
| 1,800 buys × 2 IMD | 1,800 × 0.012 = 21.6 IMD | 1,800 × 0.002 = 3.6 IMD |
| 1,200 sells × 2 IMD | 1,200 × 0.028 = 33.6 IMD | 1,200 × 0.018 = 21.6 IMD |
| **total** | **55.2 IMD** | **25.2 IMD** |

**Attacker profit: 30.0 IMD — 54 % of the team's entire revenue stream.** Cost: 3,000 flushes × ~230k gas
≈ 690M gas; on an Orbit chain at ~0.01 gwei that is ~0.0069 ETH, i.e. single-digit dollars. Profitable at
any plausible IMD price, and in the sub-1.67-IMD regime the capture rate is 100 %.

### Why it is not a false positive

* `flush()` has no caller restriction, no cooldown and no minimum-pending threshold.
* `tip` is capped per call but **not** per unit of revenue, and the number of calls is bounded only by the
  number of taxed trades, which the attacker does not have to create.
* `callerTip` is `constant`, `TEAM_WALLET` is `constant`, and the contract has, by design, "no owner, no
  admin and no launcher" (`PimdHook.sol:53-55`). **There is no post-deploy mitigation.**
* The team cannot defend by flushing itself: on a first-come sequencer a bot watching the feed wins, and the
  team would have to win every race on every trade forever.
* It does **not** touch holders — `holdersOwed` is always paid in full. The victim is the team's 25 %. That
  is what keeps this Medium rather than High.

### Second-order effect

`PimdEngine.fire()` calls `hook.flush()` with the engine as `msg.sender`, so when the engine wins the race
the tip lands in the engine and `_book()` recycles it to holders. A bot that drains `teamOwed` first both
takes the tip and makes `fire()`'s `if (hook.holdersOwed() != 0)` false, so the engine stops pulling at all
until the next trade.

**Fix shape (not applied):** make the tip a bps of `toTeam`, e.g. `tip = toTeam * TIP_BPS / BPS`, so the
team's share of its own slice is invariant to flush frequency; and/or require `toHolders + toTeam >=
MIN_FLUSH` before a tip is payable.

---

## Finding 2 — Medium: `flushHolders` exists but nothing calls it; prior-audit #5 is still live

`src/pimd/PimdEngine.sol:273-275`, `src/pimd/PimdEngine.sol:15-21`, `src/pimd/PimdHook.sol:407`

Commit `f5d85fc` added `flushHolders()` to answer prior-audit finding #5 ("IMD refusing the fixed team wallet
strands the holders' slice at the hook"). The new function is correct in isolation — it zeroes `holdersOwed`
before the unlock, pays only `engine()`, and cannot be blocked by anything the team wallet does. **But the
automated path was never repointed at it:**

```solidity
interface IPimdHookLike {
    function flush() external returns (uint256, uint256);   // flushHolders is not declared
    ...
}
...
if (hook.holdersOwed() != 0) {
    try hook.flush() {} catch {}        // PimdEngine.sol:274 — still the all-or-nothing path
}
```

So the exact failure mode the fix targets is unchanged in practice:

1. IMD (a third party's token, "whose owner's powers are not public" — `PimdEngine.sol:50-52`) starts
   refusing `TEAM_WALLET`.
2. Every `flush()` from every caller reverts inside `_payOut(team(), toTeam)` → `poolManager.take` →
   `CurrencyLibrary.transfer` → `ERC20TransferFailed`.
3. `fire()` swallows it in the empty `catch` (prior audit #6, **also unfixed**), advances `lastFire`,
   computes the drip from a pot that never grew, and still pays `fireTip`.
4. `holdersOwed` grows without bound as claims the hook holds and never burns. On chain this is
   indistinguishable from a quiet market: no event, no revert.
5. The drip only restarts if a human notices and calls `flushHolders()` **manually, forever** — and
   `flushHolders()` pays no tip, so nobody is incentivised to.

Concrete: with 100 IMD of buy volume, `holdersOwed = 100 · 0.024 · 0.75 = 1.8 IMD` and `teamOwed = 0.6 IMD`.
Under a blacklisted team wallet the engine's own pull books **0** income on every epoch indefinitely while
1.8 IMD per 100 IMD of volume accumulates at the hook.

**Why it is not a false positive:** the committed code of `fire()` and of `IPimdHookLike` is as quoted;
`grep -n flushHolders src/` matches only the hook's own definition. The capability was added; the caller was
not changed.

**Fix shape:** declare `flushHolders()` in `IPimdHookLike` and call it from `fire()` (it is the only leg the
engine cares about); keep `flush()` for the team/tip path; replace the empty `catch` with
`catch (bytes memory r) { emit PullFailed(pending, r); }`.

---

## Finding 3 — Low: an exact-out sell can never take the last 5.6 % of the pool's IMD

`src/pimd/PimdHook.sol:281` (fee) and `:310-311` (guard)

For an exact-out sell the hook grosses the ask up before handing it to the pool:

```solidity
fee = amt * bps / (BPS - bps);                      // W · 560 / 9440
...
uint256 wanted = ... : specified + fee;             // W + fee
if (movedQuote != wanted) revert PartialFill(wanted, movedQuote);
```

`Hooks.beforeSwap` sets `amountToSwap = W + fee`, so the pool is asked to deliver
`W · (1 + 560/9440) = W · 1.0593220…` of currency0. With the pool holding `R` IMD that is satisfiable only
when

```
W ≤ R · 9440 / 10000 = 0.944 · R
```

Anything above reverts `PartialFill`, by design — but the trader is not asking for more than the pool has,
they are asking for up to 5.6 % **less**, and still get a revert.

**Worked example.** Pool holds `R = 100e18` IMD.

* `W = 94e18` → `fee = 94e18 · 560 / 9440 = 5_576_271_186_440_677_966`;
  `wanted = 99_576_271_186_440_677_966 ≤ R` → **fills**.
* `W = 95e18` → `fee = 5_635_593_220_338_983_050`;
  `wanted = 100_635_593_220_338_983_050 > R` → pool delivers at most `100e18`,
  `movedQuote = 100e18 ≠ wanted` → **`PartialFill(100635593220338983050, 100000000000000000000)`**.

So the reachable ceiling is `W_max = 94.4e18` — the top **5.6 % of the pool's IMD is unreachable through any
exact-out route**. An exact-in sell can still drain all of `R` (there the fee comes out of the realised
output, `:319`), so no funds are lost; the defect is liveness and quoting.

**Grief variant.** Lowering `R` *is* a sell, which an attacker wants to do anyway. Front-running a victim's
pending exact-out sell for `W` with any sell that takes `R` below `W · 1.0593` turns the victim's trade into
an opaque `PartialFill` revert instead of a worse fill. Cost to the attacker: zero beyond the trade they
already wanted. Impact: wasted gas and a failed exit for the victim, repeatable near the range edge.

**Why it is not a false positive:** the inequality is forced by `amountToSwap = W + fee` in
`Hooks.beforeSwap` (verified in the vendored source) and by `SwapMath.computeSwapStep`'s exact-out branch,
which caps `amountOut` at the liquidity available to the target price and leaves `amountSpecifiedRemaining > 0`
when it cannot reach the ask. `Pool.swap` then returns `amount0 = amountToSwap − remaining < wanted`.

---

## Finding 4 — Low: the `tx.origin` launch cap

`src/pimd/PimdHook.sol:327-338`

`spent` is **correct** — see "verified as correct" below. The defect is the key and the blast radius.

**Bypass.** `tx.origin` is the submitting EOA; wrapping the buy in a contract does not change it, so the
"trivially bypassed by contracts?" question is **no**. It is bypassed by *EOAs*: `launchBuyCap = 25e18` and
the opening market cap is 2,500 IMD, so **100 funded EOAs take the entire opening range**. Each extra EOA
costs one 21k-gas funding transfer plus one swap; 100 × ~220k ≈ 22M gas, which on an Orbit chain at
~0.01 gwei is ~0.00022 ETH. The cap raises the cost of taking the whole launch by a fraction of a cent.

**Collateral damage.** Because the key is `tx.origin` rather than the buyer, every address behind a shared
submitter collapses into one 25 IMD bucket:

* an ERC-4337 bundler (`tx.origin` = the bundler's EOA) — all its users share one cap;
* a multicall relayer, an intent solver, a gasless-swap sponsor, a Safe executor.

One 25 IMD buy routed through a popular relayer exhausts that relayer's cap, and **every subsequent buy
through it reverts `LaunchBuyCap` for the rest of the 600 s window** — for all of its users, for the price of
a 25 IMD buy the attacker wanted to make anyway. The `LaunchBuyCap` revert is also indistinguishable from a
legitimate self-cap, so the relayer's users see unexplained failures during the only window that matters.

---

## Finding 5 — Low: three accounting / documentation defects on the money path

**(a) `totalToTeam` counts IMD the team never received.** `PimdHook.sol:442`

```solidity
totalToTeam += toTeam;     // toTeam is the PRE-tip amount
```

The team receives `toTeam - tip`; the tip goes to `msg.sender`. The same overstatement is in
`emit Flushed(msg.sender, toHolders, toTeam, tip)` (`:443`), where the third argument is the pre-tip figure.
Combined with Finding 1 this is not cosmetic: in the sub-1.67-IMD regime `totalToTeam` grows while the team
is paid exactly nothing, so any dashboard or revenue check reading it reports the opposite of the truth.
There is no `totalToTippers`. Fix: `totalToTeam += toTeam - tip;`.

**(b) the documented claims invariant is breakable by a stranger, and the donation is stranded forever.**
`PimdHook.sol:477-480`

```solidity
/// @notice IMD claims this hook holds inside the PoolManager. Equals holdersOwed + teamOwed.
function claimBalance() external view returns (uint256) { return poolManager.balanceOf(address(this), quoteId); }
```

`PoolManager.mint(to, id, amount)` and ERC-6909 `transfer(receiver, id, amount)` both let **anyone** put IMD
claims on `address(this)` at their own expense. The hook only ever burns exactly `holdersOwed + teamOwed`
(`_payOut`, `:504-508`), never `claimBalance()`, and has no sweep, so donated claims are permanently
unrecoverable and the stated equality is permanently false thereafter. Not a theft — no path lets an attacker
*remove* the hook's claims, since the hook never calls `approve`/`setOperator`, so `transferFrom` against its
balance is impossible — but it breaks the one invariant the contract documents for monitors, and it is a
cheap way to make `claimBalance()` permanently disagree with the ledger. Reword the NatSpec to "at least"
and have monitoring compare `holdersOwed + teamOwed` to itself.

**(c) stale economics in NatSpec.** `PimdEngine.sol:29`: "Where the holders' 60 % ends up." The split has
been 7,500/2,500 since the rework (`HOLDERS_BPS = 7_500`). Prior-audit #14 was closed for `README.md` and the
hook (`e8a2a03`) and missed this one.

---

## Finding 6 — Info: `_SPEC_SLOT` is conditionally written; `_FEE_SLOT` is not

`src/pimd/PimdHook.sol:275-287`

```solidity
uint256 fee;
if ((params.amountSpecified < 0) == params.zeroForOne) {
    ...
    _tstore(_SPEC_SLOT, amt);     // written ONLY in the specified-side branch
}
_tstore(_FEE_SLOT, fee);          // written always
```

This is **safe as written**, because `afterSwap` unconditionally zeroes both slots at `:298-299` before any
branch, and V4 guarantees `afterSwap` runs whenever `beforeSwap` ran (`Hooks.beforeSwap` and
`Hooks.afterSwap` share the same `msg.sender == address(self)` short-circuit, and both flags are set). I also
confirmed the transient slots cannot leak across a *caught* revert: per EIP-1153 `TSTORE` is reverted with
its frame, so a router's `try poolManager.swap(...) catch {}` rolls the slots back to zero.

The note is that the asymmetry leaves the contract one early return away from a real bug. If any future
change reaches `beforeSwap` without reaching `afterSwap`'s clear — an early `return` in `afterSwap`, turning
off the `afterSwap` permission, a second taxed pool — then an unspecified-side swap would read a **stale
`specified` from an earlier swap in the same transaction** and revert a legitimate full fill, or read a stale
`_FEE_SLOT` and `_split` a fee it never minted, breaking the mint↔book invariant. The `_INSWAP_SLOT` early
return deleted in `e9d2da4` was exactly that shape and sat at the top of both functions for the life of the
contract. Hardening: write `_tstore(_SPEC_SLOT, 0)` on the else path (or unconditionally before the branch)
so neither slot can ever be stale, and keep the clears as the first statements of `afterSwap`.

---

# Verified as correct

Everything below was checked by hand against the vendored v4-core, with the arithmetic shown.

## The four swap shapes

With `currency0 = IMD` (enforced at `:246`) and `currency1 = PIMD` (enforced at `:243`),
`zeroForOne == true` is a buy, so `bps = zeroForOne ? 240 : 560` (`:280`, `:318`) is on the right side.

IMD is the *specified* currency iff `(amountSpecified < 0) == zeroForOne` — exact-in buy (specified =
currency0) and exact-out sell (specified = currency0). The test at `:277` is exactly that predicate.
**Correct.**

| Shape | `amountSpecified` | Fee computed at | Formula | `amountToSwap` | Effective rate on the gross IMD leg |
|---|---|---|---|---|---|
| A exact-in buy | `-X` (IMD) | `beforeSwap:281` | `X·240/10_000` | `-(X − fee)` | `fee/X = 2.40 %` |
| B exact-out buy | `+Y` (PIMD) | `afterSwap:319` | `q·240/9_760` | `+Y` | `fee/(q+fee) = 2.40 %` |
| C exact-in sell | `-Z` (PIMD) | `afterSwap:319` | `q·560/10_000` | `-Z` | `fee/q = 5.60 %` |
| D exact-out sell | `+W` (IMD) | `beforeSwap:281` | `W·560/9_440` | `+(W + fee)` | `fee/(W+fee) = 5.60 %` |

The `amt·bps/BPS` vs `amt·bps/(BPS−bps)` choice is on the correct side in all four: the `/BPS` form is used
when the measured quantity is the **gross** IMD leg (A: the amount the trader hands over; C: the amount the
pool pays out), and the `/(BPS−bps)` form when the measured quantity is the **net** leg and must be grossed
up (B: what the pool demands before tax; D: what the trader wants after tax). The identity
`x/(1+x) = b/B` for `x = b/(B−b)` makes B and D land on exactly the same headline rate as A and C:

* B: `240/9760 = 0.0245901639…`; `0.0245901639/1.0245901639 = 0.0240` exactly.
* D: `560/9440 = 0.0593220339…`; `0.0593220339/1.0593220339 = 0.0560` exactly.

**No shape over- or under-charges relative to the stated 240/560 bps.**

### Rounding direction

Every division is a truncating `/` — there is no `mulDivRoundingUp` anywhere in the hook. The hook therefore
**can never mint more claims than the swapper is actually charged**, which is the only direction that would
be a theft. Residual dust is ≤ 1 wei per swap and its beneficiary alternates: in A and D the floored wei
stays with the pool (LPs), in B and C it stays with the trader. Not farmable — the minimum taxable amounts
are 41 / 40 / 17 / 16 wei for A / B / C / D respectively (`floor(x·bps/den) = 0`), against ≥ 100k gas per
swap. (`ZZArith.t.sol::test_E_small_swaps_pay_no_tax` already pins this.)

`_split` (`:495-501`) is **exact**: `toHolders = fee·7500/10000`, `teamOwed += fee − toHolders`, so
`toHolders + (fee − toHolders) == fee` with no remainder. Nothing is stranded in the split; the division's
dust (≤ 1 wei, up to 100 % of a 1–3 wei fee) lands on the team. Already pinned by
`ZZArith.t.sol::test_F_split_dust_goes_to_team`.

## Sign conventions — `BeforeSwapDelta` and `hookDeltaUnspecified`

`toBeforeSwapDelta(int128 deltaSpecified, int128 deltaUnspecified)` puts specified in the **upper** 128 bits.
`beforeSwap:288` returns `toBeforeSwapDelta(int128(uint128(fee)), 0)` — specified = `+fee`, unspecified = 0.
**Correct argument order.**

`Hooks.beforeSwap` then does `amountToSwap = params.amountSpecified + hookDeltaSpecified`, and
`Hooks.afterSwap` maps the hook's deltas onto currencies with

```solidity
hookDelta = (params.amountSpecified < 0 == params.zeroForOne)
    ? toBalanceDelta(hookDeltaSpecified, hookDeltaUnspecified)
    : toBalanceDelta(hookDeltaUnspecified, hookDeltaSpecified);
swapDelta = swapDelta - hookDelta;
```

Evaluating all four:

| Shape | predicate | branch | hook's `amount0` | trader's `amount0` after subtraction |
|---|---|---|---|---|
| A | `true == true` | specified → amount0 | `+fee` | `−(X−fee) − fee = −X` — pays `X` gross ✅ |
| B | `false == true` → false | unspecified → amount0 | `+fee` | `−q − fee` — pays `q+fee` ✅ |
| C | `true == false` → false | unspecified → amount0 | `+fee` | `+q − fee` — receives `q−fee` ✅ |
| D | `false == false` | specified → amount0 | `+fee` | `+(W+fee) − fee = +W` — receives `W` ✅ |

**All four put `+fee` on currency0 (IMD) for the hook and the matching debit on the trader.** A positive
`_accountPoolBalanceDelta` for the hook is a credit it must settle, and the hook settles it by `mint`ing
exactly `fee` claims (`PoolManager.mint` applies `-(amount.toInt128())` to the hook's delta), so the hook's
net currency0 delta over the swap is **exactly zero**. No sign error, no free trade, no theft.

Return plumbing checked too: `afterSwap` returns `(bytes4, int128)` = 64 bytes, which is what
`Hooks.callHookWithReturnDelta` requires; `ParseBytes.parseReturnDelta` reads word 2; `parseFee` reads word 3
of the 96-byte `beforeSwap` return and is only consulted when `key.fee.isDynamicFee()`, which none of the
four permitted tiers (500 / 3 000 / 10 000 / 12 500) is — so returning `0` as `lpFeeOverride` is inert and
cannot be mistaken for an override. **Correct.**

### Overflow of the delta casts

`int128(uint128(fee))` at `:288` and `:321` is an unchecked narrowing that would flip sign for
`fee ≥ 2^127`, which would make the hook *pay* the trader. It is unreachable: the adjacent
`poolManager.mint(address(this), quoteId, fee)` calls `amount.toInt128()` (SafeCast), which reverts for any
`fee > int128.max`, and `fee > 0` on every path that reaches the cast. Upstream of that, `amt * bps` is
checked arithmetic in 0.8.26 and reverts for `amt > 2^256/560`. For the unspecified branch `quoteAmt` is
derived from an `int128` delta, so `quoteAmt · 560 ≤ 9.5e40 ≪ 2^256`. **Safe, but only by SafeCast's grace —
worth an explicit bound if this is ever refactored.**

## The new `PartialFill` guard — correct for both specified-side cases

`afterSwap:307-312`

```solidity
if (specified != 0) {
    int128 a0q = delta.amount0();
    uint256 movedQuote = a0q < 0 ? uint256(uint128(-a0q)) : uint256(uint128(a0q));
    uint256 wanted = params.amountSpecified < 0 ? specified - fee : specified + fee;
    if (movedQuote != wanted) revert PartialFill(wanted, movedQuote);
}
```

The `delta` handed to `afterSwap` is the **raw pool delta for `amountToSwap`**, before
`swapDelta = swapDelta − hookDelta` (confirmed: `PoolManager.swap` calls
`key.hooks.afterSwap(key, params, swapDelta, …)` with the value returned from `_swap`, and the subtraction
happens inside `Hooks.afterSwap` *after* the external call). So the guard compares like with like.

* **Case A.** `amountToSwap = −(X − fee)`. `Pool.swap`'s `zeroForOne != (amountSpecified < 0)` is
  `true != true` → false → `amount0 = amountToSwap − remaining`. Full fill ⇒ `remaining = 0` ⇒
  `movedQuote = X − fee`. `wanted = specified − fee = X − fee`. **Exact match.** ✅
* **Case D.** `amountToSwap = +(W + fee)`. Predicate `false != false` → false → same branch ⇒
  `movedQuote = W + fee`. `wanted = specified + fee = W + fee`. **Exact match.** ✅

**Can it revert a legitimate full fill?** No. Both sides are built from the same `fee` value that was used
to build `amountToSwap`, so there is no rounding gap; the comparison reduces to `remaining == 0`. And
`remaining == 0` is exactly V4's definition of a complete fill:

* exact-in: `SwapMath` documents and enforces that "the combined fee and input amount will never exceed the
  absolute value of the remaining amount"; in the non-target branch `amountIn + feeAmount == −amountRemaining`
  exactly, so `remaining` reaches 0 and the `while (!(remaining == 0 || price == limit))` loop exits. The
  only exit with `remaining != 0` is hitting `sqrtPriceLimitX96`.
* exact-out: `amountOut` is capped at `amountRemaining` directly, so `remaining` reaches 0 unless the price
  limit is hit.

A router passing the conventional `MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE − 1` therefore always full-fills
unless the pool's single range is genuinely exhausted. **No griefing/DoS of normal trading** — an attacker
cannot induce the revert on a victim's trade without first buying out (or selling into) the whole range, and
even then the victim's alternative was a worse fill, not a better one. (Finding 3 is the one real edge: the
exact-out sell ceiling, which is a *liveness* consequence of the gross-up, not a guard bug.)

**Can it pass on a genuine partial fill?** No — `movedQuote == wanted` is `remaining == 0`, i.e. a full fill
by construction. The `abs()` on `a0q` would mask a hypothetical sign flip, but `amount0 ≤ 0` is structural
for `zeroForOne` (currency0 is the input) and `amount0 ≥ 0` for case D (currency0 is the specified output),
so the absolute value is exact in both reachable cases.

**Exact-out sell where the pool holds less IMD than the fee.** The scenario the brief asks about cannot leave
the swapper short: the fee is minted in `beforeSwap`, but `mint` is pure accounting (`_accountDelta` +
`_mint`) — it moves no tokens and does not touch pool reserves. If the pool cannot deliver `W + fee`, the
guard reverts the whole transaction and the mint is rolled back with it. There is no path where the hook
keeps a claim against IMD the pool never paid, and no path where the swapper's IMD delta goes negative (the
failure mode prior-audit #4 flagged). **The fix closes it.** The residual is Finding 3's 5.6 % ceiling.

**The two unspecified cases are correctly left unguarded** (`specified == 0`, so the block is skipped): their
fee is computed in `afterSwap` from the realised `delta.amount0()`, so a partial fill is simply taxed on what
actually moved. A zero-fill exact-out buy yields `quoteAmt = 0`, `fee = 0`, no mint, no book — consistent.

## The mint ↔ book invariant

`claims minted == holdersOwed + teamOwed + (already paid out)` holds on every path:

* The two mint sites are mutually exclusive: `beforeSwap:282` fires on `(amountSpecified < 0) == zeroForOne`,
  `afterSwap:320` on `!=`. No swap can reach both.
* Both are gated on `fee > 0`, and the single `_split` call at `:340` is gated on the *same* `fee > 0` with
  the *same* value — for the specified case the value is round-tripped through `_FEE_SLOT` unchanged; for the
  unspecified case it is the freshly computed local. **No mint without a book, no book without a mint, no
  double-book.**
* `_split` conserves exactly, so nothing is stranded in the split.
* `_payOut` burns exactly what it takes, and `flush` burns
  `toHolders + (toTeam − tip) + tip == holdersOwed + teamOwed`, i.e. precisely the values it zeroed.
  `flushHolders` burns exactly `holdersOwed`. **`flush` cannot pay out more than was taken**; if it tried,
  `PoolManager.burn` would revert on insufficient claims.
* `afterSwap` reverting (`PartialFill`, `LaunchBuyCap`) unwinds the `beforeSwap` mint with the transaction.

## `flush` / `flushHolders` / `unlockCallback` — no double-pay, no double-tip, no reentrancy

* Both entry points share one storage `nonReentrant` lock (`_lock`, `:185-190`), and **both zero their
  ledgers before the external call**: `flushHolders` sets `holdersOwed = 0` at `:411` before `unlock` at
  `:414`; `flush` sets both to 0 at `:434-435` before `unlock` at `:438`. Textbook CEI. Interleaving them in
  one transaction cannot double-pay: whichever runs second reads 0 and either pays nothing or reverts
  `NothingPending`.
* The tip cannot be paid twice from one accrual: `tip = min(callerTip, toTeam)` comes out of the same
  `teamOwed` that was just zeroed, so a second `flush` with no new trades reverts `NothingPending`.
  `flushHolders` pays no tip at all. (The *economics* of the tip are Finding 1; the mechanics are sound.)
* `tip ≤ toTeam` is enforced at `:433`, so `toTeam - tip` at `:438` cannot underflow.
* `unlockCallback` is `onlyPoolManager` **and** gated on the transient `_UNLOCK_SLOT == 1`, set only around
  the hook's own `unlock`. PoolManager only calls back the address that called `unlock`, so no third party
  can drive it; the transient flag additionally fences it to the hook's own unlocks and is rolled back by any
  revert. `abi.decode(data, (uint8))` on the longer `ACTION_FLUSH` payload is fine (the decoder enforces a
  minimum, not an exact, length) and the `uint8` validator rejects dirty high bytes.
* The only attacker-controllable payout target is the tip (`msg.sender`), capped at `callerTip`.
  `engine()` and `team()` are source constants.
* **Reentrancy through `take`'s ERC-20 transfer was considered and is safe.** Even if IMD handed control to an
  attacker mid-`flush`: re-entering `flush`/`flushHolders` hits `Reentrancy`; re-entering `unlockCallback`
  hits `onlyPoolManager`; a nested `poolManager.unlock` hits `AlreadyUnlocked`. The attacker *can* call
  `poolManager.swap` (the manager is unlocked), which mints and books a **new**, fully backed fee — it cannot
  touch the amounts `flush` already captured, and the attacker must settle their own delta or
  `NonzeroDeltaCount != 0` reverts the whole transaction. No value leaks.
* Side note: because a nested `unlock` reverts, `flush()` is unusable from inside anyone else's unlock. That
  is a small integration limitation (an aggregator cannot bundle a flush into a swap's unlock) but it is also
  what makes it impossible to redeem the hook's claims inside the same unlock that created them.

## Claim backing

For the exact-out buy the hook mints its claim in `afterSwap`, *before* the swapper has settled any IMD. That
is safe: `mint` creates only an accounting entry and an ERC-6909 balance, redeemable only via `take`, which
the hook does not call during a swap. By the end of the unlock the swapper has settled or the whole
transaction reverted on `NonzeroDeltaCount`. **No under-collateralised claim can persist.** Conservation for
the exact-out sell: the pool's virtual currency0 reserve falls by `W + fee`, the trader takes `W`, and `fee`
stays inside the PoolManager backing the hook's claim — the PoolManager's real IMD balance falls by exactly
`W`.

## The launch cap's `spent`

```solidity
uint256 spent = uint256(uint128(-delta.amount0())) + fee;
```

* Case A: the guard has already proved `−amount0 == X − fee`, so `spent = X` — the **gross** IMD including
  the tax. ✅
* Case B: `−amount0 == q` and `fee` has been overwritten with the afterSwap figure, so `spent = q + fee` —
  again the gross. ✅

`-delta.amount0()` cannot wrap: `currency0` is the input for `zeroForOne`, so `amount0 ≤ 0` structurally.
`spent` is therefore **correct**: it includes the fee, for both buy shapes. The cap is also checked before
`_split`, so a capped buy books nothing. Dead-conjunct note: prior-audit #13 is still true
(`launchCapSeconds = 600 < LAUNCH_CAP_MAX_SECONDS = 3600`), and `e9d2da4` says so deliberately.

## Other prior-audit fixes verified on the swap path

* **#2 (quote currency not pinned) — fixed correctly.** `:246` `if (c0 != quoteToken()) revert
  WrongQuoteCurrency(c0);` alongside `:243`'s `c1 != address(token)`. Both the wrong ordering and any other
  quote are now refused, which is what every fee formula, `quoteId = uint256(uint160(c0))` and the engine's
  booking depend on. `quoteId` is also the right id: `CurrencyLibrary.toId`/`fromId` are exactly
  `uint256(uint160(address))` and its inverse.
* **#12 (dead `_INSWAP_SLOT` branches) — fixed correctly.** Removed in `e9d2da4`; `grep` finds no residue. I
  separately confirmed that `Hooks` applies `noSelfCall` to `beforeInitialize`, `beforeAddLiquidity` and
  `beforeRemoveLiquidity`, and that the hook's only PoolManager calls are `mint`, `burn`, `take` and
  `unlock` — so the self-call exemption cannot be used to bypass any gate.
* **#4 — see the guard section.** Fixed by refusal rather than the report's suggested afterSwap
  recomputation; the choice is sound (V4 can only return a delta on the unspecified side, and these are the
  cases where IMD *is* specified) and the implementation is exact. Residual: Finding 3.
* **#1 (paged tally) — closed, but see the cross-reference.** `TallyMustBeWhole` at `PimdEngine.sol:311`
  (`start != 0 || maxHolders < epochCount`) does close the move-the-bag-between-pages sybil; the
  `prune`-during-`Tally` escape hatch added to compensate is the brick other lanes reproduced.
* **#9 (bind took any hook at its word) — fixed correctly.** `PimdEngine.sol:192-195` checks
  `h.engine() == address(this)`, `h.quote() == address(imd)` and `h.poolManager() == address(poolManager)`.
  The ABI works: `quote` is a `Currency` user-defined value type over `address`, so the getter returns an
  `address`.
* **#11 (fireTip with no epoch) and #6 (empty catch) — NOT fixed.** `tipBudget` is still assigned at
  `PimdEngine.sol:281` before the `drip != 0 && n != 0` test and `_tip(fireTip)` still runs unconditionally
  at `:295`; the catch at `:274` is still empty. `cache/test-failures` currently records
  `ZzAuditLifecycle::test_F4_tipPaidWithNoEpoch` as failing, which is that.

## Engine booking of IMD

`_book()` (`:449-457`) takes `income = balanceOf(this) − (pot + epochQuote)` and is the only income path — so
a flush, a `take`, a plain transfer, or the hook's caller-tip landing on the engine are all booked exactly
once, and a *failed* pull can never be booked. The ledger invariant
`balance ≥ pot + (epochQuote − epochPaidQuote)` is maintained across a multi-page `Pay`
(`total − epochPaidQuote` returns to `pot` at `:387-388`, with `mulDiv` flooring so no dust is stranded), so
`_tip` and `pay` are always backed. Income arriving mid-`Pay` is picked up by the next `fire`. **Correct.**

One caveat outside my lens: `seed()` (`:215-220`) credits `pot += amount` from the *requested* amount, so if
IMD is ever fee-on-transfer the engine's ledger would over-state its balance permanently. The hook's own path
is immune — it books from the realised balance.
