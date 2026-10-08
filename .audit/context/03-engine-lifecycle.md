# 03 — Engine lifecycle: the epoch machine and who gets paid

Scope read line by line: `src/pimd/PimdEngine.sol` (524 lines, whole file),
`src/pimd/PimdHook.sol` (flush / holdersOwed / unlockCallback / beforeSwap / afterSwap paths),
`src/pimd/PimdToken.sol`, `script/DeployPimd.s.sol`.
Local HEAD `e9d2da4`. Engine source unmodified in the working tree.

**Every finding below is backed by a passing Foundry PoC.** The 14-test PoC file is at
`C:\Users\johnk\AppData\Local\Temp\claude\C--Users-johnk-Documents-Drip\f3316234-e3af-4cb3-81bc-af9bf58e2f9c\scratchpad\ZzAuditLifecycle.t.sol`.
Drop it into `test/pimd/` and run `forge test --match-path test/pimd/ZzAuditLifecycle.t.sol -vv`.
It builds on the existing `PimdBaseTest` harness, so every line of engine logic executed is the real
contract's. 14 passed, 0 failed.

Config used for the numbers below is the production mainnet branch of `script/DeployPimd.s.sol:47-52`
(`dripBps 150`, `minInterval 2 minutes`, `minBalance 1_000_000e18`, `fireTip 0.05e18`,
`tipPerHolder 0.003e18`, `maxCatchup 6 hours`). The PoC harness uses the testnet-shaped values from
`PimdBase.t.sol:195-200`; where a number is harness-derived I say so. Gas costs are priced at
0.02 gwei and ETH $3,000, per the brief.

---

## Severity summary

| # | Sev | What | File:line |
|---|-----|------|-----------|
| C-1 | **CRITICAL** | `prune` during Tally drops `holders.length` below the frozen `epochCount`; `tally` then reverts out-of-bounds and the phase machine has **no exit**. Costs the attacker ~$0.005. | `PimdEngine.sol:248-261`, `:291`, `:311-316` |
| C-2 | **CRITICAL** | The documented escape hatch is a no-op. Nothing can ever reduce `epochCount`, so once the registered set is too big for one block the engine is **terminally** stuck and every IMD in it is locked forever. ~$24 of gas and one recycled `minBalance` bag. | `PimdEngine.sol:241-247`, `:291`, `:307-346` |
| H-1 | **HIGH** | Streak blending lets tokens with **zero** hold time earn at 0.5x via a pre-aged dust wallet. `_requireLocked` only knows Uniswap V4, so this runs inside any other flash loan at zero capital cost. PoC: 37.5% of an epoch taken on borrowed tokens repaid in the same transaction. | `PimdEngine.sol:320-325`, `:459-462` |
| M-1 | MEDIUM | `fire` pays `fireTip` out of the pot, and burns the elapsed-time budget, when **no epoch opens at all**. | `PimdEngine.sol:281-295` |
| M-2 | MEDIUM | A contract holding ≥ `minBalance` PIMD that cannot forward IMD is a **permanent, unprunable** sink on every epoch. PoC: 75% of an epoch into a dead contract, forever. | `PimdEngine.sol:225-239`, `:253`, `:369-376` |
| M-3 | MEDIUM | `tally`'s `tw == 0` path returns the quote but still pays the tip; `tipPerHolder * epochCount` lets a sybil set guarantee it captures the whole 5% budget. | `PimdEngine.sol:334-345` |
| L-1 | LOW | `fire` calls `hook.flush()`, not `flushHolders()`. A team wallet IMD refuses stops income arriving through `fire` forever. | `PimdEngine.sol:273-275`, `PimdHook.sol:407-443` |
| L-2 | LOW | The 60k `SEND_GAS` cap is never measured against real IMD. If IMD's `transfer` costs more, every payout silently becomes `PayoutFailed` and the engine is a no-op. | `PimdEngine.sol:58`, `:486-490` |
| L-3 | LOW | `_send` copies **unbounded** return data from a gas-capped call into memory. | `PimdEngine.sol:487-489` |
| L-4 | LOW | `_tip` in `fire` runs *after* `phase = Tally`, and `prune` is not `nonReentrant`: C-1 is reachable from inside `fire` via the tip recipient. | `PimdEngine.sol:248`, `:289`, `:295` |
| L-5 | LOW | `_isPool`'s 30k probe cap is evadable by a pool whose `token0()` costs more than 30k gas. | `PimdEngine.sol:510-523` |
| L-6 | INFO | No config check that `minInterval <= maxCatchup`, and `minInterval` is unbounded. | `PimdEngine.sol:163-164` |

---

## C-1 — CRITICAL: `prune` during Tally bricks the phase machine

