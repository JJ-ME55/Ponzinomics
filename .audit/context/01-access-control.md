# 01 — Access control and the launch path

Scope read in full at local HEAD `e9d2da4` ("Clear the dead swap branch and count every burn"):
`src/pimd/PimdHook.sol` (525), `src/pimd/PimdEngine.sol` (524), `src/pimd/PimdToken.sol` (49),
`src/libraries/L2Block.sol` (21), `script/DeployPimd.s.sol` (69). Cross-read against
`lib/v4-periphery/lib/v4-core/src/{PoolManager.sol, libraries/Hooks.sol, libraries/Position.sol, types/Currency.sol, libraries/SafeCast.sol, ERC6909Claims.sol}`
and against the prior report `AUDIT-1b073df.md` (16 findings).

The existing suite (58 tests) passes at this commit. Every finding below is outside its coverage.
All proofs were run with `forge test` against the repo's own `PimdBaseTest` harness and then removed;
the sources are in the session scratchpad (`ZZScratchAccessControl.t.sol`, `ZZScratch2.t.sol`,
`ZZScratch3.t.sol`, `ZZScratch4.t.sol`). `test/pimd/PimdBase.t.sol` needed one word
(`_openPoolAsFactory() internal virtual`) for the launch-window proofs; that edit has been reverted.

