# 05 — External calls, reentrancy, and transient-storage lifecycle

Scope read line by line: `src/pimd/PimdEngine.sol` (524 lines), `src/pimd/PimdHook.sol` (525 lines),
`src/libraries/L2Block.sol` (21 lines). Supporting reads: `src/pimd/PimdToken.sol`,
`lib/v4-periphery/lib/v4-core/src/PoolManager.sol` (`unlock`/`take`/`mint`/`burn`/`swap`),
`.../src/libraries/Lock.sol`, `.../src/libraries/Hooks.sol` (`beforeSwap`/`afterSwap`),
`.../src/types/Currency.sol` (`transfer`), `.../lib/solmate/src/utils/ReentrancyGuard.sol`,
`foundry.toml`.

Local HEAD `e9d2da4`. **A sibling mutation-testing agent is live-editing `src/pimd/PimdHook.sol` and
`src/pimd/PimdEngine.sol` with `// MUTANT` markers while I write.** Every line number and every quote below
is from `git show HEAD:<file>`, not from the working tree. I did not revert the mutants.

Every number below is measured, not estimated. PoCs are in the scratchpad:

| File | Run |
|---|---|
| `ZzReentrancyProbe.t.sol` | `forge test --match-path test/pimd/ZzReentrancyProbe.t.sol -vv` (5+1 pass, standalone) |
| `ZzTransientProbe.t.sol` | `forge test --match-path test/pimd/ZzTransientProbe.t.sol -vv` (5 pass, on `PimdBaseTest`) |
| `ZzImdGas.t.sol` | `forge test --match-path test/pimd/ZzImdGas.t.sol --fork-url robinhood -vv` (3 pass, **live mainnet IMD**) |

