# Ponzinomics ($PIMD) adversarial review

Six independent reviewers, one lens each, line by line over 1,188 lines at `e9d2da4`.
Every finding below was re-verified in source or on chain before it was written down.
Four of the six carried passing proof-of-concept tests; two also used mutation testing
(delete the defence, re-run its own tests, see whether anything notices).

**Verdict: do not launch.** Three launch blockers, all in the engine, all introduced or
left open by tonight's fixes. The hook's money path is sound. The deployment record
would also revert the paid launch for reasons that have nothing to do with security.

---

## 1. Launch blockers

### C1. Any address can brick the engine permanently, for gas. Four reviewers, independently.

`fire()` freezes `epochCount = holders.length` (`PimdEngine.sol:292`). The atomic
`tally()` loops `holders[i]` up to `epochCount` and refuses a smaller `maxHolders`
(`:311-316`). `prune()` is allowed during Tally and pops the array (`:249-257`).

One `prune` call during Tally and `tally` reverts `Panic(0x32)` for ever. `fire` and
`pay` both revert `WrongPhase`. There is no admin, no timeout, and `bind` is spent.
The epoch's IMD is stranded and the hook keeps accruing holder income that can never
be paid out.

The `prune`-during-Tally allowance was written *as the escape hatch* for the deadlock
introduced earlier tonight. Its NatSpec at `:242-247` argues at length that it must be
allowed. It is not an escape hatch, it is the brick, and it is worse than what it
replaced. The symmetric hole in `pay` was closed and Tally was missed.

### C2. The same bound is terminal with no attacker at all.

`prune` skips anyone still holding `minBalance` (`:253`), so an oversized holder set
cannot be shrunk, and the atomic tally has no cap. Four independent gas measurements of
`tally` came in at 13.5k, 33.6k, 35.6k and 39.1k per holder depending on holder state,
so the ceiling against a 32M block is roughly **800 to 950 holders**. Hostile contract
holders that burn both `_isPool` probes cost 58.3k each, cutting it to about **330**.

Past that point the next `fire()` wedges the epoch and nothing can shrink the set.
Ponzinomics crossing a few hundred holders bricks itself.

### C3. The flash loan that makes C1 and C2 free.

`register()` and `prune()` have neither `nonReentrant` nor `_requireLocked()`
(`PimdEngine.sol:225`, `:249`), unlike `fire`/`tally`/`pay`. Inside a `PoolManager`
unlock you `take` the pool's PIMD, walk one bag through as many addresses as you like
registering each, settle, then `fire()` and `prune([child])`. Zero capital, one
transaction, engine dead on return.

---

## 2. High

### H1. Borrowed weight. The streak blend plus a flash guard that only watches Uniswap.

The blend at `:324` conserves balance times age, so a wallet that has held the minimum
for a while can absorb a borrowed bag and keep a tier. `_requireLocked` reads only the
V4 PoolManager's unlocked slot (`:461`), so Aave, Balancer, a V2 pair or a one-block OTC
loan are all unguarded, and `fire` and `tally` are both permissionless. Weights freeze
at `tally`, so the loan spans one transaction and `pay` later honours it.

With the live `minBalance` of 100,000 PIMD (0.01% of supply), the bound is
`B <= (ageHours - 1) x minBalance`:

| seed wallet age | borrowable at the 0.5x tier | as % of supply |
|---|---|---|
| 30 days  | 71.9M PIMD | 7.2% |
| 180 days | 431M PIMD  | 43% |
| 365 days | 876M PIMD  | 88% |

Correction to what was reported mid-review: the 72%-at-30-days figure assumed a
1,000,000 PIMD minimum. The live engine's minimum is 100,000, so 30 days gives 7.2%,
and the attack scales with how long the seed wallet has been sitting rather than with
capital committed.

### H2. The liquidity lock is correct and completely untested.