| # | Sev | Where | One line |
|---|---|---|---|
| F-01 | **CRITICAL** | PimdEngine.sol:249, 254-257, 292, 315-316 | `prune` during `Tally` desyncs `holders.length` from `epochCount`; `tally` then reverts out-of-bounds forever. Engine bricked permanently, one tx, zero capital. |
| F-02 | **CRITICAL** | PimdEngine.sol:311, 315-331, 253 | Atomic `tally` over an unbounded, permissionlessly grown, un-prunable holder set. ~899 plain / ~484 hostile holders exceed a 32M-gas block; the next `fire` bricks the engine permanently. |
| F-03 | HIGH | PimdEngine.sol:225-239 | `register` has no `_requireLocked()`: PIMD flash-borrowed out of the PoolManager registers unlimited addresses at zero capital cost. Delivery vehicle for F-01/F-02. |
| F-04 | HIGH (POTENTIAL in prod, PROVEN against the repo's factory model) | PimdHook.sol:231, 352 | `sender` pins the factory *contract*, not whoever drives it. If the real pad exposes an unpermissioned open/seed on a caller-supplied `PoolKey`, audit findings #2 and #3 are not fixed. |
| F-05 | MEDIUM | PimdHook.sol:232, 407-419, 504-508; DeployPimd.s.sol:65 | A stale `ENGINE_ADDRESS` is never checked for code; `flushHolders` is permissionless, so anyone can irrecoverably push the holders' IMD to a codeless address. |
| F-06 | MEDIUM | PimdEngine.sol:185-198 | `bind`'s new checks do not cover `token_` (or `hook.token()`), and bind is one-shot. |
| F-07 | MEDIUM | PimdEngine.sol:180-211, 229 | Exclusion is bind-time-only and irreversible in both directions. |
| F-08 | MEDIUM | PimdEngine.sol:273-274; PimdHook.sol:407, 427 | `fire` still pulls through the breakable `flush()`, not the new `flushHolders()`, and the catch is still empty. Findings 5+6 half-fixed. |
| F-09 | LOW | PimdHook.sol:233-236, 248-251 | The "only gate" enforces price to ±3% but accepts a 25x-wrong LP fee tier and any `tickSpacing`. |
| F-10 | LOW | PimdEngine.sol:281, 295 | `fireTip` still paid for a no-op epoch (finding 11 unfixed). |
| F-11 | LOW | PimdEngine.sol:58, 486-490 | `SEND_GAS = 60_000` is a hard, unescapable assumption about a third party's token. |
| F-12 | INFO | PimdEngine.sol:310-311, 333-334 | Dead paging remnants in `tally`. |
| F-13 | INFO | PimdHook.sol:331, 491 | `LAUNCH_CAP_MAX_SECONDS` still dead (finding 13 unfixed). |
| F-14 | INFO | L2Block.sol:16-20; PimdHook.sol:257, 273, 329 | L2/L1 block-number mixing makes `InitBlockSwap` and the block half of the launch cap unreliable. |
| F-15 | INFO | PimdHook.sol:369-381 | "Liquidity can never leave" covers principal only, not the 1.25% LP fee. |
| F-16 | INFO | PimdHook.sol:116-133 | A derived hook can open its own look-alike PIMD pool with a different team wallet. |
| F-17 | INFO | DeployPimd.s.sol:27-59; PimdEngine.sol:159-175 | Unvalidated env overrides; `minInterval`/`minBalance` unvalidated; `binder` is one EOA whose loss strands all holder income. |

---

## F-01 CRITICAL — `prune()` during `Phase.Tally` permanently bricks the engine

`src/pimd/PimdEngine.sol:249` — `if (phase == Phase.Pay) revert WrongPhase();`
`src/pimd/PimdEngine.sol:254-257` — the swap-and-pop
`src/pimd/PimdEngine.sol:292` — `epochCount = n;`
`src/pimd/PimdEngine.sol:311, 315-316` — `maxHolders < epochCount` reverts; `for (i; i < end=epochCount) { holders[i] }`

`fire()` snapshots `epochCount = holders.length` and sets `phase = Tally`. `tally()` is now required to
weigh the **whole** set in one call: it rejects `maxHolders < epochCount` (:311) and loops `holders[i]`
for `i < epochCount` (:315-316). `prune()` is **deliberately permitted during `Tally`** (:249, and its
NatSpec at :242-247 argues it must be, as the escape hatch for an oversized set) and it `pop()`s
`holders` (:254-257). Nothing ever recomputes `epochCount` except `fire()`, and `fire()` requires
`phase == Idle`.

### Attack path
1. Attacker registers a throwaway address `X` holding `minBalance` PIMD (`register` is permissionless,
   :225), then moves the bag out, so `balanceOf(X) < minBalance` and `X` is prunable.
   (With F-03 the bag is flash-borrowed from the pool, so this step costs no capital at all. Any real
   holder who has sold down below `minBalance` serves just as well, so after a few days of trading the
   attacker needs no setup step whatsoever.)
2. Attacker calls `fire()` (permissionless, :266) once `minInterval` has elapsed. `epochCount` is now
   `holders.length`, `phase == Tally`, `epochQuote` holds this epoch's IMD.
3. Attacker calls `prune([X])` (:248). `phase != Pay`, so it is allowed. `holders.length` becomes
   `epochCount - 1`.
4. Every subsequent `tally(n)` must pass `n >= epochCount` and loops to `epochCount - 1`, so it reads
   `holders[epochCount - 1]` — out of bounds. Solidity reverts `Panic(0x32)`. **Always.**
5. `fire()` reverts `WrongPhase` (phase is `Tally`). `pay()` reverts `WrongPhase`. `prune()` can only
   shrink `holders` further. There is no admin, no setter, and `bind` is spent.

### What the attacker gains
Permanent, unrecoverable denial of the entire holder payout system. `epochQuote` is stranded. `pot` can
never release again. `flushHolders()` keeps pushing every future holder slice of the 2.4%/5.6% tax into
the engine, where it is never even booked (`_book()` only runs inside `fire()`, :276). The team keeps
being paid; holders never are. The "75% to holders" claim becomes false for the life of the token.

Cost: one transaction and one `minBalance` bag that the attacker keeps. Steps 1-3 fit in a single
transaction.

### Proof (passes)
`test_prune_during_tally_bricks_the_engine_forever` and `test_one_transaction_zero_capital_brick`.
The second is the full zero-capital version: one contract call that (a) unlocks the PoolManager,
`take`s 100,000 PIMD out of the pool's reserves, registers a fresh child contract with it, sweeps it
back and settles; then (b) calls `fire()`; then (c) calls `prune([child])`. On return,
`phase == Tally`, `tally(500)` reverts `Panic(0x32)`, `fire()` reverts `WrongPhase`, and
`epochQuote > 0`. Re-asserted after `vm.warp(+365 days)`.

### Not a false positive
`prune`-during-`Tally` is not an accident — it is documented and intended (:242-247). The out-of-bounds
read is unconditional arithmetic, not a race. `epochCount` has exactly one writer (:292) behind a
`phase == Idle` guard. The symmetric hole in `pay` **was** closed (`prune` is refused during `Pay`,
:249), which shows the desync was considered for one phase and missed for the other. The existing suite
never calls `prune` while an epoch is open.

### Fix direction (no economics touched)
Either refuse `prune` unless `phase == Idle` (and give the oversized-set problem a different escape),
or make `tally` tolerant: snapshot the length and clamp, e.g. `uint256 end = epochCount; if (end > holders.length) end = holders.length;`.
The first is simpler and removes the desync entirely; the second must also handle the swap-and-pop
moving an untallied holder into an already-read slot.

---

## F-02 CRITICAL — atomic `tally` has no bounded holder set, and the documented escape hatch cannot reach the holders that cause it

`src/pimd/PimdEngine.sol:311` — `TallyMustBeWhole`
`src/pimd/PimdEngine.sol:315-331` — the single loop: `balanceOf` + `_isPool` + four storage writes per holder
`src/pimd/PimdEngine.sol:253` — `prune` skips any holder whose balance is `>= minBalance`
`src/pimd/PimdEngine.sol:510-523` — `_isPool` makes two `staticcall`s at `PROBE_GAS = 30_000` for any holder with code

The fix for audit finding #1 made `tally` all-or-nothing. `register` remained permissionless with no cap
on `holders.length` (finding 10, unfixed). The NatSpec at :300-306 names `prune` as the remedy for an
oversized set — but `prune` refuses to remove any holder still holding `minBalance` (:253). So a holder
set that is too large to weigh in one block **cannot be shrunk**, and `tally` can never complete.

### Measured cost per holder (this repo's harness, `minBalance = 100_000e18`)

| holder kind | gas per holder in `tally` | holders to reach 32,000,000 gas |
|---|---|---|
| plain EOA | 35,560 | **899** |
| contract whose `token0()`/`token1()` burn the full 30,000-gas probe | 66,080 | **484** |

(`test_gas_cost_of_eoa_holders_in_tally`, `test_gas_cost_of_hostile_contract_holders_in_tally`, both
pass and log these numbers.)

### Attack path
1. Attacker spreads `484 x 100,000 = 48,400,000 PIMD` (**4.84% of supply**, Robinhood config) across 484
   contracts whose `token0()`/`token1()` burn the probe budget, and registers them all (permissionless,
   cheap, spread over as many transactions as wanted).
2. Attacker calls `fire()`. `epochCount` now includes all of them, `phase = Tally`.
3. `tally` needs >32M gas and cannot be executed. `prune` cannot touch them (balance `>= minBalance`).
4. The attacker then sells the bags. Now they *are* prunable — but pruning them triggers F-01's
   out-of-bounds brick. **Either branch is permanent**, so the attacker recovers all capital and the
   engine stays dead.

A plain-EOA variant needs 899 bags, i.e. ~9% of supply, and no contract deployment at all.
On the mainnet config (`minBalance = 1_000_000e18`) the capital requirement rises to ~48% of supply,
so this is primarily a Robinhood-config finding — and Robinhood is the script's default chain.

### Also reachable with no attacker at all
899 ordinary holders is a perfectly normal number for a launched memecoin. The first `fire()` after the
holder count crosses the ceiling freezes the engine in `Tally` forever, with the same two dead branches.
`epochCount` and `holderCount()` being public (as :305-306 notes) lets a keeper *watch* the ceiling
approach; it gives nobody a way to stop crossing it, because registration is permissionless.

### Not a false positive
The ceiling is arithmetic, not a guess: the per-holder gas was measured on this code. The contract has
no cap, no admin, and `bind` is spent. The two "escapes" the comments name (`prune`, and the public
counters) do not work. A 32M block gas limit is the figure used above; the finding is insensitive to the
exact number — it only changes the holder count.

### Fix direction
Restore paging but make the epoch's weights snapshot-consistent instead of live (`min(bal, lastBal)`,
with increases credited from the next epoch, is the mitigation the prior report already proposed for
findings 1 and 7 and costs nothing in economics); or cap `holders.length` at registration; or let
`tally` drop entries whose balance is below `minBalance` in-loop so the set self-trims, and let `prune`
remove any registered address when the set is oversized.