Scratchpad path:
`C:\Users\johnk\AppData\Local\Temp\claude\C--Users-johnk-Documents-Drip\f3316234-e3af-4cb3-81bc-af9bf58e2f9c\scratchpad\`

---

## The headline: I went looking for reentrancy and found none, because IMD does not call its recipient

That is the single most load-bearing fact in this document, and it is measured against the live token, not
assumed. `ZzImdGas.t.sol:test_imd_transfer_does_not_call_the_recipient` transfers real IMD on a Robinhood
fork to a contract whose `fallback` records being called:

```
transfer ok(1=yes): 1
recipient was called(1=yes): 0
gas handed to recipient: 0
recipient IMD balance: 1000000000000000000
```

IMD at `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` is 15,448 bytes, is **not** a proxy (EIP-1967
implementation slot reads `0`), and its resolved selector set is a plain OpenZeppelin v5 `ERC20` +
`Ownable` surface over what looks like a LayerZero OFT (`setDelegate`, peer/nonce selectors; no
`setFee`, no blacklist, no dividend tracker, no `excludeFrom*`). `owner()` is
`0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7`.

Consequences, all of which I verify individually below:

* `PimdEngine._send` (`:488`) is **not** a reentrancy entry point. A holder gets no execution out of it.
* `PoolManager.take` inside the hook's flush (`PimdHook:507`) hands the tip recipient no execution, so the
  `unlock -> unlockCallback -> take -> IMD transfer -> ???` chain the brief asks about **terminates at the
  transfer**. There is no `???`.
* The engine's whole `PayoutFailed`-and-skip machine, and the hook's `flushHolders()` escape hatch, defend
  against a threat this IMD cannot pose (an owner refusing one address). The threat that *is* live on this
  external call is the gas cap, which has ~1.5x of margin. The threat model is inverted relative to the risk.

---

## Severity summary

| # | Sev | What | File:line |
|---|-----|------|-----------|
| M-1 | MEDIUM | `SEND_GAS = 60_000` has only **~1.5x** headroom over the live IMD's measured 37.5k–40k, and overrunning it makes every payout fail **silently and permanently** — `pay` reports success, `totalDripped` stays 0, the epoch recycles into the pot forever. | `PimdEngine.sol:58`, `:486-490`, `:369-376` |
| M-2 | MEDIUM | `_isPool`'s probe budget is **fully burnable**: measured **58,300 gas** per holder on top of baseline, 2.49x per-holder tally cost, cutting the whole-set-tally ceiling from ~819 holders to **~328**. This is the number that sets `03`'s terminal gas ceiling. | `PimdEngine.sol:59`, `:510-523`, `:307-311` |
| M-3 | MEDIUM | `fire()`'s `catch {}` is **still empty** — the prior audit's finding 6 was not fixed — and the engine calls only `flush()`, never the `flushHolders()` hatch added for exactly the failure the catch hides. `holdersOwed()` is still outside the `try`. | `PimdEngine.sol:273-275`, `PimdHook.sol:407-419` |
| L-1 | LOW | `_send` copies **unbounded** return data into fresh memory on every loop iteration. Measured 12.2x gas amplification at 24 holders/page and **68,292,225 gas** at 60/page (over a 32M block). Not reachable with today's immutable IMD; reachable the moment this engine is reused against a different or upgradeable quote token. | `PimdEngine.sol:487-489` |
| L-2 | LOW | `_probe` assigns an **unmasked** 32-byte word to an `address` variable — undefined behaviour per the Solidity docs. Measured: currently neutralised, the compiler masks before the `==`. Latent on any compiler/settings change. | `PimdEngine.sol:516-523` |
| L-3 | LOW | `register()` and `prune()` are the only state-changing engine entry points with **neither** `nonReentrant` **nor** `_requireLocked()`. `prune` is `03`'s brick trigger and would be reachable from inside `fire()`'s own tip callback if the quote token ever called out. | `PimdEngine.sol:225-261` |
| L-4 | LOW | `L2Block` fails open by substituting a **different clock**. A staticcall to an empty `address(100)` returns `ok == true` with 0 bytes; `ret.length < 32` is the only thing between the hook and a trusted garbage value. | `L2Block.sol:16-20`, `PimdHook.sol:257`, `:273`, `:329` |
| I-1 | INFO | `_UNLOCK_SLOT` is dirty for the whole duration of the unlock by design. Benign **only** because V4's `AlreadyUnlocked` plus "the callback always goes to the unlocker" make a second `unlockCallback` unreachable. Undocumented dependency. | `PimdHook.sol:413-415`, `:437-439`, `:447` |
| I-2 | INFO | `afterSwap` has no assertion that `beforeSwap` ran for *this* swap. The `_SPEC_SLOT` guard's correctness rests entirely on V4 pairing the two callbacks. | `PimdHook.sol:296-299` |

Cross-references, not re-reported here: the `prune`/`epochCount` out-of-bounds brick and the terminal gas
ceiling are `03`'s C-1 and C-2; the V4-only scope of `_requireLocked` is `03`'s H-1 and the prior audit's
finding 7. M-2 supplies the measured constant those depend on.

---

## Transient-storage slot inventory

Numeric values computed from the source expressions (my keccak implementation reproduces v4-core's
published `Unlocked` constant byte for byte, which validates it).

| Slot | Numeric value | Writers | Readers | Clearers | Dirty-on-revert risk |
|---|---|---|---|---|---|
| `_FEE_SLOT`<br>`keccak256("pimd.hook.fee") - 1` | `0x0eb3bef9bd4e59438c25bab8a44d6cf295aa4a5d9b8628ba5ed22cc13ee0f285` | `beforeSwap:287` (**unconditional**, writes 0 when no specified-side fee) | `afterSwap:296` | `afterSwap:298` | **None.** Rewritten unconditionally on every `beforeSwap`, so a stale value can never be read. Verified by PoC. |
| `_UNLOCK_SLOT`<br>`keccak256("pimd.hook.unlocking") - 1` | `0xc9b700c6b8fb8b3123239919e933bba58563cbc7772f87df1d2afdb39ddfa5e` | `flushHolders:413`, `flush:437` | `unlockCallback:447` | `flushHolders:415`, `flush:439` | **Dirty by design** for the whole unlock. Not dirty across a revert: EIP-1153 reverts transient writes with the frame, so `try hook.flush() {} catch {}` in `PimdEngine:274` cannot leave it at 1. See I-1 for the window's safety argument. |
| `_SPEC_SLOT`<br>`keccak256("pimd.hook.specified") - 1` | `0xa988ac26fe7894344807576e208b0464e62316dbf298fd9b49f3b48557293aab` | `beforeSwap:285` (**conditional** — only when IMD is the specified side) | `afterSwap:297` | `afterSwap:299` | **None.** The one slot with a conditional write, which is why it needed the hardest look. Cleared on every non-reverting path and rolled back on every reverting one. Verified by PoC, both orders, four swap shapes. |
| `IS_UNLOCKED_SLOT` (**not ours**) | `0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23` | V4 `Lock.unlock`/`lock` | `PimdEngine._requireLocked:461` via `exttload` | V4 | N/A. **Verified identical** to `lib/v4-periphery/lib/v4-core/src/libraries/Lock.sol:8`. The flash guard reads the right slot — had this constant been one byte wrong it would read `0` forever and silently disable the engine's documented defence 1. |

**Collisions:** none. Three distinct keccak-minus-one values, and transient storage is per-address so there is
no interaction with the PoolManager's own slot. The engine holds no transient storage of its own (solmate's
`ReentrancyGuard` is the **storage** variant, `uint256 private locked = 1`).

**`_SPEC_SLOT` isolation, verified.** `ZzTransientProbe.t.sol`:

* `test_specSlot_doesNotLeakBetweenTwoSwapsInOneTx` — exact-in buy (writes the slot) then exact-in sell
  (must read 0) then exact-in buy then **exact-out sell** (writes it again) then exact-in buy, all in one
  transaction. All five fill. Had the slot leaked, the following swap's `afterSwap` would have compared the
  previous swap's `specified` against its own fill and reverted `PartialFill`. PASS.
* `test_specSlot_isRolledBackByAPartialFillRevert` — a 10,000,000 IMD buy the single-sided range cannot
  absorb reverts inside `afterSwap` *after* lines 298–299 have written 0 and *at* line 311; a normal buy and
  a normal sell in the same transaction then both succeed. PASS. This pins the EIP-1153 revert semantics the
  whole design leans on.

The guard is correct. Its only fragility is I-2: there is no `require` that `beforeSwap` ran, so the
invariant lives in V4's `Hooks.beforeSwap`/`Hooks.afterSwap` pairing (both of which also share the same
`msg.sender == address(self)` self-call skip, so they cannot desynchronise) rather than in this contract.

---

## Guard coverage: every external/public state-changing function

### `PimdEngine`

| Function | `nonReentrant` | `_requireLocked` | Other gate | Moves value | Verdict |
|---|---|---|---|---|---|
| `bind(address,address,address[])` `:185` | no | no | `msg.sender == binder`, one-shot `bound` | no | Safe. Makes three external calls to an attacker-chosen `hook_` (`:193-195`) **before** setting `bound = true` at `:196`, so it is reentrant in shape — but a reentrant call arrives with `msg.sender == hook_`, which fails `NotBinder`. |
| `seed(uint256)` `:215` | **yes** | no | — | pulls IMD in | Safe. `require(transferFrom(...))` is a typed high-level call, so no unbounded return-data copy. `_requireLocked` is unnecessary: it reads no PIMD balance. |
| `register(address[])` `:225` | **NO** | **NO** | `bound` | no | See L-3. Reads PIMD balances inside a potential unlock. |
| `prune(address[])` `:248` | **NO** | **NO** | `phase != Pay` | no | See L-3. This is `03`'s brick trigger and it is the least guarded function in the contract. |
| `fire()` `:266` | **yes** | **yes** `:270` | `bound`, `phase == Idle`, `minInterval` | pays `fireTip` | Guarded. Note it *opens* a PoolManager unlock itself via `hook.flush()` after passing `_requireLocked`, which is fine — see "Verified safe". |
| `tally(uint256)` `:307` | **yes** | **yes** `:309` | `phase == Tally`, whole-set | pays tips | Guarded. |
| `pay(uint256)` `:349` | **yes** | **yes** `:351` | `phase == Pay` | **pays holders** | Guarded. |

No unguarded function moves value. The two unguarded functions move no IMD.

### `PimdHook`

| Function | `nonReentrant` | Other gate | Moves value | Verdict |
|---|---|---|---|---|
| `beforeInitialize` `:223` | no | `onlyPoolManager`, `!launched`, `sender == launchFactory()` | no | Safe: one-shot flag written before returning, and the only external calls are `L2Block` and the PoolManager. |
| `afterInitialize` `:263` | no | `onlyPoolManager`, `view` | no | Safe. |
| `beforeSwap` `:267` | **no** | `onlyPoolManager` | mints claims | **Not covered by `_lock`.** Reachable during a `flush` unlock in principle. Accounting-safe — see "Verified safe". |
| `afterSwap` `:291` | **no** | `onlyPoolManager` | mints claims, books `holdersOwed`/`teamOwed` | Same. |
| `beforeAddLiquidity` `:345` | no | `onlyPoolManager`, `sender == launchFactory()`, `!seeded` | no | Safe (flag set before return, no external call). |
| `beforeRemoveLiquidity` `:373` | no | `onlyPoolManager`, `view` | no | Safe. |
| `afterAddLiquidity` / `afterRemoveLiquidity` / `beforeDonate` / `afterDonate` | — | `pure`, always revert | no | Safe. Permission bits are false, so V4 never calls them. |
| `flushHolders()` `:407` | **yes** | `launched`, `holdersOwed != 0` | **pays the engine** | Guarded. Zeroes `holdersOwed` **before** the unlock, which is what makes a nested swap harmless. |
| `flush()` `:427` | **yes** | `launched`, something pending | **pays engine, team, caller** | Guarded. Same pre-unlock zeroing. |
| `unlockCallback(bytes)` `:446` | no | `onlyPoolManager`, `_tload(_UNLOCK_SLOT) == 1` | **burns claims, takes IMD** | Safe. Unreachable a second time — see I-1. |
| `receive()` `:522` | — | always reverts | no | Safe. |

**Cross-function reentrancy sweep.** The only calls that could hand control to a party other than the
PoolManager, PIMD or IMD are:

1. `PimdEngine._send` → `IMD.transfer` (`:488`) — IMD does not call out. **Closed by measurement.**
2. `PimdHook._payOut` → `poolManager.take` → `Currency.transfer` → `IMD.transfer` (`:507`) — same.
   Note `Currency.transfer` forwards `gas()`, i.e. *all* remaining gas, not a capped amount, so if IMD ever
   acquired a recipient hook this would be a full-power frame inside the unlock, not a starved one.
3. `PimdEngine.bind` → `hook_.engine()/quote()/poolManager()` (`:193-195`) — gated by `binder`.
4. `PimdEngine._isPool` → `_probe` staticcall (`:520`) — **static**, cannot write state anywhere.
5. `PimdEngine.fire` → `hook.flush()` (`:274`) — our own hook; opens an unlock but re-enters nothing.

If (1) or (2) ever opened, the reachable targets would be exactly `register()` and `prune()` (L-3) — every
other engine entry point is behind the shared solmate lock, and both hook flush paths are behind `_lock`.

---

## M-1 — MEDIUM: the 60,000 gas cap on the payout call has ~1.5x of margin, and overrunning it is silent and permanent

`src/pimd/PimdEngine.sol:58`, `:486-490`

```solidity
uint256 internal constant SEND_GAS = 60_000;
...
function _send(address to, uint256 amount) internal returns (bool) {
    (bool ok, bytes memory ret) =
        address(imd).call{gas: SEND_GAS}(abi.encodeCall(IERC20Min.transfer, (to, amount)));
    return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
}
```

**Answering the brief's question directly: the cap does not apply to the holder at all.** The call goes to
IMD, not to the payee, and IMD calls nobody. A Safe or a 4337 account receives IMD for exactly the same cost
as an EOA — measured below. The cap is a budget for *IMD's own* transfer logic, and nothing else.

**Measured against live mainnet IMD** (`ZzImdGas.t.sol`, `--fork-url robinhood`), with `vm.cool(IMD)` before
each probe so the first payout's cold-storage costs are charged inside the budget, as they are in a real
`pay` transaction:

```
cold IMD, cap / delivered(1=yes):      35000 0      37500 -       40000 1
warm IMD, cap / delivered(1=yes):      35000 0                    40000 1
contract recipient cap / delivered:    37500 0                    40000 1
```

Requirement is **between 37,500 and 40,000 gas**, identical for EOA and contract recipients, cold or warm.
`SEND_GAS = 60_000` therefore carries roughly **20,000 gas (≈1.5x) of headroom**. That is less than one
cold `SSTORE` (20,000 + 2,100 cold slot = 22,100).

**Why that margin matters more than it looks.** The failure mode is not a revert. `ZzReentrancyProbe.t.sol`
drives the real engine against a quote token whose transfer does three cold `SSTORE`s (66.3k, i.e. just over
the cap):

```
test_A1_heavyImdSilentlyFailsEveryPayout:
  epoch quote silently returned (wei IMD): 62458675327289758900000
  phase == Idle ("epoch closed successfully"), totalDripped == 0, totalPayouts == 0,
  every holder balance == 0, pot == potBefore + quote