**Root cause.** `epochCount` is a snapshot of `holders.length` taken at `fire` (`PimdEngine.sol:291`).
`tally` is now all-or-nothing and iterates **exactly** `epochCount` slots:

```solidity
// PimdEngine.sol:310-316
uint256 start = cursor;
if (start != 0 || maxHolders < epochCount) revert TallyMustBeWhole(epochCount);
uint256 end = epochCount;
...
for (uint256 i = start; i < end; ++i) {
    address a = holders[i];     // <-- bounds-checked storage array read
```

`prune` is explicitly permitted during Tally (`:249`, `if (phase == Phase.Pay) revert WrongPhase;`)
and does a swap-and-pop that **shortens `holders`** (`:254-257`) while leaving `epochCount` alone.
The moment `holders.length < epochCount`, `holders[i]` at `i >= holders.length` panics with `0x32`
and `tally` reverts. There is no other transition out of `Tally`: `fire` requires `Idle` (`:268`),
`pay` requires `Pay` (`:350`), and there is no owner, no timeout and no admin.

**Exploit, step by step (PoC `test_F1_pruneDuringTallyBricksEngine`, PASS).**

1. Attacker funds one address `S` with `minBalance` PIMD (1,000,000 PIMD) and calls
   `register([S])`. Permissionless, `PimdEngine.sol:225`.
2. He moves the bag straight back out. `register` only checks the balance *at registration*
   (`:230-231`); nothing requires it to persist. `S` is now registered with balance 0.
3. The keeper (or the attacker) calls `fire()`. `epochCount = holders.length`, `epochQuote = drip`,
   `phase = Tally`.
4. Attacker calls `prune([S])` — allowed in Tally, and `S`'s balance is below `minBalance` so it
   passes the gate at `:253`. `holders.length` drops by one. `epochCount` does not.
5. `tally(anything)` now reverts `panic 0x32` forever. So does every retry, at any later timestamp.
   `fire()` and `pay()` revert `WrongPhase`.

PoC output, harness config, 100 IMD seeded:

```
stranded epochQuote (wei IMD): 27861042101616640000   (27.86 IMD reserved, unreachable)
pot still held (wei IMD):      72118957898383360000   (72.12 IMD, undrippable: fire needs Idle)
```

All future hook income is locked too: `_book()` is only reached from `fire` (`:276`), which needs
`Idle`.

**Recovery, and why it does not save you.** The only escape is for a third party to register
*exactly* `epochCount - holders.length` fresh, `minBalance`-funded, not-already-registered addresses
to push the length back up. The PoC confirms this works. But both calls are permissionless and
land in the same block, so the attacker simply front-runs every tally attempt. Measured, inside the
harness (`test_F1b_regriefIsCheaperThanRescue`, PASS):

```
round 0  prune gas 67,620   rescue register gas 87,314
round 4  prune gas 67,637   rescue register gas 87,327
```

Per grief round the attacker spends one prune (~88.6k gas with the 21k tx base) plus re-arming one
prunable entry (register 87.3k + two PIMD transfers ~80k + base ≈ 209k) ≈ 298k gas = **$0.018**.
At one round per `minInterval` (2 minutes) that is **$12.90/day to freeze every payout in the
protocol indefinitely** — and the rescuer must lock a fresh `minBalance` bag each round. A single
prunable entry can be armed and spent repeatedly from one recycled bag.

**Attacker gain.** None directly; this is pure liveness destruction, which is exactly what a
shorter or a rival launch wants, and it is also the lever for an extortion. The protocol's entire
value proposition (the drip) stops.

**Why this is not a false positive.** The PoC runs the real `register`/`fire`/`prune`/`tally`, asserts
the exact `stdError.indexOOBError` panic, asserts `WrongPhase` on both other entry points, and
re-asserts the revert after a 30-day warp. The NatSpec at `:242-247` states that prune-during-Tally
exists *as the escape hatch*, so this is the designed path, not a corner case — and it is the brick.
Nothing in the existing test suite exercises prune during Tally
(`grep -n prune test/pimd/*.sol` returns only registration-side tests).

**Fix direction.** `prune` must not be able to invalidate the snapshot. Either (a) refuse `prune`
in any phase other than `Idle` and give `fire`/`tally` a real abort path, or (b) clamp the loop:
`uint256 end = epochCount; if (end > holders.length) end = holders.length;` *and* let `prune`
decrement `epochCount` when it removes a slot below it, or (c) drop `epochCount` entirely and have
`tally` iterate `holders.length`, snapshotting nothing. Note (c) alone still leaves C-2.

---

## C-2 — CRITICAL: the escape hatch cannot shrink the work, so the gas ceiling is terminal