---

## F-03 HIGH — `register()` is the one state-changing entry with no `_requireLocked()`, so flash-borrowed PIMD registers unlimited addresses at zero capital cost

`src/pimd/PimdEngine.sol:225-239` — no `_requireLocked()`; `bal` read at the instant of the call (:230-231).
Compare `fire` :270, `tally` :309, `pay` :351.

`PoolManager.take(currency, to, amount)` hands out real PIMD against a negative delta that only has to
be settled before the unlock closes — a free, uncapped flash loan of up to the pool's entire ~900M PIMD
reserve. `register` reads `balanceOf(a)` with no unlock guard, so inside one unlock an attacker can park
one bag in address after address and register each.

### Proof (passes)
`test_register_works_with_flash_borrowed_pimd_inside_an_unlock`: a contract unlocks the PoolManager,
`take`s 100,000 PIMD, and in a loop creates a child, funds it, calls `engine.register([child])` and
sweeps the bag back, then `sync`/`transfer`/`settle`s. Five addresses registered; `holderCount()` grows
by 5; every child's PIMD balance is 0 afterwards. Zero capital.

### Why it matters
The engine's own design note (:45-49) says the unlock guard exists because "weights are read from
balances" and "inside an unlock a flash borrower can hold an enormous PIMD balance". `register` writes
`lastBal` and `streakStart` **from exactly such a balance** (:235-236) and is the gate that decides who
is in `holders` at all. Leaving it out of the guard is an inconsistency, not a judgement call.
Concretely it is what makes F-01 and F-02 capital-free, and it re-opens finding 10 at a far lower price
than that report assumed (which assumed a real bag had to be bought and held).

The guard is also absent from `prune` (:248), where the consequence is milder: a flash-borrowed balance
makes a holder look un-prunable for the length of a callback.

### Fix
Add `_requireLocked()` to `register` and `prune`, and prefer `msg.sender == account` self-registration.

---

## F-04 HIGH (POTENTIAL for production) — the factory pin binds the factory *contract*, not whoever drives it

`src/pimd/PimdHook.sol:231` — `if (sender != launchFactory()) revert NotLaunchFactory();` in `beforeInitialize`
`src/pimd/PimdHook.sol:352` — the same in `beforeAddLiquidity`

`sender` is `msg.sender` as seen by the PoolManager (`Hooks.sol:178-182`;
`PoolManager.modifyLiquidity` passes `msg.sender`), i.e. the address that called `initialize` /
`modifyLiquidity`. Pinning it to `LAUNCH_FACTORY` (`0xA25B02A1e93903b790E6aaf7dA1b8B8d50294645`) stops a
stranger calling the PoolManager **directly** — which is all the two new tests prove
(`test_only_the_launch_factory_may_open_the_pool`, `test_a_stranger_cannot_squat_the_seed`). It says
nothing about a stranger calling **the factory**.

The pad this hook launches on is permissionless. If its open/seed entry points take a caller-supplied
`PoolKey` (or a caller-supplied hook address) without restricting the caller, then audit findings #2 and
#3 are **not fixed at all** — the attacker just adds one hop.

### Proven against this repo's own factory model
`test/pimd/PimdBase.t.sol`'s `MockLaunchFactory.open()` and `.seed()` are both `external` and
unpermissioned, which is the shape a permissionless pad plausibly has.