test_A2_heavyImdNeverRecovers:
  five epochs, zero IMD delivered; pot after 5 no-op epochs: 100000000000000000000000
```

Step by step, if the budget is ever exceeded:

1. `pay` enters the loop, sets `h.weight = 0` (`:366`) — **before** the send, so there is no retry inside
   the epoch.
2. `_send` returns `false` on the internal out-of-gas. `pay` emits `PayoutFailed` (`:375`) and continues.
3. `paid` stays 0, so `epochPaidQuote`, `totalDripped`, `totalPayouts` and `epochPaidHolders` stay 0.
4. At `end == epochCount`, `leftover = total - 0` goes back to `pot` (`:387-388`), `phase = Idle`,
   `EpochPaid(epoch, 0, 0)` is emitted.
5. `_tip` also uses `_send`, so the keeper's tip fails too and is refunded (`:500-503`). **Nobody is out of
   pocket and nobody notices.** Every epoch thereafter does the same.

The only on-chain signal is a `PayoutFailed` per holder per epoch. Nothing reverts, no flag is set, and the
site's `totalDripped` simply reads 0 forever.

**Why this is not a false positive.** The gap between 40,000 (measured requirement) and 60,000 (the cap) is
20,000 gas. IMD is 15,448 bytes of someone else's code; the engine's own comment at `:50-52` says "IMD is
not our contract and its owner's powers are not public". The margin is real today — I am not claiming the
engine is broken — but it is one storage write wide, it is not asserted anywhere, and no test in `test/`
measures it (`PimdFork.t.sol:253` checks only that IMD takes no transfer fee). An engine whose entire
purpose is pushing IMD should fail loudly, not silently, when its one external call does not fit.

Minimal fixes, in order of value: (a) a fork test that asserts the live IMD transfer fits in
`SEND_GAS / 2`, run in CI; (b) raise `SEND_GAS` to 150,000 — the cap exists to stop *one* address stalling
a batch, and 150,000 x 400 holders is still well inside a block; (c) make the all-failed case loud, e.g.
revert `pay`'s final page if `epochPaidHolders == 0 && totalWeight != 0`.

---

## M-2 — MEDIUM: `_isPool`'s probe budget is fully burnable, and that is what sets the engine's terminal holder ceiling

`src/pimd/PimdEngine.sol:59`, `:510-523`, called from `:231` (`register`) and `:328` (`tally`)

```solidity
uint256 internal constant PROBE_GAS = 30_000;
...
function _isPool(address a) internal view returns (bool) {
    if (a.code.length == 0) return false;
    address t = token;
    return _probe(a, IPairLike.token0.selector) == t || _probe(a, IPairLike.token1.selector) == t;
}
```

**Is the cap honoured by the `staticcall` opcode, given the 1/64 rule?** Yes, and in the conservative
direction: the opcode forwards `min(30_000, 63/64 * gasleft())`, so 30,000 is a hard **upper** bound on
what one probe can consume. The 1/64 rule can only reduce it. There is no path by which a probed contract
consumes more than 30,000.

**But 30,000 x 2 is fully burnable, and `||` short-circuits the wrong way for us.** A contract that returns
anything other than PIMD from `token0()` forces the second probe, so the per-holder cost is `2 * PROBE_GAS`.
Measured on the real engine (`ZzTransientProbe.t.sol:ZzProbeGasTest`, 20 holders each, `tally` covering the
whole set as `:311` now demands):

| Holder shape | `tally` gas per holder | Holders that fit a 32,000,000 gas block |
|---|---|---|
| Plain EOA (`code.length == 0`, early return) | **39,070** | **819** |
| Contract burning both probe budgets | **97,370** | **328** |

The delta is **58,300 gas**, i.e. 2 x `PROBE_GAS` almost exactly, confirming the budget is spendable in full.

**Exploit, step by step:**

1. Deploy N contracts whose `token0()`/`token1()` spin `keccak256` over scratch memory down to ~1,200 gas
   and then return a 32-byte word that is not PIMD. (A `staticcall` cannot `SSTORE`, but memory hashing
   burns gas fine — the PoC's `ProbeHog` is 8 lines of Yul.)
2. Send each `minBalance` PIMD. At the production config in `script/DeployPimd.s.sol`
   (`minBalance 1_000_000e18`) that is 328M PIMD, 32.8% of supply — expensive. At the harness config
   (`100_000e18`) it is 32.8M PIMD, 3.3% of supply.
3. Call `register` with all N. `register` also pays the probe cost, but the attacker pays that.
4. `tally` must now cover the whole set in one call (`:311`, `TallyMustBeWhole`) and needs
   `N * 97,370` gas. Past ~328 it does not fit a block.
5. There is no way out. `prune` cannot remove them — they hold `minBalance`, so `:253` skips them. And per
   `03`'s C-1, pruning *anything* shears `holders.length` below the frozen `epochCount` and makes `tally`
   revert out of bounds instead. `fire` refuses because `phase != Idle`. `epochQuote` is stranded.

**Consequence:** permanent denial of the entire payout mechanism, with the open epoch's IMD locked out of
the pot. This is the mechanism behind `03`'s C-2; my contribution is the measured constant — the hostile
ceiling is **2.5x tighter** than the honest one, and it is tightened by an external call this contract makes
on a stranger's behalf, inside a loop that must complete atomically.

**Why this is not a false positive.** `register` is permissionless by design (`:223`), the probe is inside
the atomic tally loop by design (`:328`), and the dev comment at `:508-509` states the intent — "a hostile
holder contract must not be able to stall an epoch: each probe is a gas-capped staticcall" — which the
measurement contradicts. The cap bounds the *per-probe* cost; it does nothing about the *aggregate*, and the
aggregate is what the whole-set tally made fatal. The two fixes (`:311` atomic tally, `:510-523` gas-capped
probe) are individually reasonable and jointly load a gun.

Cheapest mitigation that keeps both: cache the `_isPool` verdict at `register` time and do not re-probe in
`tally` (a contract cannot stop being a pair shape in a way that matters, and `register` already pays for
the probe), or hard-cap `holders.length`.

---

## M-3 — MEDIUM: the empty catch was not fixed, and the escape hatch built for it is never used

`src/pimd/PimdEngine.sol:273-275`

```solidity
if (hook.holdersOwed() != 0) {
    try hook.flush() {} catch {}
}
```

The prior audit's finding 6 recommended `catch (bytes memory reason)` plus an event. **That was not done.**
What changed since `1b073df` is only the `holdersOwed() != 0` gate, which does not address the finding and
leaves its two noted edges intact:

* `hook.holdersOwed()` is still **outside** the `try` (`:273`), so a hook whose view reverted blocks `fire`
  entirely — the opposite of the stated "a hook-side problem must never block a drip".
* `catch { }` with no parameter is the catch-all: it swallows `Panic`, custom errors and empty reverts
  alike. The decode of `flush()`'s `(uint256, uint256)` return is *not* routed into it, so malformed return
  data still reverts `fire`.

**What is new, and worse.** The hook now has `flushHolders()` (`:407-419`), added expressly because
"`flush` pays the engine, the team and the caller's tip in one unlock, so if IMD ever refused the team
wallet the holders' IMD would be stranded here with it. This path cannot be blocked by anything the team
wallet does". **The engine never calls it.** `fire` calls only `flush()`. So:

1. Anything makes `flush()` revert — and `poolManager.take` → `Currency.transfer` bubbles up an ERC-20
   failure as `ERC20TransferFailed`, so a single refused payee reverts the whole unlock.
2. `fire` swallows it, emits nothing, advances `lastFire`, drips from a pot that never grew, and still pays
   `fireTip` out of that pot (`:295`).
3. Holders' IMD accumulates at the hook indefinitely. The fix for this exact scenario sits one function away,
   unused, and a keeper watching `fire` has no way to know.

**Why this is not a false positive.** This is the failure class the brief says already hid one breakage from
the team once. The gate added since then narrows nothing: it only skips `flush` when `holdersOwed == 0`,
which is precisely when there is nothing to lose. The remedy is two lines — `catch (bytes memory r)` plus an
event, and have `fire` fall back to `hook.flushHolders()` when `flush()` fails.

I will note for the record that with today's IMD the triggering condition (IMD refusing an address) does not
exist: no blacklist selector, no proxy, no owner hook on `transfer`. The finding is about the engine being
blind, not about an imminent loss.

---

## L-1 — LOW: `_send` copies unbounded return data inside the payout loop

`src/pimd/PimdEngine.sol:487-489`

`(bool ok, bytes memory ret) = address(imd).call{...}` allocates a fresh `bytes` for **all** of IMD's return
data on every iteration. Solidity's free-memory pointer only grows within a frame, so `pay`'s memory grows
linearly in `page size x payload` and its gas cost grows quadratically.

Measured (`ZzReentrancyProbe.t.sol`, quote token returning 3,000 words = 96 KiB per transfer, which fits
inside the 60,000 callee budget):

```
test_B1: pay(24) gas, plain IMD return:    958,969
         pay(24) gas, 96KiB IMD return:  11,746,033      (12.24x)