`beforeRemoveLiquidity` refusing `liquidityDelta < 0` is the entire safety case for
letting the IMD pad hold the LP position. One reviewer attacked it hard against v4-core
source and **it holds**: `SafeCast.toInt128` makes the sign check equivalent,
`liquidityDelta <= 0` routes to remove so a zero delta cannot reach the seed, claims
cannot be burned or transferred by anyone, `take` must settle, `donate` only adds, and
`noSelfCall` does skip those callbacks but the hook makes no call that reaches them and
owns no position.

Mutation testing then showed `beforeAddLiquidity` and `beforeRemoveLiquidity` can be
**deleted outright and all five liquidity tests still pass**. `Pimd.t.sol:255,392,407`
never approve PIMD to the LP router, so the revert comes from the allowance, not the
hook. `:417` removes from `lpRouter`, which owns no position, so V4 reverts
`CannotUpdateEmptyPosition` regardless. `:428` has no assertions at all. The `seeded`
guard at `PimdHook.sol:353` is unreachable by any test.

The code is right today. Nothing stops the next edit from breaking it silently.

---

## 3. Medium

- **M1. The keeper tip can take the whole team slice.** `callerTip = 0.01e18` is
  `constant` (`PimdHook.sol:105`), clamped by `if (tip > toTeam) tip = toTeam` (`:433`).
  The team's cut is 0.6% of a buy and 1.4% of a sell, so below 1.667 IMD of buys or
  0.714 IMD of sells accrued between flushes the caller takes **all of it** and
  `_payOut(team, 0)` moves nothing. A bot flushing after each small trade collects it
  every time. Holders are untouched. No owner and a `constant` tip means this cannot be
  changed after deploy.
- **M2. The `flushHolders` fix was never wired in.** `fire()` still calls `hook.flush()`
  (`PimdEngine.sol:274`) and `IPimdHookLike` does not declare `flushHolders` (`:15-21`).
  The engine cannot reach it. The empty `catch {}` was gated, not fixed, and
  `holdersOwed()` sits outside the `try`. A blocked team wallet still silently halts the
  drip, despite a commit message saying otherwise.
- **M3. `_isPool`'s probe budget is burnable** at 58.3k gas per hostile holder, the
  measured constant behind C2's ceiling. Each probe is capped; the aggregate is not.
- **M4. Keepers are tipped for epochs that distribute nothing.** `tipBudget` is set
  before the `drip != 0 && n != 0` gate (`:281`) and `_tip(fireTip)` runs
  unconditionally (`:296`).
- **M5. `bind` validates the hook three ways and `token_` not at all.**
- **M6. `SEND_GAS = 60_000` against a measured live-IMD requirement of 37.5k to 40k.**
  About 1.5x headroom, less than one cold `SSTORE`. It works today, confirmed by the
  passing fork test that moves real IMD, but the failure mode is silent and permanent:
  `pay` reports success, `totalDripped` stays 0, and the epoch recycles into the pot for
  ever behind a `PayoutFailed` event. No test measures it.
- **M7. The deploy script has been broadcast twice and two engines are live.**
  `0xC0533818...` (11KB of code) and `0x92A9ABEB...`. The hook's `ENGINE_ADDRESS`
  constant names the second. The script has no address assertion, so a third run
  silently breaks the hook and you find out at `bind`, after paying for the launch.

---

## 4. The deployment record would revert the launch on its own

`deployments.pimd.4663.json` is stale and contradicts both the hook's compiled constants
and the live chain:

| field | record | truth |
|---|---|---|
| `startTick` | 143580 | must be within 300 of **129000**. Off by 14,580 ticks, reverts |
| `buyTaxBps` | 300 | **240** |
| `sellTaxBps` | 700 | **560** |
| `engine` | `0xC0533818...` | hook names `0x92A9ABEB...` |
| `deployer` | `0x244FA8fd...` | factory's `deployer()` is `0xcECc29B0...` |