* `test_a_stranger_can_squat_the_seed_by_routing_through_the_factory` (passes): pool open, not yet
  seeded. Anyone sends 1 IMD to the factory, then calls `factory.seed(key, 129060, 129120, 1e6)`.
  A range strictly above spot needs only IMD, so dust is enough. `beforeAddLiquidity` sees
  `sender == factory`, sets `seeded = true`, and the factory's real ~900M-PIMD seed then reverts
  `LiquidityIsLocked()` (`0x6bac637f`, wrapped by `Hooks`' `CustomRevert` as
  `WrappedError(hook, 0x259982e5, 0x6bac637f, HookCallFailed())`). Nothing resets `seeded` or
  `launched`; the hook is spent on an empty pool and the launch must be redone with a new hook.
* `test_a_stranger_routing_through_the_factory_picks_the_pool` (passes): a stranger drives
  `factory.open()` with `fee: 500`, `tickSpacing: 32_767` and the opening price 300 ticks off (the far
  edge of tolerance). The hook accepts it, latches `launched`, and the real `fee: 12_500` /
  `tickSpacing: 60` pool is then refused `AlreadyLaunched()` forever.

### What settles it
The source of `0xA25B02A1e93903b790E6aaf7dA1b8B8d50294645` on Robinhood Chain. Specifically:

1. Does a single launch call deploy the token, deploy the hook, `initialize` **and** `modifyLiquidity`
   atomically in one transaction? If yes, both windows are closed and this drops to INFO.
2. Does the factory call `PoolManager.modifyLiquidity` itself, or route the seed through a
   PositionManager / router? **If it routes, `sender` is that router and the factory's own seed reverts
   `NotLaunchFactory` — the launch bricks on the first attempt.** This is the inverse risk on the same
   line and is worth checking before the launch request goes out, because `launched` latches on
   `initialize` and `beforeAddLiquidity` has no second chance for a different `sender`.
3. Does it expose any other path (migrate, re-open, a generic `execute`) that reaches `initialize` or
   `modifyLiquidity` with caller-supplied arguments?

### Fix direction that does not depend on the answer
Record the `sender` seen in `beforeInitialize` and require `beforeAddLiquidity`'s `sender` to equal it
(closes the squat regardless of who drove the open), and require the seed in `initBlock` (closes the
window entirely). Pin `key.tickSpacing` and `key.fee` to the launch policy's single pair.

---

## F-05 MEDIUM — a stale `ENGINE_ADDRESS` is never detected at launch, and `flushHolders()` lets anyone burn the holders' IMD to it

`src/pimd/PimdHook.sol:93` — the `ENGINE_ADDRESS` constant
`src/pimd/PimdHook.sol:232` — `if (engine() == address(0) || team() == address(0)) revert BadConfig();`
`src/pimd/PimdHook.sol:407-419` — `flushHolders`, permissionless
`src/pimd/PimdHook.sol:504-508` — `_payOut` → `poolManager.take`
`script/DeployPimd.s.sol:65` — "write this address into PimdHook.ENGINE_ADDRESS, push, then quote the launch"

The engine's address reaches the hook by a human copying it from the deploy script's console output into
a source constant. `beforeInitialize` only checks it is non-zero. `PoolManager.take` →
`CurrencyLibrary.transfer` (`types/Currency.sol`) is a bare ERC-20 `transfer` with **no check that `to`
has code**, so if the constant is stale or belongs to a different chain's engine:

1. The pool opens normally; taxes accrue; `holdersOwed` grows.
2. `flushHolders()` is permissionless (:407) and requires only `launched && holdersOwed != 0`. Anyone —
   including a bot watching the launch — calls it. `take` succeeds and the IMD lands at an address
   nobody controls. Irrecoverable.
3. The mistake is only surfaced when the binder calls `bind`, which now reverts `BadConfig`
   (`h.engine() != address(this)`, PimdEngine.sol:193) — i.e. **after** step 2 is already possible, and
   after `launched`/`seeded` have latched, so the remedy is a whole new hook and a new launch.

Cheap fix, consistent with the contract's own "fail loudly rather than open a wrong pool" stance
(:42-43): in `beforeInitialize`, `if (engine().code.length == 0) revert BadConfig();` and optionally
`if (PimdEngine(engine()).imd() != quoteToken()) revert BadConfig();` — the engine exposes `imd()` as a
public immutable, so this is one call and it makes a wrong constant unlaunchable.

Not a false positive: the check at :232 shows the author intended to validate the constant and chose the
weakest possible test. `take` to a codeless address was confirmed in the library source, not assumed.

---

## F-06 MEDIUM — `bind()`'s new verification does not cover the token

`src/pimd/PimdEngine.sol:185-198`

The three new checks (`h.engine() == address(this)`, `h.quote() == imd`, `h.poolManager() == poolManager`)
correctly close audit finding 9's main case, and `h.quote() == imd` implicitly requires the pool to be
open, because `quote` is only written in `beforeInitialize` (PimdHook.sol:253). That is a good side
effect. What is still unchecked:

* `token_` is only tested for `!= address(0)` (:188). The hook publishes `token` as a public immutable,
  so `IPimdHookLike(hook_).token() == token_` is one call. Without it, a mistyped `token_` produces an
  engine that reads balances from the wrong ERC-20, binds cleanly, fires cleanly, weighs everybody at
  zero (or weighs the wrong holders) and cannot be corrected — `bind` is one-shot (:187).
* `seeded` is not required, so the engine can bind to a pool that was opened but never seeded (which,
  per F-04, is a reachable end state).
* The checks are satisfiable by any contract returning three constants, so they verify *consistency*,
  not honesty. That is acceptable — `bind` is binder-only, and a binder who deploys a hostile hook has
  already lost — but it means the checks are a typo guard rather than a trust boundary, and the one
  remaining typo surface (`token_`) is the one left open.