**Root cause.** `epochCount` is written in exactly one place, `fire` (`:291`), which requires
`Idle`. `Idle` is only reachable from `tally`'s `tw == 0` branch (`:340`) or the end of `pay`
(`:385`). Both require `tally` to complete. So:

- If `tally` needs more gas than a block provides, it can never complete.
- `prune` cannot help: it shortens `holders` and triggers the C-1 out-of-bounds revert.
- `register` cannot help: it lengthens `holders` but `tally` still loops `epochCount` slots at the
  same cost.
- Nothing else writes `epochCount`, `phase` or `epochQuote`.

The engine is **terminally** stuck with the whole pot and the reserved `epochQuote` inside it, plus
every IMD the hook pushes in from then on. The NatSpec at `:241-247` asserts the opposite
("weighing happens in one call, so a holder set too large for one block would otherwise leave the
epoch stuck in Tally with no way back, because the only thing that can shrink the set is this
function"). The reasoning is wrong: shrinking the *set* does not shrink the *loop*.

**Measured gas ceiling (`test_F2_...`, `test_F2b_...`, PASS).**

| Holder shape | gas / holder in `tally` | holders that fill a 32,000,000 gas block |
|---|---|---|
| EOA, registered then drained (weight 0) | **13,521** | **2,366** |
| Contract that burns both `_isPool` probes | **94,286** | **339** |

The contract figure is the interesting one: `_isPool` (`:510-523`) issues two
`staticcall(PROBE_GAS=30_000, …)` probes, and a holder contract can burn both stipends. 60k+ gas
per holder, per epoch, consumed by a holder who still gets weight (a failed probe returns 0, which
does not match `token`, so it is **not** classified as a pool and *is* paid). `_isPool` is only
reached when `bal >= minBalance` (`:328`), so this shape costs the attacker real PIMD.

**Cheap exploit — drained sybils, ~$24 (verified mechanics in `test_F2_...`).**

1. `register` checks the balance only at registration time and nothing requires it to persist, so
   **one** `minBalance` bag registers an unbounded number of addresses by being passed along:
   `transfer(S_i, minBalance)` → `register([S_i])` → `S_i.transfer(back)`. The PoC asserts
   `holderCount() == 400` with the single bag intact at the end
   (`"n registered on a single bag"`, `"bag intact"`).
2. Arming cost per sybil, batched: ~51k (fund) + ~87.3k (register) + ~29k (drain) ≈ **167k gas**.
3. For a 32M block limit, 2,366 sybils are needed: 2,366 × 167k = **397M gas = 0.0079 ETH ≈ $24**.
   Register 5,000 for ~$50 to leave no doubt.
4. Attacker calls `fire()` himself (permissionless, `:266`). `epochCount` snapshots the bomb.
5. `tally` can never fit in a block. Engine dead. Capital spent: one 1,000,000 PIMD bag, retained.

**Terminal + unprunable variant, ~$4 of gas (`test_F2c_irrecoverableGasCeiling`, PASS).**
Make the probe-burning holders *unable to transfer* — a contract with only a gas-burning fallback
and no transfer path. Its PIMD balance can never fall below `minBalance`, so `prune` can never
remove it (`:253`). 400 of them:

```
IMD stranded in epochQuote forever:  278610421016166400000   (278.6 IMD)
IMD stranded in pot forever:         721369578983833600000   (721.4 IMD)
PIMD the attacker burned to do it:   40000000000000000000000000  (40M = 4% of supply)
```

The PoC then proves every door is shut: `tally` with a 32,000,000 gas cap fails; `prune(burners)`
removes nothing; pruning any *other* entry makes `tally` revert out-of-bounds instead; `fire` and
`pay` revert `WrongPhase`. Gas cost of 400 burners: 400 × (70k deploy + 51k fund + 87k register) ≈
70.5M gas ≈ **$4.23**. PIMD cost 4% of supply — at a $5,000 launch cap that is **$200** to
permanently destroy the payout engine and lock every IMD in it.

**This also happens organically.** `holders` only ever grows except by explicit `prune`.
Registration survives the balance leaving, so every wallet that has *ever* held `minBalance` and
been registered stays in the tally loop until someone prunes it — and the keeper must prune **only
in Idle** or it triggers C-1. A token with churn walks itself into this ceiling. At 13,521 gas per
holder the headroom is ~2,400 entries on a 32M block, and far less (~500) against Arbitrum's 7M
sustained gas speed limit.

**Why not a false positive.** `epochCount` is `public` and the PoC asserts its value directly; the
32M cap is enforced with an explicit `call{gas: 32_000_000}` and the failure asserted; the
unprunability is asserted by `holderCount()` being unchanged after `prune(b)`. No cheatcode warps
or mocks are involved in the ceiling itself.

---

## H-1 — HIGH: zero-hold-time tokens earn at 0.5x, and the flash-loan guard is V4-only

Two defects that compose into one exploit.

**(a) The blend conserves `lastBal x streak`, so an aged dust wallet launders a fresh bag.**

```solidity
// PimdEngine.sol:322-325
} else if (bal > last) {
    h.streakStart = uint64((last * h.streakStart + (bal - last) * nowTs) / bal);
}
```

Algebraically, the new age is `age_new = last * (now - streakStart_old) / bal`, i.e. the product
`balance x age` is invariant under a top-up. So a wallet holding `b` tokens for `T` seconds can
absorb up to `b*T/3600` tokens and still land at `age >= 1 hour`, which is tier **0.5x** — not the
0x the whole design is built on. Its weight becomes `0.5 * b*T/3600 = b*T/7200`.

With the production `minBalance` of 1,000,000 PIMD held for 30 days, one seed wallet carries
`1e6 * 2,592,000 / 3,600 = 7.2e8` PIMD — **72% of total supply** — at 0.5x. Its honest weight would
be `3 * 1e6 = 3e6`; laundered it is `3.6e8`. **120x amplification**, and ten such seed wallets carry
more PIMD than exists. The only real constraint is how much PIMD the attacker can hold *for the
duration of one call*.

**(b) `_requireLocked` only checks Uniswap V4.**

```solidity
// PimdEngine.sol:459-462
function _requireLocked() internal view {
    if (IExttload(address(poolManager)).exttload(IS_UNLOCKED_SLOT) != bytes32(0)) revert PoolUnlocked();
}
```

That is the V4 PoolManager's transient `Unlocked` slot and nothing else. An Aave/Morpho/Balancer
flash loan, an ERC-3156 lender, a V2 pair's `swap` flash-out, a V3 `flash`, a friendly whale, or a
one-block OTC loan all leave the slot at zero. `fire`, `tally` and `pay` are each permissionless
with no cross-block requirement, so all three run inside one callback. Weights freeze at `tally`,
so **the borrow only has to span `fire` + `tally`**.

**Exploit, step by step (`test_F6_nonV4FlashLoanRunsWholeEpoch`, PASS).**

1. Weeks ahead: deploy a plain contract `A` (no `token0`/`token1`, so `_isPool` returns false —
   the PoC asserts `holderCount() == 2`, "attacker contract registered, not seen as a pool"), fund
   it with `minBalance` PIMD, `register([A])`. This dust is the *only* capital ever at risk.
2. Wait for the streak. 30 days in the PoC.
3. Wait for `block.timestamp >= lastFire + minInterval` — public, readable via `nextFireAt()`.
4. One transaction: flash-borrow PIMD to `A` → `engine.fire()` → `engine.tally(n)` → `engine.pay(n)`
   → repay the lender. The PoC asserts the lender's balance is unchanged at the end
   (`"loan repaid in the same tx"`).

PoC result, harness config (`minBalance 100,000e18`, seed held 30 days, 71.9M PIMD borrowed,
against one honest holder of 20M PIMD aged 30 days at 3x, 1,000 IMD pot):

```
IMD to the flash attacker:                            234242032477336595875   (234.2 IMD)
IMD to the 30-day honest holder:                       390366720795560993125   (390.4 IMD)
share of the epoch taken on borrowed tokens (bps):     3750                    (37.5%)
```

**37.5% of the epoch, on tokens the attacker owned for the length of one call, repaid in the same
transaction, with 0.01% of supply as the only committed capital.** Repeatable every epoch: he
re-registers a fresh dust wallet after each use (the laundering sets `lastBal` to the borrowed
amount, so the next tally sees `bal < last` and resets the streak — `:320-321` — a one-time cost of
one new dust wallet per attack).

**Control (`test_F3b_controlFreshBagEarnsNothing`, PASS):** the *same* 72M PIMD bag, registered
fresh with no pre-aged wallet, is paid exactly **0**. That isolates the defect to the blend.

**No flash lender needed at all (`test_F3_streakLaundering`, PASS).** The primitive is just a
transfer one transaction before the tally, so any whale who has *just bought* can upgrade his bag
from 0x to 0.5x and sell minutes later:

```
blended age (s):                                      3600
tier after laundering (bps):                          5000
IMD to the laundering wallet:                         234220032477336595875
share of epoch taken by 1-second-old tokens (bps):    3750
```

**Why not a false positive.** The documented contract (`PimdEngine.sol:32`,
"under an hour 0x") is violated: tokens one second old are paid. Weight per token is correctly
capped at 3x — I verified the blend can only ever move `streakStart` toward `now`, so there is no
amplification *above* an honest 14-day holder's rate — but the entire 0x floor and the ladder's
purpose (reward duration) are bypassed, and the capital requirement is a dust bag plus a one-call
borrow. The `_requireLocked` NatSpec at `:47-49` claims "Outside an unlock the borrow cannot
exist", which is simply not true of any lender other than V4.

**Fix direction.** Two independent fixes, both needed. (1) Weight from a *lagged, minimum* balance,
not a live one: record `min(bal, lastBal)` observed over the epoch, or require a holder's balance to
have been at or above its weighted amount at the previous tally too. (2) Do not let a top-up buy
tier: on any increase, either hard-reset `streakStart = now` (losing the blend's nicety but closing
this) or cap the carried balance at `lastBal` and weight the excess at 0 until the next epoch.
Dropping `_requireLocked` in favour of (1) is the only robust answer — there is no way to enumerate
every lender.

---

## M-1 — MEDIUM: `fireTip` is paid out of the pot when no epoch opens

```solidity
// PimdEngine.sol:280-295
lastFire = block.timestamp;                       // advanced unconditionally
tipBudget = (drip * TIP_BUDGET_BPS) / BPS;        // set unconditionally
uint256 n = holders.length;
emit Fired(epoch + 1, drip, n);
if (drip != 0 && n != 0) { ... }                  // the epoch may not open
_tip(fireTip);                                    // paid either way
```

When `n == 0` and `drip != 0`, no epoch opens, `epoch` is not incremented, the pot is not reduced by
`drip` — but `tipBudget` is set to 5% of a drip that never happened, `lastFire` is advanced (burning
the accrued time), and `_tip(fireTip)` pays the caller out of the pot (`:499`).

**PoC (`test_F4_tipPaidWithNoEpoch`, PASS):** 1,000 IMD pot, nobody registered, 20 `fire()` calls
two minutes apart:

```
pot before:                      1000000000000000000000
pot after 20 no-op fires:         999600000000000000000
IMD farmed by the caller:                    400000000000000000   (0.4 IMD = 20 x 0.02 fireTip)
```

with `assertEq(engine.epoch(), 0)` and `phase == Idle` on every iteration.

**Production numbers.** `fireTip = 0.05e18`, `minInterval = 2 minutes` → 720 fires/day = **36 IMD/day**
drained to a bot. The only brake is `tipBudget >= fireTip`, i.e. `drip * 5% >= 0.05 IMD`; with
`dripBps 150` over a 2-minute interval `drip ≈ pot * 0.002`, so any pot above ~500 IMD funds the
full tip. At a 500 IMD pot that is **7.2%/day of the holders' pot** to a caller who produces nothing.
The window is the launch (before anyone registers) and any period where registrations have been
pruned to zero.

**Fix:** move `tipBudget = …` and `_tip(fireTip)` inside the `if (drip != 0 && n != 0)` block, and
do not advance `lastFire` when no epoch opens.

---

## M-2 — MEDIUM: a contract that cannot forward IMD is a permanent, unprunable sink

`register` is permissionless and takes an arbitrary address list (`:225`). `excluded` is write-once
at `bind` (`:201-209`) and can never be extended. `prune` can only remove an entry whose balance is
*below* `minBalance` (`:253`). And `pay` only returns a share to the pot if `_send` **fails**
(`:369-376`) — a `transfer` that lands in a contract with no way to move it succeeds, and the IMD
is gone.

So: any contract holding ≥ `minBalance` PIMD that cannot call `IMD.transfer` becomes a permanent,
unremovable claimant on a share of every epoch, forever. Anyone can create one.

**PoC (`test_F8_unprunableSinkEatsEveryEpoch`, PASS).** Attacker sends 30M PIMD (3% of supply) to a
contract with no transfer path, registers it, waits 20 days so it reaches 3x, against an honest
holder of 10M aged the same:

```
IMD paid into the dead sink:        468440064954673191750   (468.4 IMD = 75% of the epoch)
IMD paid to the honest holder:      156146688318224397250   (156.1 IMD)
```

then asserts `prune([sink])` leaves it registered — "sink cannot be pruned, ever".

**Attacker gain.** None; this is vandalism priced in PIMD (3% of supply here). It is permanently
unfixable after `bind`, which makes it worth pricing: at a $5,000 launch cap, $150 of PIMD
permanently redirects 75% of every future drip into a dead address. It is also an *accident* waiting
to happen — any third-party vesting contract, locked-LP wrapper, bridge or multisig-without-ERC20-
sweep that holds ≥ 0.1% of supply can be registered by a stranger, and `bind`'s `alsoExclude` is a
one-shot manual list that only the airdrop distributor is documented to contain
(`DeployPimd.s.sol:67`). The launch factory `0xA25B…4645` is not on it.

**Fix:** either make payouts pull-based for contract holders, or allow `prune` of any address whose
`_send` has failed / whose weight has been zero for N epochs, or require a holder to prove it can
receive (and let anyone prune a registered address that is not an EOA and not on an allowlist).
At minimum, `register` should refuse `a.code.length != 0` unless the address self-registers.

---

## M-3 — MEDIUM: tips are paid for an epoch that releases nothing, and sybils secure the whole budget

```solidity
// PimdEngine.sol:334-345
if (end == epochCount) {
    cursor = 0;
    if (tw == 0) {
        pot += epochQuote; epochQuote = 0; phase = Phase.Idle;   // nothing released
    } else { phase = Phase.Pay; }
}
_tip(tipPerHolder * (end - start));                              // paid anyway
```

Two issues.

1. **Tip for a null epoch.** PoC `test_F4b_tipPaidWhenTallyReleasesNothing` (PASS): one holder kept
   under an hour old, so `tw == 0`; the quote goes straight back and the caller is still paid:
   ```
   quote returned to pot:              78400000000000000000    (78.4 IMD, nobody paid)
   tip still paid to tally caller:         500000000000000
   tipBudget left:                    3899500000000000000      (3.90 IMD still claimable)
   ```
   A holder's streak resets to `now` whenever its balance falls (`:320-321`), so an attacker can
   hold a wallet at tier 0 indefinitely by sending 1 wei out before each tally. In the launch window
   (or any period where he is the only registrant) this farms the tip budget while nobody is paid.

2. **`tipPerHolder * epochCount` is unbounded by anything but the cap.** Since `start == 0` and
   `end == epochCount` always (the atomicity check at `:311` forces it), the tally caller claims
   `tipPerHolder * epochCount`, clamped to `tipBudget`. With production values
   (`tipPerHolder 0.003e18`), **1,667 registered addresses saturate the entire 5% budget in one
   call** — and registering 1,667 zero-weight addresses costs one recycled `minBalance` bag plus
   ~$17 of gas (C-2's arming cost). The attacker guarantees he, and not an honest keeper, takes the
   full 5% of every epoch's drip, while also pushing the engine toward C-2's ceiling.

Also note the tips are drawn from `pot` (`:499`), i.e. *on top of* `drip`, so total outflow per
epoch is 105% of the drip, and tips are absent from every lifetime stat (`totalDripped` at `:379`
counts payouts only).

**Fix:** skip `_tip` on the `tw == 0` path; scale the tally tip by holders *actually weighted*
(`w != 0`) rather than slots visited; take tips out of `drip` before reserving `epochQuote`.

---

## Lows

**L-1 — `fire` calls the wrong flush.** `PimdEngine.sol:273-275` calls `hook.flush()`, which pays
the engine **and** the team in one unlock (`PimdHook.sol:427-443`). The hook has a dedicated
`flushHolders()` (`PimdHook.sol:407-421`) that exists precisely so "if IMD ever refused the team
wallet the holders' IMD would be stranded here with it". The engine's `IPimdHookLike` interface
(`:15-21`) does not even declare it, so the engine can never call it. If IMD ever blocks the team
wallet, `fire`'s `try/catch` swallows the revert forever and income only reaches the engine when
somebody remembers to call `flushHolders()` out of band. Add `flushHolders()` to the interface and
prefer it in `fire`.

**L-2 — the 60k send cap is unverified against real IMD.** `SEND_GAS = 60_000` (`:58`). Nothing in
`test/pimd/` measures IMD's actual `transfer` cost; `PimdFork.t.sol:253` only checks there is no
transfer fee. IMD is a third-party token on an ecosystem of "IMD-quoted dividend tokens"; dividend-
style tokens routinely cost 80k–200k per transfer. If IMD's `transfer` exceeds 60k, `_send` returns
false for *everybody*, every payout becomes `PayoutFailed`, every share falls back into the pot
(`:386-388`), `_tip` also always fails (`:500-503`) and the engine is a silent no-op forever. This
is cheap to settle: fork Robinhood chain and measure `imd.transfer` to a cold address, including the
cold-account and cold-slot surcharges, then set the cap with headroom.

**L-3 — unbounded return-data copy from a gas-capped call.** `PimdEngine.sol:487-489` assigns
`bytes memory ret` from `address(imd).call{gas: SEND_GAS}(…)`. The `RETURNDATACOPY` and the memory
expansion are charged to the *engine*, outside the 60k stipend. A 60k-gas callee can expand to tens
of kilobytes, costing the engine ~20–30k extra gas per payout and shrinking the already-tight tally/
pay budget. Only exploitable by IMD's own owner, so LOW — but there is no reason to take it: use
`assembly` with a 32-byte output buffer exactly as `_probe` does (`:516-523`), which is already
correct.

**L-4 — C-1 is reachable from inside `fire`.** `fire` sets `phase = Phase.Tally` at `:289` and then
calls `_tip(fireTip)` at `:295`, which `_send`s IMD to `msg.sender`. `prune` is not `nonReentrant`
(`:248`) and `fire`'s own `nonReentrant` does not protect it. If IMD notifies recipients, a tip
recipient can call `prune` from that callback with `phase == Tally` and brick the epoch inside the
`fire` transaction. The measured prune cost (~46k internal) is close to the 60k stipend, so this is
marginal — but the ordering is wrong regardless: move `_tip` to the top of `fire`, or before the
phase transition.

**L-5 — `_isPool` probes are evadable by cost.** `_probe` caps each `staticcall` at
`PROBE_GAS = 30_000` (`:520`). A pool-shaped contract whose `token0()` costs more than 30k gas
returns `ok == false`, `out == 0`, and is classified as *not* a pool — so it registers and is paid
(`:231`, `:328`). The check is a best-effort heuristic by design (any pool that simply omits
`token0`/`token1` also walks through), so LOW; worth saying out loud in the NatSpec at `:506-509`,
which currently reads as a guarantee.

**L-6 — config gaps.** The constructor (`:160-164`) bounds `dripBpsPerPeriod` and `maxCatchup` but
not `minInterval`, and does not require `minInterval <= maxCatchup`. With `minInterval > maxCatchup`
every epoch systematically discards accrued time; with `minInterval == 0` an attacker can fire the
instant the previous epoch closes, which makes C-1's grief window continuous. Add
`if (minInterval == 0 || minInterval > maxCatchup) revert BadConfig();`.

---

## Verified safe

Things I attacked and could not break. These are statements about the code as read, with the
reasoning, not assertions of absence.

**The atomic-tally fix does close the original sybil double-count, and I found no second route.**
I re-derived the old HIGH from `AUDIT-1b073df.md` and attacked the fix directly:

- `holders` cannot contain the same address twice. `register` pushes only when `index1 == 0`
  (`:229`) and sets `index1 = holders.length` after the push (`:234`). `prune`'s swap-and-pop
  (`:254-258`) writes `_holder[last].index1 = idx1` before `delete _holder[a]`, so the moved
  address's index is always correct, and the self-assign case (pruning the tail, where `last == a`)
  is safe because the `delete` comes after. `index1` is `uint64`, needing 2^64 entries to truncate.
- `tally` visits each slot exactly once: the atomicity check at `:311` forces `start == 0` and
  `end == epochCount`, so a bag cannot be moved across a page boundary and weighed twice.
- Nothing can move PIMD *inside* the tally loop. `IERC20Min.balanceOf` is declared `view` (`:10`),
  so it compiles to `STATICCALL`; `_probe` uses `staticcall` (`:520`); `tally` is `nonReentrant`.
  PIMD is a plain solmate `ERC20` with a mapping-backed `balanceOf` and no hooks
  (`PimdToken.sol:26-35`), so there is no callback surface at all.
- Weight per token is hard-capped at 3x. The blend only ever moves `streakStart` *toward* `now`
  (`age_new = last * age_old / bal <= age_old` for `bal >= last`), and a decrease resets to `now`
  (`:320-321`). So `w <= 3 * bal` always and no wallet can out-earn an honest 14-day holder per
  token. H-1 is a *floor* bypass, not an amplification past the ladder's top.
- `prune` cannot evict an honest holder from a running epoch. The `minBalance` gate at `:253` means
  only entries that would have had weight 0 anyway (`:328`) are prunable, and the tail address that
  swaps into the freed slot is either weighed there or is a post-snapshot registrant with weight 0.
  I walked every (prune, register, length-vs-epochCount) combination: no omission and no
  double-count, only the C-1 revert.

**`register` during an in-flight epoch cannot touch the frozen weights.**
(`test_F5_pruneRefusedDuringPay`, PASS.) `prune` correctly reverts `WrongPhase` during Pay (`:249`).
`register` is ungated but only `push`es, so new entries land at index `>= epochCount` with
`weight == 0` and are not paid that epoch — asserted (`"late registrant not paid this epoch"`).
A `push` never moves existing elements, so a reentrant `register` from inside the `pay` loop is
harmless too.

**IMD accounting is sound. No double-count, no overdraw, no underflow.**
(`test_F5b_directImdTransferIsBookedOnce`, PASS.) `_book` (`:449-457`) is reachable only from `fire`
(`Idle`-only), computes `tracked = pot + epochQuote` and books `bal - tracked` once; a direct IMD
transfer to the engine is booked exactly once, asserted against the balance. I also checked the
invariant mid-`Pay`, where `pot + epochQuote` deliberately exceeds the real balance by `paid`:
`_tip`'s guard `if (amt == 0 || pot < amt) return` (`:497`) is still safe, because
`B_mid = B0 - paid >= pot0 + total - paid >= pot0 >= amt`. At the end of `pay`,
`leftover = total - epochPaidQuote` cannot underflow (the sum of `mulDiv(total, w, tw)` over all `w`
is at most `total`), and `pot += leftover` restores the invariant exactly. `_tip` also fully
reverses itself if `_send` fails (`:500-503`).

**A failed payout cannot be retried or double-paid.** `pay` zeroes `h.weight` *before* `_send`
(`:366-369`), so a refused address cannot be paid twice and its share falls into `leftover`.
`epochQuote` and `totalWeight` are read once per page from storage (`:357-358`), so a holder's share
does not depend on which page it lands in, exactly as the comment claims.

**`_isPool` is not fooled by dirty return data.** (`test_F7_isPoolDirtyWordEvasion`, PASS.)
`_probe` writes a raw 32-byte word into an `address` local via assembly (`:521`), which looks like a
classic dirty-upper-bits escape. I built a contract returning `uint256(uint160(token)) | (1 << 200)`
and it was still correctly refused registration — solc masks the operand at the comparison. The
clean-shaped pool is refused too. (L-5's *gas*-based evasion is a separate and real gap.)

**`fire`'s `hook.flush()` is not a V4-unlocked window into the engine.** `flush` opens its own
unlock (`PimdHook.sol:437`) but `unlockCallback` only does `_payOut` (`PimdHook.sol:446-502`), and the unlock
closes before `flush` returns, so `_book` and the rest of `fire` run with the PoolManager locked.
Registrations or prunes performed from inside `flush` land before `n = holders.length` is read
(`:283`), so the snapshot is consistent either way.

**`_released` / `_pow` cannot overflow or underflow in the allowed config range.** With
`dripBpsPerPeriod <= 5_000` and `frac < PERIOD`, the partial-period term
`dripBps * WAD * frac / (BPS * PERIOD)` is at most `4.99e17 < WAD` (`:471`), so the subtraction is
safe; `keepPerPeriod >= 0.5e18`; `_pow`'s exponent is at most `7 days / 15 min = 672`; and
`keep <= WAD` makes `p - mulDiv(p, keep, WAD)` safe (`:472`). `maxCatchup` correctly bounds a dead-
keeper gap (`:467`).

**Narrowing casts are safe for this supply.** PIMD's supply is fixed at `1e27`
(`PimdToken.sol:28`), so `uint128(bal)` (`:326`), `uint128(w)` where `w <= 3e27` (`:329`) and
`uint64(block.timestamp)` (`:236`, `:321`, `:324`) cannot truncate. `h.received += uint128(amt)`
(`:370`) would need 3.4e20 IMD to overflow.

**Solmate's `ReentrancyGuard` does not block the legitimate same-transaction sequence.** It uses a
per-call storage flag, so `fire` → `tally` → `pay` as three sequential external calls in one
transaction is allowed. That is what makes H-1's single-transaction attack possible, and it is also
required for any honest keeper batching, so it is not itself a defect — but it does mean
`nonReentrant` provides no protection against single-transaction epoch manipulation.

---

## Recommended order of work

1. **C-1 / C-2 together.** They are one root cause: `epochCount` is a stale snapshot that nothing
   can reduce, combined with an all-or-nothing loop. Any fix must make `tally`'s work shrinkable
   *and* keep `prune` from invalidating the snapshot, and it must leave a path out of `Tally` that
   does not depend on the loop fitting in a block. An explicit `abandonEpoch()` that returns
   `epochQuote` to the pot and sets `phase = Idle` after some timeout would be a cheap
   belt-and-braces addition regardless of which fix is chosen.
2. **H-1.** Weight from a minimum-over-epoch balance rather than a live one. Do not rely on
   `_requireLocked`; it cannot enumerate lenders, and the attack needs no lender at all.
3. **M-1, M-3.** One-line reorderings in `fire` and `tally`.
4. **L-2.** Fork-measure IMD's `transfer` before launch. This one is a launch blocker if it fails.
5. **M-2.** Decide the policy on contract holders before `bind`, because `excluded` is write-once.