test_B2: pay(60) gas with a 96KiB return: 68,292,225     (over a 32,000,000 gas block)
```

`pay(500)` is what `PimdBase.t.sol:_runEpoch` uses and what a keeper script would naturally do; at 60 it
already does not fit a block.

**Can a holder do this?** No — and the brief asks exactly that. The call goes to IMD, so only IMD controls
the payload. **Is it reachable today?** No: IMD is not a proxy and returns exactly 32 bytes
(`test_imd_transfer_external_calls`). Hence LOW, not MEDIUM.

**Why it still belongs in the report.** `_send` is the *only* place in these three files that copies
unbounded return data — `seed`'s `require(imd.transferFrom(...))` and every other call is a typed
high-level call, which copies only the expected static size. `_probe` gets this right (32-byte bounded copy
in assembly). So this is a single inconsistent line in the one loop that handles money, in a contract whose
quote token is a constructor argument and whose source is explicitly reused across launches
(PULSE → PIMD). One-line fix: do the call in assembly with a 32-byte return area, exactly as `_probe` does.

---

## L-2 — LOW: `_probe` writes an unmasked word into an `address`

`src/pimd/PimdEngine.sol:516-523`

```solidity
function _probe(address a, bytes4 sel) internal view returns (address out) {
    assembly ("memory-safe") {
        let ptr := mload(0x40)
        mstore(ptr, sel)
        let ok := staticcall(PROBE_GAS, a, ptr, 4, ptr, 32)
        if and(ok, gt(returndatasize(), 31)) { out := mload(ptr) }
    }
}
```

Opcode-level verdict, since the brief asks for one:

* `mstore(ptr, sel)` puts the 4-byte selector in the **high** bytes of the word, so `staticcall(..., ptr, 4, ...)`
  sends exactly the selector. Correct.
* Input and output regions **overlap** at `ptr`. Safe: the EVM copies calldata into the child frame before
  any return data is written back.
* The return copy is bounded to 32 bytes, and `returndatasize() > 31` is checked before `mload`, so a short
  return can never be read as a value — the remaining bytes would still hold the selector word. Correct, and
  notably better than `_send`.
* `memory-safe` annotation is **valid**: the block writes 32 bytes at the free-memory pointer without
  advancing it, which the Solidity memory model explicitly permits as scratch, and it never touches
  `0x00-0x3f` or the zero slot at `0x60`.
* **The one defect:** `out := mload(ptr)` assigns a raw 32-byte word to an `address`-typed variable without
  masking to 160 bits. The Solidity docs state that assigning a value outside a type's range in inline
  assembly is undefined behaviour, and `_isPool` then relies on `_probe(...) == t`.

**Measured outcome:** currently harmless. `ZzTransientProbe.t.sol:test_isPool_dirtyWordEvadesTheProbe`
registers a contract whose `token0()` returns `uint256(uint160(PIMD)) | (0xdead << 160)` alongside an honest
pair, and the engine skips **both**:

```
dirty-word pair registered(1=yes): 0
clean pair registered(1=yes): 0
```

At `solc 0.8.26` with `via_ir = true` and `optimizer_runs = 44444444` the compiler masks before the `EQ`, so
the padded word is still recognised. **This is a latent defect, not a live one:** the correctness of a
pool-exclusion check rests on a compiler cleanup the language does not promise. A `via_ir` toggle, an
optimizer-run change, or a solc bump could flip it, and the symptom would be a silent one — a rogue pair
quietly collecting drips. Fix is one word: `out := and(mload(ptr), 0xffffffffffffffffffffffffffffffffffffffff)`.

Separately, and independent of the masking: `_isPool` only catches contracts that *choose* to expose
`token0()`/`token1()` returning PIMD. A bespoke pool simply omits them. The check is effective against
canonical V2/V3 pairs, which is the realistic case, and is not a security boundary.

---

## L-3 — LOW: `register` and `prune` have no guard of any kind

`src/pimd/PimdEngine.sol:225-239`, `:248-261`

Both are `external`, permissionless, write storage, and carry neither `nonReentrant` nor `_requireLocked()`,
while `fire`/`tally`/`pay` carry both. The contract's own header (`:47-49`) states the rule: "`fire`, `tally`
and `pay` refuse to run while the PoolManager is unlocked ... weights are read from balances". `register`
reads a balance from inside a potential unlock at `:230` and writes it to `h.lastBal` at `:235`.

**What an attacker gains from registering under a flash borrow:** very little, and it is worth being precise
rather than alarming. `register` records `lastBal = borrowed` and `streakStart = now`. At the next `tally`,
`bal < last` triggers the sell branch (`:320-321`) and resets the streak — and the address holds less than
`minBalance`, so its weight is 0 (`:328`). Inflating `lastBal` is **self-harming**: it resets the clock on
every subsequent tally. The streak-blending at `:324` likewise makes a borrowed top-up exactly
weight-neutral (hold `B` for 14 days at 3x, borrow `B` more, blended age halves to 7 days at 1.5x on `2B`
— the same product). The design absorbs this; the missing guard is an inconsistency, not a theft.

**What matters is `prune`.** It is the trigger for `03`'s C-1 brick, it is permitted during `Tally` by
explicit design (`:242-247`), and it is the one unguarded, state-shearing function reachable from a callback.
`fire()` sets `phase = Tally` at `:289` and *then* calls `_tip` at `:295`; if the quote token ever handed
control to the tip recipient, that recipient could `prune` and brick the epoch **inside the same
transaction that opened it**. Today it cannot (IMD does not call out), and the attacker does not need
reentrancy anyway — a second transaction does the same job. But a `nonReentrant` on `prune` costs 2,100 gas
and removes the whole class.

---

## L-4 — LOW: `L2Block` fails open onto a different clock, and `ok` is true for an empty address

`src/libraries/L2Block.sol:16-20`

```solidity
(bool ok, bytes memory ret) = ARBSYS.staticcall{gas: ARBSYS_GAS}(abi.encodeWithSignature("arbBlockNumber()"));
if (!ok || ret.length < 32) return block.number;
return abi.decode(ret, (uint256));
```

**Verified live.** `PimdFork.t.sol:148` records that ArbSys answers for real on this chain, and my own fork
run confirms the precompile at `address(100)` responds. Not currently broken.

Four observations, in decreasing order of importance:

1. **A staticcall to an *empty* account returns `ok == true` with zero bytes.** So `ok` proves nothing; the
   only real check is `ret.length < 32`. That check is present and correct — this is handled. But it means
   that if `address(100)` ever held an ordinary contract whose fallback returned 32 or more bytes, the value
   would be `abi.decode`d and **trusted blindly** as an L2 block number, written into `initBlock` at
   `PimdHook:257` and compared at `:273` and `:329`. There is no sanity bound (e.g. "within 2^48", or
   "not less than `initBlock`").
2. **The fallback substitutes a different clock, not a stale one.** On an Orbit chain `block.number` is the
   parent-chain block. If ArbSys answers at `beforeInitialize` but not later (or the reverse), `initBlock`
   and the live reading come from two incomparable counters. Both of the guards built on it then
   misbehave: `L2Block.number() == initBlock` (`:273`, the same-block anti-snipe) can never fire, and
   `L2Block.number() < initBlock + launchCapBlocks` (`:329`) resolves to whichever side the two counters
   happen to fall on. What actually keeps the launch cap from sticking on is the **time** bound, as the
   prior audit's finding 13 noted: `launchCapSeconds` (600) expires long before
   `LAUNCH_CAP_MAX_SECONDS` (3,600), so the documented fail-open bound at `PimdHook:68` is dead code and the
   real protection is the 600-second conjunct at `:330`.
3. `ARBSYS_GAS = 20_000` is an upper bound honoured by the opcode (1/64 can only reduce it). The real
   precompile needs far less. No issue.
4. `bytes memory ret` is again an unbounded copy, but `address(100)` is a precompile, not attacker-chosen.
   This one is fine; L-1 is the one that matters.

`initBlock == 0` doubles as the "not launched" sentinel (`PimdHook:272`), so a chain reporting L2 block 0 at
launch would brick swaps. Not reachable in practice.

---

## I-1 — INFO: `_UNLOCK_SLOT` is dirty for the whole unlock, and the safety argument is undocumented

`PimdHook.sol:413-415`, `:437-439`, `:447`

The slot is set to 1, the PoolManager is unlocked, the entire callback and both `take` calls run with the
slot at 1, and only then is it cleared. Within that window, `unlockCallback` would pass its own guard if it
could be called again.

It cannot, for two independent reasons, **neither of which is in a comment**:

1. `PoolManager.unlock` reverts `AlreadyUnlocked` while unlocked (`PoolManager.sol:105`), so no second
   unlock can begin.
2. More fundamentally, `PoolManager.unlock` calls back to `IUnlockCallback(msg.sender)` — *the unlocker*.
   An attacker who somehow nested an unlock would receive the callback on **their own** contract, never on
   the hook. The hook's `unlockCallback` is only ever reachable from an unlock the hook itself opened.

So the guard at `:447` is redundant belt-and-braces rather than the load-bearing check it reads as, and
`_UNLOCK_SLOT` being dirty is safe for a reason that has nothing to do with the slot. Worth a comment, since
the next person to read `:447` will assume the slot is what protects the function.

Also verified in this window: the hook's ERC-6909 claims cannot be touched by anyone else. `PoolManager.burn`
routes to `_burnFrom`, which requires `from == msg.sender` or an operator/allowance, and the hook approves
nobody — so the sequential `_payOut` burns in `flush` cannot be starved by a third party.

---

## Verified safe (examined, measured, dismissed)

These are the attacks the brief asked for that do **not** work. Each is listed with the reason, because a
negative that is measured is worth as much here as a finding.

**Re-entry into the hook through the PoolManager during its own flush.**
`unlock -> unlockCallback -> take -> IMD.transfer -> ???`. The chain **terminates at the transfer**: IMD
hands the recipient no execution (measured). Even if it did:
* `unlockCallback` is unreachable a second time (I-1).
* `flush` and `flushHolders` share `_lock`, so neither can be re-entered.
* `beforeSwap`/`afterSwap` are **not** behind `_lock` and a nested swap during the flush unlock would run
  them. That turns out to be accounting-safe, by a non-obvious argument worth recording: `flush` zeroes
  `holdersOwed` and `teamOwed` **before** `unlock` (`:434-435`), so a nested `_split` accumulates onto zero
  and survives. Claims balance it: start `C = H + T`; `_payOut` burns `H`, `(T - tip)` and `tip`; the nested
  swap mints `F` and books `0.75F + 0.25F`. End state `C - H - T + F = F = holdersOwed + teamOwed`. The
  invariant holds for both `flush` and `flushHolders`. **This only works because of the pre-unlock zeroing** —
  moving those two lines after the unlock would create a real double-spend of the fee, and nothing in the
  source says so.

**A hostile holder burning the batch's gas through `_send`.** Impossible: the 60,000 is spent by IMD, not by
the payee, and IMD does not call the payee. The payee's code never runs.

**A holder returning a huge payload through `_send` to grief the batch.** Impossible: only IMD can set the
return data. See L-1 for what IMD itself could do.

**Gas-starving `_send` by calling `pay` with a tight gas limit, to forfeit other holders' shares.**
`h.weight = 0` is written before the send, so a forfeited share is unrecoverable within the epoch — the
incentive is real. But the 1/64 rule defeats it: a call that runs out of gas internally consumes
essentially everything forwarded (`63/64` of what was left), leaving ~1/64 for `pay`'s tail
(`epochPaidQuote`, four `SSTORE`s, the `leftover` return, `_tip`'s own 60,000-gas call). The transaction
reverts instead of committing a partial, griefed epoch. Not exploitable.

**`_requireLocked` reading the wrong slot.** `PimdEngine.sol:63`'s constant is **byte-for-byte identical**
to `v4-core/src/libraries/Lock.sol:8`, independently reproduced from `keccak256("Unlocked") - 1`. Had it
been wrong, `exttload` would return zero forever and the engine's documented defence 1 would be silently
absent. It is correct.

**Transient slot collisions between the hook's three slots.** None; three distinct keccak-minus-one values,
computed above. Transient storage is per-address, so no interaction with V4's slot either.

**Two swaps in one transaction seeing each other's `_SPEC_SLOT`/`_FEE_SLOT`.** Does not happen. Verified for
four swap shapes in both orders, plus across a `PartialFill` revert (PoC, 2 passing tests). `_FEE_SLOT` is
written unconditionally on every `beforeSwap`, so it cannot go stale; `_SPEC_SLOT` is the conditional one
and is cleared at `:299` on every path and rolled back by EIP-1153 on every reverting one.

**`fire()` opening an unlock after passing `_requireLocked`.** `fire` checks the lock at `:270`, then
`hook.flush()` unlocks the PoolManager for the duration of the callback, then V4 re-locks. `fire` reads no
PIMD balance, so the window is harmless, and `nonReentrant` holds the engine's lock across it so
`tally`/`pay`/`seed` cannot run inside it. Correct, though it does mean `_requireLocked` is checked at entry
only — fine here, because `tally`'s loop makes nothing but `staticcall`s and `pay`'s weights are frozen.

**`bind`'s three external calls before `bound = true`.** Reentrancy-shaped but closed by `msg.sender == binder`.
Confirms the prior audit's finding 9 is fixed: `bind` now checks `h.engine()`, `h.quote()` and
`h.poolManager()` at `:193-195`.

**`int128(uint128(fee))` truncation at `PimdHook:288` and `:321`.** Unreachable: `poolManager.mint` runs
first (`:282`, `:320`) and its `amount.toInt128()` reverts for any `fee >= 2^127`. Defence by ordering only —
worth a comment.

**`PimdToken.balanceOf` as a reentrancy vector.** It is solmate's public mapping, a bare `SLOAD`. No
external call, so `register`/`prune`/`tally` have no entry point through it.

---

## Verification of the prior audit's two unreviewed fixes

| Prior finding | Status at `e9d2da4` |
|---|---|
| 12 (INFO) — `_INSWAP_SLOT` never written, both early returns dead | **Fixed, cleanly.** `grep -n _INSWAP src/pimd/PimdHook.sol` is empty: the constant and both branches are gone. The three remaining slots are fully accounted for in the table above, with no orphans and no collisions. |
| 6 (LOW) — `fire()`'s empty catch hides every pull failure | **Not fixed.** `catch {}` is still parameterless at `:274`, `holdersOwed()` is still outside the `try` at `:273`, and nothing is emitted. The only change is a `holdersOwed() != 0` gate, which skips the call precisely when there is nothing to lose. Re-raised as M-3, with the new aggravating fact that the `flushHolders()` hatch built for this failure is never invoked by the engine. |
| 4 (MEDIUM) — tax charged on the specified, not the filled, amount | **Fixed, and the fix is sound.** The new `_SPEC_SLOT` guard is correctly scoped (verified by PoC); the `wanted` computation matches V4's `swapDelta` construction for both specified-side shapes, including exact-output rounding. Side effect outside my lens: a buy or exact-out sell that cannot fully fill now reverts rather than partially filling, which on a single-sided bounded range is a liveness restriction routers will hit. |
| 1 (HIGH) — paged tally weighs live balances | **Fixed** by the whole-set requirement at `:311` — which is what makes M-2's measured ceiling and `03`'s C-1/C-2 fatal rather than merely annoying. |
| 7 (LOW) — unlock guard is V4-only | Unchanged; `03`'s H-1 owns it. |

---

## Pre-launch checks this document implies

1. **Assert the IMD gas headroom in CI.** Add to `PimdFork.t.sol`: a `vm.cool(IMD)` capped transfer at
   `SEND_GAS / 2` must succeed. It does today (requirement 37.5k–40k, cap 60k). If a future IMD deployment
   or a different quote token fails it, M-1 goes from thin margin to total silent failure.
2. **Assert IMD makes no call to the recipient.** The `Tattletale` probe in `ZzImdGas.t.sol` is six lines
   and pins the fact that this entire document's reentrancy conclusion rests on.
3. Replace `_send`'s `(bool, bytes memory)` with a 32-byte bounded assembly call (L-1), matching `_probe`.
4. Mask `_probe`'s `out` to 160 bits (L-2).
5. Add `nonReentrant` to `prune` (L-3), and have `fire` fall back to `flushHolders()` and emit the caught
   reason (M-3).
6. Cache the `_isPool` verdict at registration instead of re-probing every tally (M-2).