And the live engine's config differs from the config all 46 tests run against:

| parameter | live chain | tests (`PimdBase.t.sol:190-201`) |
|---|---|---|
| `maxCatchup` | 3600 (1 hour) | 6 hours |
| `fireTip` | 0.01 IMD | 0.02 IMD |
| `tipPerHolder` | 0.0001 IMD | 0.0005 IMD |
| `minBalance` | 100,000 PIMD | 100,000 PIMD (matches) |
| `minInterval` | 120s | 120s (matches) |
| `dripBpsPerPeriod` | 400 | 400 (matches) |

`maxCatchup` matters most: `PimdAttacks.t.sol:245-250` asserts in prose that one epoch
can never release more than `1 - 0.96^24 = 62.5%` of the pot. At the live 1 hour it is
`1 - 0.96^4 = 15.1%`. One of the two is wrong, and it is a decision rather than a bug.

---

## 5. Verified sound

Worth stating plainly, because it is most of the code.

- **All four swap shapes.** Re-derived by two reviewers against vendored v4-core. No
  theft, no free trade, no sign error. Both fee forms are on the correct side and land
  on exactly 2.40% and 5.60% of the gross IMD leg. Every division truncates toward the
  protocol, so the hook can never mint more claims than the swapper was charged. The
  mint-to-book invariant holds and `_split` conserves exactly.
- **The `_SPEC_SLOT` partial-fill guard is correct**, confirmed twice, once by PoC across
  four shapes in both orders in one transaction and across a `PartialFill` revert.
- **All 25 narrowing casts are safe.** `released <= pot` proven by induction through
  `_pow`; `sum(shares) <= epochQuote` proven exactly; dust goes to the pot, so splitting
  into many positions loses money. `circulatingSupply()` cannot underflow or double-count.
- **The whole reentrancy family is closed by measurement, not argument.** Live IMD on a
  fork hands the recipient no execution, is not a proxy, and has no fee, blacklist or
  dividend surface. `_send` is not an entry point.
- **The engine's `IS_UNLOCKED_SLOT` is byte-identical to v4-core's `Lock.sol`.**
- **The atomic tally does close the original sybil double-count** and no second route was
  found: `holders` cannot hold duplicates, each slot is visited once, and nothing can
  move PIMD inside the loop.
- **Our sender pinning will not break the real launch.** The factory's on-chain bytecode
  contains `unlock`, `unlockCallback`, `initialize(PoolKey,uint160)`, `modifyLiquidity`,
  `settle` and `take`, so it drives the PoolManager directly from its own address. No
  router, no PositionManager in the path. This was the open launch-blocking question and
  it is retired.

---

## 6. Still open

Whether a stranger can drive the factory against our hook, squatting the one seed with
dust or latching a wrong fee tier. The factory ABI recovered from its dispatcher includes
`openRound(bytes32,uint256,uint64)` and a `deployer()` of `0xcECc29B0...`, the swarm's
launch wallet, which suggests the opener is privileged, but three of the access-control
getters revert, so the signature guesses are unreliable. Settled by `cast run` on a prior
launch transaction, to see who called `openRound` and how many liquidity adds it makes.

---

## 7. What the fix has to decide

C1, C2, C3 and H1 are one design tension rather than four patches: an atomic tally stops
the sybil double-count but needs a bounded holder set, and weighing live balances needs a
flash guard that cannot be built generically.

The shape that resolves all four is a bounded holder set, a real abort path out of Tally,
`prune` back to Idle-only, and weighing on `min(balance, lastBal)` so tokens must survive
one epoch to count.

That last change makes a fresh buy wait one epoch, which is a change to the economics
fixed deliberately earlier. That is a decision for the owner of the economics, not for
the reviewer.

---

No contract source was modified during this review. `src/`, `script/` and tracked tests
are byte-identical to `e9d2da4`, and the suite is 52/52 green (46 local, 6 fork against
real IMD state).