---

## F-07 MEDIUM — exclusion is bind-time only, and irreversible in both directions

`src/pimd/PimdEngine.sol:180-211` — `alsoExclude`
`src/pimd/PimdEngine.sol:229` — `excluded` is consulted **only** in `register`

`excluded` is written once, at `bind`, and never again. Two consequences:

* **Nothing discovered later can be excluded.** The deploy script's own warning
  (`DeployPimd.s.sol:67`: "The airdrop distributor MUST be in that list, or it earns drips nobody can
  claim") describes an unrecoverable one-shot. If the distributor address is wrong or missing, anyone
  can `register` it (permissionless, :225) and up to a tenth of supply's worth of weight drips into a
  contract that cannot forward IMD — diluting every real holder, forever, with no way to stop it. The
  same applies to any CEX hot wallet, treasury, vesting contract or bridge that later holds PIMD.
* **The binder can permanently blacklist arbitrary addresses.** `alsoExclude` is unbounded and
  unvalidated; an address in it can never register and therefore can never be paid. In a contract whose
  NatSpec says "No owner. […] after that nothing about this contract can change" (:38-41), the binder
  holds one irreversible censorship action over an arbitrary set, visible only in the `Excluded` events.

Note also that `excluded` is checked nowhere but `register`, so exclusion is purely a registration
filter. That happens to be sound today only because `bind` necessarily precedes any `register`
(`register` reverts `NotBound`, :226); if a future change let addresses enter `holders` another way, the
exclusion list would stop working silently.

---

## F-08 MEDIUM — the fix for audit findings 5+6 added an escape hatch but did not route the engine to it, and the failure is still silent

`src/pimd/PimdEngine.sol:273-274` — `if (hook.holdersOwed() != 0) { try hook.flush() {} catch {} }`
`src/pimd/PimdHook.sol:407-419` — new `flushHolders`
`src/pimd/PimdHook.sol:427-444` — `flush`, still all-or-nothing across engine, team and tipper

`flushHolders()` is the right fix for finding 5 — it pays only the engine, so the holders' path no longer
depends on IMD being willing to transfer to `TEAM_WALLET`. But:

* `fire()` still pulls through `flush()` (:274), the function that can be bricked by the team leg
  (`_payOut(team(), toTeam)`, PimdHook.sol:460). If IMD ever refuses `TEAM_WALLET`, the automatic income
  path dies exactly as before; only a human who knows to call `flushHolders()` can revive it.
* The catch is still empty (finding 6 unfixed): no event, no reason bytes. A flush failing on every
  epoch is indistinguishable on chain from a quiet market, which is the precise failure mode the brief
  says has already bitten once.
* `hook.holdersOwed()` at :273 is still **outside** the `try`, so a hook whose view reverted would block
  `fire()` entirely, and Solidity still does not route `flush()`'s return-data decoding failures into
  the catch.
* `fireTip` is still paid for an epoch whose income never arrived (see F-10).

One-line improvement: have `fire()` call `flushHolders()` — the engine only needs the holders' slice —
and `catch (bytes memory reason) { emit PullFailed(reason, pending); }`.

---

## F-09 LOW — the "only gate" is strict about price and loose about everything else

`src/pimd/PimdHook.sol:233-236` — fee tier in {500, 3000, 10000, 12500}
`src/pimd/PimdHook.sol:248-251` — tick within ±300

`beforeInitialize` is described as the single gate that "checks the caller, the pairing, the quote
currency, the fee tier and the opening price" (:42-43). It enforces the opening price to ±300 ticks
(~±3%) and then accepts an LP fee of 0.05% where the launch policy's stated economics require 1.25%
(:36-39: "the pool charge[s] 1.25% of every trade and pays it to the launch's paying wallet; all of that
buys PIMD and burns it"). A 500 tier is a 25x cut to the burn, silently, latched forever.
`key.tickSpacing` is not looked at at all — `PoolManager.initialize` only bounds it to 1..32767 — and a
coarse spacing makes the intended `[82980, 129000]` seed range unrepresentable (`modifyLiquidity`
requires tick boundaries to be multiples of `tickSpacing`), forcing a different range than the launch
was priced for.

Demonstrated by `test_a_stranger_routing_through_the_factory_picks_the_pool` (fee 500, tickSpacing
32767, +300 ticks, all accepted). Severity is LOW on its own, since the factory is expected to pass
12500/60, and HIGH only in combination with F-04. The point here is that the gate's tolerances are
inconsistent with each other, so the strictness of the price check gives false assurance about the rest.

---

## F-10 LOW — `fireTip` is still paid when no epoch opens (audit finding 11, unfixed)

`src/pimd/PimdEngine.sol:281` — `tipBudget = (drip * TIP_BUDGET_BPS) / BPS;`
`src/pimd/PimdEngine.sol:285` — `if (drip != 0 && n != 0)`
`src/pimd/PimdEngine.sol:295` — `_tip(fireTip);`

Unchanged from `1b073df`: `tipBudget` is set from a notional drip before the check that an epoch actually
opens, and `_tip(fireTip)` runs unconditionally after it. With `holders.length == 0`, `lastFire`
advances, the pot is not released, and the caller is paid `min(fireTip, 5% of the notional drip)` out of
holders' money for a no-op, repeatable every `minInterval` (2 minutes by default). At the Robinhood
defaults (`fireTip = 0.01e18`) that is roughly 7 IMD/day leaked from the pot for as long as nobody is
registered.

---

## F-11 LOW — `SEND_GAS = 60_000` is an unescapable assumption about a third party's token

`src/pimd/PimdEngine.sol:58`, `:486-490` (`_send`), `:494-504` (`_tip` uses the same path)

Every IMD payout is a `call{gas: 60_000}`. The design note (:50-52) justifies the cap as protection
against one hostile recipient; the flip side is that if IMD's `transfer` ever costs more than 60,000 gas
— an upgrade adding hooks, a fee-on-transfer branch, a blacklist lookup, a different gas schedule on a
chain upgrade — then **every** payout and **every** tip silently returns `false` forever,
`PayoutFailed` is emitted for everybody, and all IMD rolls back into the pot (:387-388) where it
accumulates with no way out. There is no setter and no uncapped fallback. Worth either raising the cap
substantially or retrying uncapped for the final page.

---

## F-12 INFO — dead paging remnants in `tally`

`src/pimd/PimdEngine.sol:310-311`: `uint256 start = cursor; if (start != 0 || …)`. `cursor` is set to 0
by `fire()` (:291) and can only be non-zero while `phase == Pay`, so `start != 0` is unreachable while
`phase == Tally`. `:333-334`: `cursor = end; if (end == epochCount)` — `end` is assigned `epochCount` at
:312 and never changed, so the write is immediately overwritten and the branch is always taken.
`_tip(tipPerHolder * (end - start))` at :345 is therefore always `tipPerHolder * epochCount`. Harmless,
but it reads as if paging still exists, which is how a future change could re-arm F-01's sibling.

---

## F-13 INFO — `LAUNCH_CAP_MAX_SECONDS` still dead

`src/pimd/PimdHook.sol:331` and `:491`. `launchCapSeconds` (600) < `LAUNCH_CAP_MAX_SECONDS` (3600), so
the third conjunct can never bind. Unchanged from audit finding 13, and see F-14 for why it matters more
than the prior report suggested.

---

## F-14 INFO — L2/L1 block-number mixing

`src/libraries/L2Block.sol:16-20` falls back to `block.number` when the ArbSys staticcall fails.
`PimdHook.sol:257` stores `initBlock` from whichever source answered at initialization, and `:273` and
`:329` compare against whichever answers later. On Orbit the two are different magnitudes (L2 block
count vs L1 block count), so a single intermittent ArbSys failure makes `InitBlockSwap` (:273) a no-op,
or makes the block half of the launch cap (:329) permanently satisfied or permanently expired. Only the
`launchCapSeconds` time bound is actually load-bearing — which is worth saying out loud, because
:66-67 claims the opposite ("if the ArbSys precompile ever stopped answering, the block test alone would
keep the cap on forever"); `LAUNCH_CAP_MAX_SECONDS` is what is supposed to prevent that, and per F-13 it
cannot.

---

## F-15 INFO — "liquidity can never leave" is about principal, not fees

`src/pimd/PimdHook.sol:369-381`. Refusing every negative `liquidityDelta` locks the principal. The
`liquidityDelta == 0` allowance is exactly a fee collection, and at a 1.25% LP fee tier on a single
near-full-range position the accrued fees are a large and growing claim in **both** IMD and PIMD, held
by whoever made the seed. The hook neither limits nor directs them. That is deliberate — the launch
policy sends them to buy-and-burn — but the guarantee a reader takes from :49-50 is stronger than what
the code provides, and the recipient is a third-party contract outside this tree.

---

## F-16 INFO — a derived hook can open a look-alike pool

`src/pimd/PimdHook.sol:116-133`. `engine()`, `team()`, `quoteToken()` and `launchFactory()` are
`public virtual`, so a subclass can redirect all four. It is a different address and therefore a
different hook and a different pool, so the production pool is unaffected — but a clone can open
PIMD/IMD at another fee tier, tax identically, and pay its own team wallet, while presenting source that
differs from the real hook in four one-line getters. Combined with audit finding 16 (an untaxed hookless
pool is already possible), the practical point is that "which pool is the real one" is a front-end and
explorer question, not something the contracts settle.

For the production path the constant-plus-virtual-getter pattern is otherwise **sound**: the getters
resolve internally in the concrete contract (no external call, so no extra gas, no reentrancy surface
and no way for a third party to change what they return), the constructor's
`Hooks.validateHookPermissions` still binds the hook's address bits to the declared permission set, and
`beforeInitialize` reads `quoteToken()`/`launchFactory()` before latching anything. The weakness of the
pattern is not the `virtual` — it is that none of the four constants is verified against on-chain
reality at launch time (F-05).

---

## F-17 INFO — deploy-time wiring

`script/DeployPimd.s.sol:37-52` lets `POOL_MANAGER`, `IMD`, `MIN_BALANCE`, `MIN_INTERVAL`, `FIRE_TIP`,
`TIP_PER_HOLDER` and `DRIP_BPS` be overridden by environment variables with no cross-check against the
hook's `QUOTE_TOKEN` constant (`PimdHook.sol:96`, currently equal to the script's `ROBINHOOD_IMD`). A
mismatched `IMD` produces an engine that can never bind — `PimdEngine.sol:194` catches it, which is the
good case. `PimdEngine`'s constructor (:159-175) validates `dripBpsPerPeriod` and `maxCatchup` but
**not** `minInterval` (0 is accepted) and **not** `minBalance` (0 is accepted, which would let every
dust address register and makes F-02 trivial).

`binder` defaults to `team`, a single EOA (`0x0960E8Bd80462e3842Bb6620c7C5289A44c4559B`, the same
address as the hook's `TEAM_WALLET`). If that key is lost or compromised before `bind`, the engine can
never be bound: `register` and `fire` revert `NotBound` forever, while `flushHolders()` is
permissionless and **not** gated on the engine being bound, so every holder slice keeps being pushed
into a contract that can never pay it out. A compromised binder, conversely, gets one irreversible shot
at the token address, the hook address and an arbitrary blacklist (F-06, F-07).

---

# Checked and found genuinely safe

These were attacked specifically and did not yield. Listed so the absence of a finding is informative.

## `beforeRemoveLiquidity` — the whole safety case

I could not find any path that removes liquidity.

* **int256 / int128 sign confusion.** `params.liquidityDelta` is `int256` in the hook's check
  (`PimdHook.sol:379`) and `int128` in core. This is the classic place for a bypass and it is **not**
  exploitable here: `PoolManager.modifyLiquidity` calls `params.liquidityDelta.toInt128()`, and
  `SafeCast.toInt128(int256)` reverts `SafeCastOverflow` unless `int128(x) == x`. So no value is
  negative to core and non-negative to the hook, or vice versa.
* **Routing confirmed.** `Hooks.beforeModifyLiquidity` sends `liquidityDelta > 0` to
  `beforeAddLiquidity` and `liquidityDelta <= 0` to `beforeRemoveLiquidity`. A zero delta therefore
  cannot consume the single `seeded` slot, and a negative delta cannot reach `beforeAddLiquidity`.
* **The `liquidityDelta == 0` allowance cannot be abused by a stranger.** Positions are keyed by
  `(msg.sender, tickLower, tickUpper, salt)`, and `Position.update` reverts
  `CannotUpdateEmptyPosition` when `liquidityDelta == 0` and the position's liquidity is 0. Only the
  address that made the seed has a non-empty position, so only it can poke, and a poke returns fees,
  never principal.
* **`donate`.** Permissionless on this pool (`beforeDonate`/`afterDonate` flags are false, so the
  reverting stubs at :394-400 are never reached) but donate only *adds* currency as fees to in-range
  liquidity. Not a withdrawal vector.
* **`take`.** Not theft: `PoolManager.unlock` reverts unless `NonzeroDeltaCount.read() == 0` at the end,
  so every `take` must be settled.
* **ERC-6909 claims.** The hook's claims cannot be moved by anyone else. The hook never calls `approve`
  or `setOperator`, and `ERC6909Claims._burnFrom` requires `from == msg.sender` or an operator /
  allowance. `quoteId == uint256(uint160(IMD))` matches `CurrencyLibrary.toId()`, so `mint`, `burn`,
  `take` and `balanceOf` all address the same id.
* **`noSelfCall`.** It is real and it does skip `beforeInitialize`, `beforeAddLiquidity`,
  `beforeRemoveLiquidity`, `beforeDonate` and `afterDonate` when `msg.sender == address(hook)`
  (`Hooks.sol:171-175`), i.e. a hook that calls `modifyLiquidity` itself bypasses its own lock.
  **It is unreachable here**: the hook's only outbound PoolManager calls are `mint` (:282, :320),
  `unlock` (:414, :438), `balanceOf` (:479), `burn` (:506) and `take` (:507). There is no
  `modifyLiquidity`, `swap`, `initialize` or `donate` call, no owner, no arbitrary-call entry point and
  no `delegatecall` anywhere in the contract that could add one. Even if it were reachable, the hook
  holds no position of its own, so it could only drain a position owned by `address(hook)`, which has
  zero liquidity. This is the single most important thing to re-check on any future change to the hook.
* **Reentrancy during the hook's own unlock.** If IMD ever had a transfer callback, the engine or the
  tip recipient would get a window where the PoolManager is unlocked. Even then: `modifyLiquidity` with
  a negative delta still hits `beforeRemoveLiquidity`; any swap or take they do must still settle;
  `flush`/`flushHolders` are blocked by `nonReentrant` (:185-190); and `engine.fire/tally/pay` are
  blocked by `_requireLocked()`, which is the guard working as designed.

## `unlockCallback` cannot be driven by anyone else

`PoolManager.unlock` calls `IUnlockCallback(msg.sender).unlockCallback(data)`, so the only way the
PoolManager calls `hook.unlockCallback` is if the hook itself called `unlock`. `onlyPoolManager` (:446)
plus the transient `_UNLOCK_SLOT` check (:447) is therefore belt-and-braces, and the transient flag is
also correct across reverts — EIP-1153 `tstore` is reverted with the frame, so the engine's
`try hook.flush() {} catch {}` cannot leave the slot armed for a later call in the same transaction.
Nested unlocks are impossible (`unlock` reverts `AlreadyUnlocked`). `ACTION_FLUSH = 2` and
`ACTION_HOLDERS = 4` are the only accepted actions; anything else reverts `HookNotImplemented` (:465).

## `beforeInitialize` cannot be bypassed, and the quote is now properly pinned

`PoolManager.initialize` always calls it (the permission bit is in the hook's address and
`isValidHookAddress` is enforced), `sender` is the true `msg.sender`, and `AlreadyLaunched` (:228) makes
the launch genuinely one-shot. Because no second pool can exist on this hook, the swap and liquidity
callbacks not re-checking `key` against `_key` is sound, and `quote`/`quoteId` cannot be repointed.

Audit finding 2 is **properly fixed**: :246 now requires `c0 == quoteToken()`, a strictly stronger check
than the engine-derived one the prior report suggested, and :243 still pins `c1 == token`. A stranger
calling `PoolManager.initialize` directly is refused and `launched` stays false, so the real launch is
not denied by that route. (The remaining hop is F-04.)

## `beforeAddLiquidity` cannot be replayed or reentered

`seeded` is written before the hook returns (:354), the function makes no external call, and a reverting
add reverts the flag with it. A positive `int256` liquidityDelta too large for `int128` sets `seeded` and
then reverts in `toInt128`, which rolls the flag back. Audit finding 3 is fixed **against a direct
PoolManager caller**; see F-04 for the hop that remains.

## Fee accounting is exact

`claimBalance()` really does equal `holdersOwed + teamOwed`. The specified and unspecified branches are
mutually exclusive (`(amountSpecified < 0) == zeroForOne` at :277 versus `!=` at :315); `_FEE_SLOT` is
zeroed in `beforeSwap` on the unspecified path (:287) so the overwrite at :319 cannot double-count; and
`_split` (:495-501) assigns `fee - toHolders` to the team so floor division strands nothing.

The partial-fill fix (audit finding 4) is arithmetically correct for both specified cases:
`wanted = specified - fee` for exact-input and `specified + fee` for exact-output, which is exactly
`amountToSwap` after `Hooks.beforeSwap` applies `hookDeltaSpecified`, so a full fill always matches and
anything short reverts `PartialFill`. The launch-cap `spent` (:333) reconstructs the gross IMD correctly
in both buy cases. No reentrancy is possible during a swap: the PoolManager moves no tokens there, only
deltas.

## Engine phase machine, apart from F-01

`prune` is correctly refused during `Pay` (:249), where a swap-and-pop would misallocate a frozen
weight. `register` during `Tally` or `Pay` is harmless: it only appends, so no existing index moves and
`epochCount` bounds the loops. `pay`'s denominators are frozen on `epochQuote` and `totalWeight`
(:357-358), so a holder's share does not depend on its page or on an earlier failed payout, and the
leftover reconciliation (:387-388) returns both the floor-division dust and any refused holder's share
to the pot. `_requireLocked()` is present on `fire` (:270), `tally` (:309) and `pay` (:351), and the slot
constant `0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23` is the correct
`bytes32(uint256(keccak256("Unlocked")) - 1)`.

## `PimdToken`

No owner, no mint, no burn, no hooks, no access control to attack. Audit finding 15 is correctly fixed:
`totalBurned()` (:40-42) and `circulatingSupply()` (:46-48) now both count `balanceOf[address(0)]`, and
`INITIAL_SUPPLY == totalSupply` invariantly, so `circulatingSupply` cannot underflow.

## Audit finding 12

`_INSWAP_SLOT` is correctly and completely removed — no declaration and no reads remain, so there is no
longer an untaxed-swap branch waiting to be armed.

## Audit finding 9

Substantively fixed: `bind` now verifies `hook.engine()`, `hook.quote()` and `hook.poolManager()`
(:192-195), and the `quote` check doubles as a "pool is open" requirement. See F-06 for what is left.

---

# Verdict on the prior report's fixes

| Prior finding | Status at `e9d2da4` |
|---|---|
| 1 High — paged tally double-counts | Fixed as stated (`tally` is atomic, :311), but the fix **introduced F-01 and F-02**, both worse than the original. Net regression. |
| 2 Med — currency0 not checked against IMD | **Correctly fixed** (PimdHook.sol:246), stronger than suggested. |
| 3 Med — seed front-run | Fixed against a direct PoolManager caller (PimdHook.sol:352); **not** fixed against a caller routing through the factory (F-04). |
| 4 Med — tax on unfilled amount | **Correctly fixed** (PartialFill, PimdHook.sol:307-312); maths verified against `Hooks.beforeSwap`. |
| 5 Low — flush all-or-nothing | Partially fixed: `flushHolders()` added, but `fire()` still uses `flush()` (F-08). |
| 6 Low — empty catch hides flush failures | **Not fixed** (PimdEngine.sol:274). |
| 7 Low — non-V4 flash lenders | Not fixed (by design). Slightly cheaper to use now that `tally` is one call. |
| 8 Low — sell-and-rebuy keeps the streak | Resolved in documentation (commit `b655c80`), code unchanged. Correct resolution. |
| 9 Low — bind does not verify the hook | **Correctly fixed** (PimdEngine.sol:192-195), except `token_` (F-06). |
| 10 Low — register bloat | **Not fixed**, and now escalated: it is the enabler for F-02 and, via F-03, costs no capital at all. |
| 11 Low — fireTip for a no-op epoch | **Not fixed** (F-10). |
| 12 Info — dead `_INSWAP_SLOT` | **Correctly fixed** (removed). |
| 13 Info — dead `LAUNCH_CAP_MAX_SECONDS` | **Not fixed** (F-13), and F-14 makes it load-bearing. |
| 14 Info — stale README / NatSpec | Hook NatSpec updated (commit `e8a2a03`); not re-checked here. |
| 15 Info — `totalBurned` ignores `address(0)` | **Correctly fixed** (PimdToken.sol:41, 47). |
| 16 Info — untaxed second pool | Design limitation, unchanged. |
