# 06 — Where the tests lie, and where launch day goes wrong

Auditor pass over the test suite and the deploy path. Local HEAD `b655c80`, working tree clean.
Foundry **1.8.3** (`cae51ad`), solc 0.8.26. Suite as committed: **46 local + 6 fork = 52**, all green.

Everything below that is marked **PROVEN** was established by running code in this session: either a
purpose-written probe test, or a *mutation test* (delete the defence, re-run its own tests, see whether
they notice). All mutations were reverted; `git diff --stat` is empty and the suite is back to 46/46 with
byte-identical gas numbers.

> Three untracked scratch files exist in `test/pimd/` (`ZZScratch2.t.sol`,
> `ZZScratchAccessControl.t.sol`, `ZzAuditLifecycle.t.sol`, all written 06:51–06:54 today, none in
> `git ls-files`). They are another pass's working files. They are **not** part of the 52 and nothing here
> depends on them. Decide before launch whether they are committed or deleted — right now
> `forge test` with no `--match-path` compiles and runs them, so "the suite" means different things
> depending on who runs it.

---

## 0. The headline

Four of the five defences the brief called "unreviewed" are genuinely covered — mutation testing kills
the tests when the code is removed. **The fifth is not covered at all.** And two things the suite says
nothing about will cost you the launch.

| # | Finding | Severity | Evidence |
|---|---|---|---|
| A1 | `beforeAddLiquidity` **and** `beforeRemoveLiquidity` can be deleted in their entirety and all five liquidity tests still pass | **CRITICAL (false green)** | PROVEN, mutation |
| A2 | One permissionless `prune()` during `Tally` bricks the engine **permanently**. Zero tests touch `prune` | **CRITICAL (contract bug, zero coverage)** | PROVEN, probe |
| A3 | `tally` costs **33,622 gas/holder** and must be whole; ~950 holders is a hard, unremediable ceiling | **HIGH** | PROVEN, measured |
| B1 | The live engine's frozen `maxCatchup` is **1 hour**; every test asserts 6-hour behaviour | **HIGH** | PROVEN, on-chain |
| B2 | `deployments.pimd.4663.json` is stale and wrong in five fields, incl. a `startTick` the hook now rejects | **HIGH (launch-day footgun)** | PROVEN, on-chain |
| B3 | `bytecode_hash="none"` does **not** remove the solc version tag from the deployed bytes | MEDIUM | PROVEN, artifact |
| A4 | The real hook constants (`TEAM_WALLET`, `ENGINE_ADDRESS`, `QUOTE_TOKEN`, `LAUNCH_FACTORY`) are never read by any test | MEDIUM–HIGH | code |
| — | Launch-factory sender pinning: **substantially de-risked** by on-chain bytecode evidence | *good news* | PROVEN, on-chain |

---

# PART A — WHERE THE TESTS LIE

## A.0 Mutation-test results: which defences are actually covered

I deleted each defence and re-ran the tests that claim to cover it.

| Defence | Site | Mutation | Tests noticed? |
|---|---|---|---|
| `beforeInitialize` factory pin | `PimdHook.sol:231` | `sender;` | **YES** — `test_only_the_launch_factory_may_open_the_pool` fails |
| `beforeInitialize` quote pin | `PimdHook.sol:246` | check removed | **YES** — `test_initialize_refuses_a_quote_that_is_not_imd` fails |
| `_SPEC_SLOT` partial-fill refusal | `PimdHook.sol:311` | check removed | **YES** — `test_a_partially_filled_buy_is_refused_rather_than_overtaxed` fails |
| Atomic (whole-set) tally | `PimdEngine.sol:311` | reverted to paged | **YES** — both tally tests fail |
| Flash-borrow unlock guard | `PimdEngine.sol:461` | `_requireLocked` gutted | **YES** — all 3 unlock tests fail |
| Rogue-pool probe | `PimdEngine.sol:510–513` | `_isPool` → `false` | **YES** — `test_a_pool_like_contract_is_not_paid` fails |
| **`beforeAddLiquidity` factory pin** | `PimdHook.sol:352` | `sender;` | **NO** |
| **`beforeAddLiquidity` one-shot seed** | `PimdHook.sol:353` | guard removed | **NO** |
| **`beforeRemoveLiquidity` liquidity lock** | `PimdHook.sol:379` | guard removed | **NO** |
| **`tx.origin` keying of the launch cap** | `PimdHook.sol:334,336` | → `msg.sender` | **NO** |

Transcript of the damning run — hook gutted at lines 352, 353 and 379 simultaneously:

```
[PASS] test_a_second_liquidity_add_is_refused()      (gas: 143441)
[PASS] test_a_stranger_cannot_squat_the_seed()       (gas: 16970886)
[PASS] test_fee_collection_is_still_allowed()        (gas: 649552)
[PASS] test_liquidity_can_never_be_removed()         (gas: 85645)
[PASS] test_third_party_liquidity_is_blocked()       (gas: 1687309)
Suite result: ok. 5 passed; 0 failed
```

### A1 (CRITICAL). The liquidity lock — "the entire safety case for a third party holding the LP position" — has no coverage whatsoever

Five tests, five green, zero signal. Here is why each one lies.

**`test_third_party_liquidity_is_blocked`** — `Pimd.t.sol:255-266`
Mints and approves **IMD** to `lp` (`:258-259`) but never approves **PIMD**. The add is at
`[TICK_LOWER, START_TICK]` with spot *at* `START_TICK`, so the position is 100% currency1 (PIMD).
`PoolModifyLiquidityTest.unlockCallback` settles with `currency1.settle(manager, data.sender, …)` →
`transferFrom(PimdTest, manager, …)` → **reverts on allowance**. The bare `vm.expectRevert()` at `:260`
swallows that just as happily as it swallows `NotLaunchFactory`.

**`test_a_stranger_cannot_squat_the_seed`** — `Pimd.t.sol:392-405`
`liquidityDelta: 1` over `[82980, 129000]` at spot `129000` owes ≈568 wei of PIMD, so the same missing
approval reverts the call. Because the revert happens *inside* the unlock, the `seeded = true` write is
rolled back, so `assertFalse(fresh.seeded())` at `:404` also passes. Both assertions survive deletion.

**`test_a_second_liquidity_add_is_refused`** — `Pimd.t.sol:407-414`
Two independent failures:
1. Same missing-PIMD-approval escape as above.
2. **It is pointed at the wrong check.** `beforeAddLiquidity` tests `sender != launchFactory()`
   (`:352`) *before* `seeded` (`:353`). The caller here is `lpRouter`, so the revert is
   `NotLaunchFactory`. The one-shot seed guard at `:353` is reachable **only** by a second positive add
   *from the factory*, and **no test in the repo makes one.** `test_fee_collection_is_still_allowed`
   (`:431`) looks like it does, but `liquidityDelta == 0` routes to `beforeRemoveLiquidity`, not
   `beforeAddLiquidity` — confirmed in `lib/.../v4-core/src/libraries/Hooks.sol`:
   ```solidity
   if (params.liquidityDelta > 0  && hasPermission(BEFORE_ADD_LIQUIDITY_FLAG))    → beforeAddLiquidity
   else if (params.liquidityDelta <= 0 && hasPermission(BEFORE_REMOVE_LIQUIDITY_FLAG)) → beforeRemoveLiquidity
   ```

**`test_liquidity_can_never_be_removed`** — `Pimd.t.sol:417-424`
Calls `lpRouter.modifyLiquidity(key, …, liquidityDelta: -1, …)`. `lpRouter` **does not own the
position** — the factory does (`PimdBase.t.sol:240`). So `Pool.modifyLiquidity` →
`Position.update(-1)` → `LiquidityMath.addDelta(0, -1)` → underflow revert, with or without the hook.
*The only caller that could ever actually withdraw is the position owner, and no test attempts it.*
This is the test the entire "it is safe to let the launch factory hold the LP" argument rests on.

**`test_fee_collection_is_still_allowed`** — `Pimd.t.sol:428-432`
**Zero assertions.** It calls `factory.seed(key, …, 0)` and checks nothing. It would pass if the
collected fee were zero, negative-delta'd, or paid to the wrong address.

**Fixes, concretely:**
```solidity
// 1. the lock, from the only caller that could break it
function test_the_position_owner_cannot_withdraw() public {
    vm.expectRevert(_wrapped(IHooks.beforeRemoveLiquidity.selector, PimdHook.LiquidityIsLocked.selector));
    factory.seed(key, TICK_LOWER, START_TICK, 0, /*negative=*/ -1e18);  // needs a signed overload on the mock
}
// 2. the one-shot seed, from the factory
function test_the_factory_gets_exactly_one_add() public {
    vm.expectRevert(_wrapped(IHooks.beforeAddLiquidity.selector, PimdHook.LiquidityIsLocked.selector));
    factory.seed(key, TICK_LOWER, START_TICK, 1e18);
}
// 3. third-party add: approve BOTH tokens first, so the revert can only come from the hook
function test_third_party_add_is_refused_for_the_right_reason() public {
    token.approve(address(lpRouter), type(uint256).max);   // <-- the missing line
    imd.approve(address(lpRouter), type(uint256).max);
    vm.expectRevert(_wrapped(IHooks.beforeAddLiquidity.selector, PimdHook.NotLaunchFactory.selector));
    lpRouter.modifyLiquidity(key, ModifyLiquidityParams(TICK_LOWER, START_TICK, 1e18, 0), "");
}
// 4. fee collection actually collects
function test_fee_collection_pays_the_position_owner() public {
    _pastLaunchCap(); _buy(alice, 100e18); _sell(alice, token.balanceOf(alice)/2);
    uint256 b = imd.balanceOf(address(factory));
    factory.seed(key, TICK_LOWER, START_TICK, 0);
    assertGt(imd.balanceOf(address(factory)) - b, 0, "the pool's own 1.25% reached the owner");
}
```

Hook reverts come back wrapped, which is why the suite reaches for bare `expectRevert`. The helper you
need (verified against `v4-core/src/libraries/Hooks.sol::callHook` and `CustomRevert.sol:11,83`):

```solidity
function _wrapped(bytes4 hookFn, bytes4 inner) internal view returns (bytes memory) {
    return abi.encodeWithSelector(
        CustomRevert.WrappedError.selector,
        address(hook), hookFn,
        abi.encodeWithSelector(inner),                       // add args for PartialFill/UnsupportedFeeTier
        abi.encodeWithSelector(Hooks.HookCallFailed.selector)
    );
}
```

### A4 (MEDIUM–HIGH). The harness overrides mean the production constants are never executed

`PimdBase.t.sol:92-122` defines `PimdHookHarness`, overriding `engine()`, `team()`, `quoteToken()` and
`launchFactory()`. Every local test and **every fork test** (`PimdFork.t.sol:108-109`) deploys the
harness. `PimdHook` itself is never deployed at a hook-flagged address anywhere in the repo.

Exactly what is therefore untested, and what breaks while all 52 stay green:

| Constant | Site | On-chain value | Wrong ⇒ | Caught when? |
|---|---|---|---|---|
| `ENGINE_ADDRESS` | `PimdHook.sol:93` | `0x92A9ABEB…` — **verified deployed**, `bound()==false` | `flush()` sends real IMD to a dead address forever; holders never get paid | `bind` reverts `BadConfig` — **after the paid launch**, and the hook is immutable |
| `TEAM_WALLET` | `:91` | `0x0960E8Bd…` | 25% of every trade's tax to a wrong address, forever | **never** — nothing on chain or in the suite objects |
| `QUOTE_TOKEN` | `:96` | `0x5F7Bb593…` | `beforeInitialize` reverts `WrongQuoteCurrency` | at launch — paid launch burned |
| `LAUNCH_FACTORY` | `:100` | `0xA25B02A1…` — **verified, 17.3 KB of code** | `beforeInitialize` reverts `NotLaunchFactory` | at launch — paid launch burned |

`TEAM_WALLET` is the dangerous one: it is the only constant with **no failure mode that reverts**. A
transposed character silently redirects the team's entire revenue stream and nothing anywhere notices.

Also never executed: the real `PimdHook` constructor's
`Hooks.validateHookPermissions(this, getHookPermissions())` (`:198`) at a real mined address. The flag
arithmetic is right — `BEFORE_INITIALIZE(0x2000) + AFTER_INITIALIZE(0x1000) + BEFORE_ADD_LIQ(0x800) +
BEFORE_REMOVE_LIQ(0x200) + BEFORE_SWAP(0x80) + AFTER_SWAP(0x40) + BEFORE_SWAP_DELTA(0x8) +
AFTER_SWAP_DELTA(0x4) = **0x3ACC** ✓` — but the harness has four extra immutables and a six-argument
constructor, so the **creation code the factory will mine against is a different artifact from the one
`HookMiner` is pointed at in every test** (`PimdBase.t.sol:210`, `Pimd.t.sol:458`,
`PimdFork.t.sol:108`).

Two cheap tests that close the whole row:

```solidity
// put the real constants under assertion, without a harness
function test_the_compiled_constants_are_the_intended_addresses() public {
    PimdHook real = _deployRealHookAtMinedAddress();         // PimdHook, 2 ctor args, flags 0x3ACC
    assertEq(real.team(),          0x0960E8Bd80462e3842Bb6620c7C5289A44c4559B);
    assertEq(real.engine(),        0x92A9ABEB52031D529AB1ae3638CA073fa12Be01d);
    assertEq(real.quoteToken(),    0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127);
    assertEq(real.launchFactory(), 0xA25B02A1e93903b790E6aaf7dA1b8B8d50294645);
    assertEq(uint160(address(real)) & 0x3FFF, 0x3ACC, "permission bits");
}
// and cross-check the deploy script against the hook, in one assertion each
function test_script_and_hook_agree() public {
    assertEq(DeployPimd.DEFAULT_TEAM,           real.team());
    assertEq(DeployPimd.ROBINHOOD_IMD,          real.quoteToken());
    assertEq(DeployPimd.ROBINHOOD_POOL_MANAGER, address(real.poolManager()));
}
```
(Today `DEFAULT_TEAM`/`ROBINHOOD_IMD`/`ROBINHOOD_POOL_MANAGER` in `DeployPimd.s.sol:19-25` do match the
hook character for character — I checked by hand. Nothing in the repo would notice if they stopped.)

### A5 (GOOD NEWS, partly). `MockLaunchFactory` vs the real launch factory

`MockLaunchFactory` (`PimdBase.t.sol:39-86`) calls `manager.initialize` from its own address
(`:47`), then `manager.unlock` → `manager.modifyLiquidity` → `sync`/`transfer`/`settle`/`take`
(`:51-83`), all from that same address. If the real factory initialises through one address and adds
liquidity through another — or through v4-periphery's `PositionManager`, which is how almost every pad
mints an LP position — then `beforeInitialize`'s pin (`:231`) or `beforeAddLiquidity`'s pin (`:352`)
sees the periphery contract instead of the factory and **reverts the real launch.** Both pins read a
single `LAUNCH_FACTORY` constant, so they cannot even be different addresses.

**I went and looked.** Runtime bytecode of `0xA25B02A1e93903b790E6aaf7dA1b8B8d50294645` on chain 4663
(17,320 bytes), grepped for literal selectors:

| Selector | Function | Present |
|---|---|---|
| `0x6276cbbe` | `IPoolManager.initialize(PoolKey,uint160)` | **yes** |
| `0x5a6bcfda` | `IPoolManager.modifyLiquidity(PoolKey,ModifyLiquidityParams,bytes)` | **yes** |
| `0x48c89491` | `IPoolManager.unlock(bytes)` | **yes** |
| `0x91dd7346` | `unlockCallback(bytes)` | **yes** (it *is* the callback recipient) |
| `0xa5841194` / `0x11da60b4` / `0x0b0d9c09` | `sync` / `settle` / `take` | **yes** |
| `0xdd46508f` | `PositionManager.modifyLiquidities(bytes,uint256)` | **no** |
| `0xf3cd914c` | `IPoolManager.swap(...)` | **no** |
| `0x234266d7` | `IPoolManager.donate(...)` | **no** |
| `8366a39c…40951` | the PoolManager address, embedded as a literal | **yes** |
| `5f7bb593…b7127` | IMD, embedded as a literal | **no** — the quote is a parameter |

So the real factory drives the PoolManager **directly, from its own address, inside its own unlock** —
architecturally the same shape as the mock, and it holds the position itself rather than via an NFT.
`swap` is absent, so the factory does not make a first buy in the launch transaction and will not trip
`InitBlockSwap` (`PimdHook.sol:273`). **The launch-blocking sender-pinning risk is substantially
retired.** Downgrade it from blocker to "confirm by trace".

Three questions this evidence does **not** settle, and exactly what settles them:

1. **How many `modifyLiquidity` adds does one launch make?** Two adds and the second hits
   `LiquidityIsLocked` (`:353`) and the launch dies.
   → `cast run <txhash>` on any prior launch by this factory and count the `modifyLiquidity` frames.
2. **Does any factory code path call `modifyLiquidity` with a *negative* delta?** A "finalise", "refund"
   or "burn position" step would hit `beforeRemoveLiquidity` (`:379`) and revert **forever** — not just
   at launch, but for the whole life of the pool. Selector presence cannot distinguish sign.
   → decompile `0xA25B02A1…`, or trace a prior launch through to the end of its lifecycle.
3. **Does the factory mine the token salt so the token sorts *above* IMD?** `beforeInitialize` requires
   `currency1 == token` and `currency0 == IMD` (`:243,246`). IMD is not baked into the factory, so the
   pairing is caller-supplied and the hook is the only guard.
   → confirm with the pad operator, and read a prior launch's pool key.

The decisive test, which does not exist: **drive the launch through the real factory on a fork.**
```
forge test --fork-url robinhood --match-test test_fork_launch_through_the_real_factory
```
calling the factory's actual launch entrypoint at `0xA25B02A1…` with the real `PimdHook` (not the
harness). That one test replaces every assumption in this section.

### A6. `PimdFork.t.sol` never executes the real `L2Block` path

`PimdFork.t.sol:136-138` mocks ArbSys (`vm.mockCall(address(100), "arbBlockNumber()", …)`) and `_buy`
(`:151`) calls it before every swap. So the real staticcall in
`L2Block.sol:17` is only ever reached once — in `setUp` at `factory.open` (`:120`) — and **on a fork it
fails there**, because `address(100)` on this chain stores the single byte `0xfe` (verified:
`cast code 0x…064` → `0xfe`). Foundry copies that byte and executes it; `INVALID` burns the forwarded
gas and reverts, so `L2Block.number()` silently returns `block.number`.

Measured on chain 4663 right now:

| | value |
|---|---|
| `ArbSys.arbBlockNumber()` | 83,089,587 |
| `l1BlockNumber` (what Solidity's `block.number` returns on Nitro) | 26,145,766 |
| gap | **≈ 57 million** |
| gas for a bare `arbBlockNumber()` call | 22,033 total − 21,000 base ≈ **1,000** |
| `ARBSYS_GAS` budget | 20,000 (`L2Block.sol:14`) — **20× headroom** |
| ArbOS version | **116** — far past ArbOS 32, so Cancun / EIP-1153 `TSTORE`/`TLOAD` are available ✓ |

So the gas cap will not bite in practice, and `evm_version = "cancun"` is safe on this chain. But the
*semantics* of a fallback are never exercised, and one direction is fail-**dangerous**:

- **ArbSys fails at init, answers later.** `initBlock ≈ 26.1M` (an L1 number); afterwards
  `L2Block.number() ≈ 83.1M`. Then at `PimdHook.sol:329`,
  `83.1M < 26.1M + 6000` is **false from the very first swap** → the 25-IMD-per-origin launch cap is
  **silently off for the entire launch window**, and `L2Block.number() == initBlock` (`:273`) is also
  false → the same-L2-block snipe guard is off too. One wallet takes the whole opening range. No revert,
  no event, nothing in the suite.
- **ArbSys answers at init, fails later.** `initBlock ≈ 83.1M`; afterwards `26.1M < 83.1M + 6000` is
  **true forever** → the block arm of the window never closes. Saved only because the two time arms
  (`:330-331`) are AND-ed, so the cap still expires at 600 s. Fail-open holds here.

This is *exactly* the branch the fork test runs and then papers over with a mock. Minimum fix — one
assertion in `PimdFork.t.sol::setUp`, plus one honest local test:

```solidity
// fork: prove which path ran, and that it produced an L2-shaped number
assertGt(hook.initBlock(), block.number, "initBlock must be the ArbSys L2 number, not block.number");
// local: etch a reverting ArbSys and assert the fallback is the *safe* direction
function test_arbsys_failure_does_not_silently_disarm_the_launch_cap() public {
    vm.etch(address(100), hex"fe");           // the real on-chain shape: INVALID
    assertTrue(hook.inLaunchCapWindow(), "a dead precompile must not open the floodgates");
}
```
Consider making the direction explicit in the contract: record a `bool initBlockIsL2` alongside
`initBlock` and treat a mismatch as "cap still on" rather than "cap off".

## A7. `PimdAttacks.t.sol`, test by test: does it prove its comment?

| Test | Line | Claim | Verdict |
|---|---|---|---|
| `test_fire_refuses_while_the_pool_is_unlocked` | `:38` | the flash-borrow weight attack is closed | **Proves the guard, not the attack.** Mutation-killed ✓, so the guard is covered. But `Unlocker` (`:10-31`) never *borrows* anything — it calls no `manager.take`. The test shows "`fire` reverts inside an unlock", never that a borrowed balance would otherwise be weighed, and never that the attack was profitable. `vm.expectRevert()` at `:45` is unpinned → any revert satisfies it. |
| `test_tally_refuses_while_the_pool_is_unlocked` | `:49` | same | Same. Does carry a real positive assertion (`:65`, phase reaches `Pay`). Unpinned revert at `:59`. |
| `test_pay_refuses_while_the_pool_is_unlocked` | `:68` | same | Same. Positive assertion at `:84`. Unpinned revert at `:79`. |
| `test_one_refused_holder_does_not_stop_the_others` | `:90` | a refused address is skipped, its share returns to the pot, the epoch finishes | **Partly, and two assertions are dead weight.** `assertEq(phase, Idle)` (`:109`) — "the epoch still finished" — is near-tautological: `_runEpoch` (`PimdBase.t.sol:352-363`) only advances while the phases line up, and `Idle` is *also* the state `tally` leaves behind when `tw == 0` and it hands the quote back (`PimdEngine.sol:337-340`). It is the alice/carol assertions at `:106-107` that carry the test, not this one. `assertLt(totalDripped, potBefore)` (`:112`) **proves nothing** — one epoch releases ~15% of the pot, so it holds whether or not bob was paid. The genuinely good line is `:111` (`balanceOf(engine) == pot()`). **Missing:** that bob's *exact* share came back; that `PayoutFailed(bob, amt)` was emitted; the other two `_send` branches at `PimdEngine.sol:489` (an IMD returning `false`, and an IMD that *burns gas* rather than reverting — `vm.mockCallRevert` costs nothing, so `SEND_GAS = 60_000` is never stressed and the griefing vector is unexplored). |
| `test_many_holders_weigh_whole_and_pay_across_pages` | `:116` | tally is whole, pay is paged | **Yes — the best test in the file.** Selector *and* argument pinned (`:131`). Mutation-killed ✓. Minor gap: never checks that payouts sum to the epoch quote. |
| `test_one_bag_cannot_be_weighed_twice_across_wallets` | `:152` | one bag earns one share however many wallets | **Passes, but for a weaker reason than it claims.** Mutation-killed ✓ so the atomic-tally guard is covered. But the arithmetic at `:190-195` holds simply because bob's balance is **zero at tally time** — nothing here demonstrates the pre-fix attack, and the structurally identical residual attack (register → `prune` during `Tally`) is untested and is finding **A2** below. |
| `test_a_pool_like_contract_is_not_paid` | `:199` | `_isPool` keeps rogue pools off the drip | **Yes.** Mutation-killed ✓ (fails with `2254758179315160297 != 0`). Gaps: never asserts the pair failed to *register* (`holderCount()` is not checked); `FakePair` (`:295-303`) is a trivially honest responder, so the stated reason for the gas cap — `PROBE_GAS` at `PimdEngine.sol:520`, "a hostile holder contract must not be able to stall an epoch" — is **never exercised**. No test uses a `token0()` that burns gas, reverts, or returns short data (the `returndatasize() > 31` guard at `:521`). |
| `test_dust_holder_is_skipped_and_prunable` | `:217` | dust is skipped **and prunable** | **Half the name is a lie.** The test never calls `prune`. `prune` has **zero coverage in the entire repo** — see A2, where that absence turns out to hide a permanent brick. |
| `test_a_long_gap_still_releases_only_a_slice` | `:233` | the catch-up clamp stops a gap becoming a payday | **Good test, wrong configuration.** Numerically honest (`:248-250`), and the comment at `:245-246` spells out the maths. But it says "the clamp is set to 6 hours at deploy" and **the deployed engine's clamp is 1 hour** — `cast call 0x92A9ABEB… "maxCatchup()"` → `3600`. See B1. |
| `test_a_stranger_can_deploy_it_and_hold_nothing` | `:257` | no owner; one-shot power belongs to the named binder | **Yes.** Both reverts selector-pinned (`:277`, `:282`) — the only properly pinned reverts in the file. Gap: only the `h.engine() != address(this)` branch of `bind` is covered; `h.quote() != imd` (`PimdEngine.sol:194`) and `h.poolManager() != poolManager` (`:195`) are untested, and those are the checks guarding a one-shot. |
| `test_team_is_excluded_from_drips` | `:288` | the team does not farm the pot | **Mirror assertion.** It re-reads the three values `bind` wrote eleven lines earlier (`PimdEngine.sol:201`). It never shows exclusion has an *effect* — no excluded address is given a bag and run through an epoch. Pairs with `test_an_excluded_holder_is_never_registered_or_paid` (`Pimd.t.sol:373`), whose name also promises "or paid" and which likewise never pays anything. |

## A8. Assertions that survive deleting the feature

Ranked by how badly they mislead.

1. **`Pimd.t.sol:186`** — `assertEq(token.balanceOf(alice), token.balanceOf(alice), "PIMD balance untouched by being paid")`. **The same expression on both sides.** Unconditionally true. The claim it is labelled with — that payouts in IMD leave PIMD alone — is never tested. Capture `token.balanceOf(alice)` into a local before `_runEpoch()`.
2. **`Pimd.t.sol:428-432`** `test_fee_collection_is_still_allowed` — **no assertions at all.**
3. **`Pimd.t.sol:129`** — `assertEq(hook.HOLDERS_BPS() + 2500, hook.BPS())`. Checks that 7500 + 2500 == 10000. Arithmetic on two constants; passes regardless of any behaviour.
4. **`PimdAttacks.t.sol:112`** — `assertLt(engine.totalDripped(), potBefore)`. One epoch can release at most ~15% of the pot, so this holds even if the feature under test is inverted. Replace with `assertEq(totalDripped, alicePaid + carolPaid)` and `assertGe(pot(), bobsShare)`.
5. **`PimdAttacks.t.sol:109`** — `assertEq(phase, Idle, "the epoch still finished")`. Reachable by the `tw == 0` path with nobody paid at all.
6. **`Pimd.t.sol:251`** — `assertGt(engine.pot(), potBefore * 9 / 10)`. True for any drip between 0% and 10%; the test claims to verify ~4%.
7. **`Pimd.t.sol:292-302`** `test_a_second_pool_on_this_hook_is_refused`. Calls `initialize` from `address(this)`, not the factory. `launched` (`PimdHook.sol:228`) and the factory pin (`:231`) both fire on this input, so the test passes with **either** deleted — mutation-confirmed (it was the one test that survived the `beforeInitialize` factory-pin mutation). Fix: `vm.prank(address(factory))` and pin `AlreadyLaunched.selector`.
8. **`Pimd.t.sol:354-368`** `test_initialize_refuses_a_quote_that_is_not_imd`. `vm.assume` at `:357` **in a non-fuzz test** is not a rejection mechanism. If `uint160(junk) > uint160(t)`, `PoolManager.initialize` reverts `CurrenciesOutOfOrderOrEqual` *before the hook is ever called* (`v4-core/src/PoolManager.sol`, the order check precedes `key.hooks.beforeInitialize`), and the bare `expectRevert` at `:366` accepts it. It happens to reach the hook today (mutation-confirmed ✓) by deploy-nonce luck. Replace `vm.assume` with a mined address or an explicit `require`.
9. **`Pimd.t.sol:100`** — the **only** test of the `_SPEC_SLOT` partial-fill refusal uses a bare `vm.expectRevert()` with the reason in a *comment*. `assertEq(imd.balanceOf(bob), 1000e18)` at `:112` holds for any revert. The defence is real (mutation-killed ✓) but the test does not say so.
10. **15 of the 27 `vm.expectRevert` calls across the suite carry no selector** (`grep -c "vm.expectRevert()"` → 15). Every one of them accepts a revert from the wrong line.

## A9. Missing tests, ranked by risk

### A2 — CRITICAL. `prune()` during `Tally` permanently bricks the engine. Zero tests touch `prune`.

`fire` snapshots `epochCount = holders.length` (`PimdEngine.sol:292`). `tally`'s loop runs to that
snapshot and indexes the live array: `for (i = start; i < end; ++i) { address a = holders[i]; }` with
`end = epochCount` (`:315-316`, `:312`). `prune` is **permissionless**, is deliberately **allowed during
`Tally`** (`:249` refuses only `Pay`, and the docstring at `:242-247` explains why), and **pops the
array** (`:257`).

So one `prune` of one below-minimum holder leaves `holders.length < epochCount`, and `tally` reverts with
an index-out-of-bounds panic for ever. `tally` is the only way out of `Tally`; `fire` requires `Idle`
(`:268`); `prune` cannot help because it only removes holders already below `minBalance` (`:253`).

**PROVEN.** Probe run this session (file since removed):

```
[PASS] test_probe_prune_during_tally_bricks_the_engine() (gas: 2399452)
```
asserting, in order: `fire()` → `Tally` with `epochCount == 3`; a *griefer* address calls
`prune([carol])` → `holderCount() == 2`; `tally(3)` reverts `stdError.indexOOBError`;
`tally(type(uint256).max)` reverts identically (because `end` is `epochCount` regardless of the page
size); `fire()` reverts `WrongPhase`; phase is still `Tally`.

Cost to the attacker: **one transaction, ~30k gas, no capital.** A prunable holder requires nothing
unusual — any registered wallet that later sells below 100,000 PIMD qualifies, which is ordinary
behaviour. Consequence: the drip stops permanently, `epochQuote` is stranded outside the pot, and no
holder is ever paid again. There is no admin, no upgrade and no recovery path.

Tests to add (they fail today):
```solidity
function test_prune_during_tally_cannot_strand_the_epoch() public { /* probe above, inverted */ }
function test_prune_the_last_holder_rewrites_indices_correctly() public { … }
function test_prune_is_refused_during_pay() public {
    vm.expectRevert(PimdEngine.WrongPhase.selector); engine.prune(p);
}
```
The contract fix is one line — clamp the loop to the live array:
`uint256 end = epochCount; if (end > holders.length) end = holders.length;` — but note that still
*misweighs* a reordered set, so the cleaner fix is to refuse `prune` whenever `phase != Idle` and solve
the gas ceiling (A3) another way, since the docstring's whole justification for allowing it is that
ceiling.

### A3 — HIGH. The tally gas ceiling is real, measured, and has no remedy.

**PROVEN.** Measured this session over 300 registered holders:

```
tally gas for 300 holders: 10,086,718
gas per holder:            33,622
holders that fit in 32,000,000 gas: 951
```

`tally` must cover the whole set in one transaction (`:311`), so ~950 registered holders is a hard
ceiling. Registration is permissionless and needs only `minBalance` = 100,000 PIMD = **0.01% of supply**
per wallet (`PimdEngine.sol:231`, live value confirmed on chain). 951 wallets × 100,000 PIMD ≈ 9.5% of
supply — a few hundred dollars at a 2,500-IMD opening — and the engine can never tally again. `holders`
never shrinks for above-minimum holders, so it is a one-way ratchet: even if the current epoch squeezes
through, the next `fire` snapshots the larger set.

The docstring at `:305-306` offers monitoring as the mitigation ("`epochCount` and `holderCount()` are
public so the keeper can watch how close that ceiling is") — but **the keeper has no lever.** `prune`
cannot touch a holder at or above `minBalance`.

Note the reported block `gasLimit` on chain 4663 is 2^50 (Arbitrum's nominal value); the real limit is
the per-transaction cap and the ArbOS gas-per-second speed limit. **Measure the chain's actual accepted
tx gas limit before launch** and set `minBalance` so that (circulating supply / `minBalance`) stays
comfortably under it. `minBalance` is immutable, so this is a pre-launch decision only.

### The rest, ranked

| # | Missing test | Why it matters |
|---|---|---|
| 4 | **Second positive add from the factory** → `beforeAddLiquidity`'s `seeded` guard (`:353`) | one of the four unreviewed fixes; **currently unreachable by any test** |
| 5 | **Negative-delta removal by the position owner** → `beforeRemoveLiquidity` (`:379`) | the entire third-party-LP safety case; see A1 |
| 6 | **`flushHolders()` and the `ACTION_HOLDERS` branch** (`PimdHook.sol:407-419`, `450-454`) | **never called by any test.** This is the escape hatch for "IMD refuses the team wallet" — the only reason it exists — and it is wholly uncovered |
| 7 | **`engine.seed()`** (`PimdEngine.sol:215-220`) | **never called.** The `transferFrom` + `pot`/`totalSeeded` accounting is unverified |
| 8 | **Two swaps on this pool in one unlock** (a real router multi-hop) | `_FEE_SLOT` is always written (`:287`) but `_SPEC_SLOT` only conditionally (`:285`). Transient-storage bugs surface only with two swaps per tx, and no test does one |
| 9 | **Partially-filled exact-out *sell*** | `(amountSpecified<0)==zeroForOne` is also true for exact-out sells, so `_SPEC_SLOT` is armed and `wanted = specified + fee` (`:310`). Only the exact-in-buy branch is tested |
| 10 | **The `±300` tick tolerance boundary** | tested at `-120` (accept, `Pimd.t.sol:338`) and `+1000` (reject, `:331`). `±300` and `±301` — the actual launch constraint — are never probed |
| 11 | **The other three allowed fee tiers (500 / 3000 / 10000)** | `beforeInitialize` accepts all four (`:234-236`) but the economics assume 12,500. Open at 10,000 and the off-hook burn budget silently drops from 1.25% to 1% and **nothing reverts** |
| 12 | **`bind`'s `quote` and `poolManager` branches** (`:194-195`) | one-shot guards, untested |
| 13 | **`bind` does not validate `token_` at all** (`:188` checks only non-zero) | the hook exposes `token` as a public immutable; `bind` could assert `hook.token() == token_` and does not. A wrong `token_` is silent and permanent |
| 14 | **`bind` before the pool is open** | `h.quote()` is `address(0)` until `beforeInitialize` runs (`:253`), so bind reverts `BadConfig`. Recoverable, but the ordering constraint is enforced nowhere and tested nowhere |
| 15 | **The streak-blend formula** (`:324`) | the only real arithmetic in the engine. `test_longer_holder_gets_a_bigger_share` tests the *ladder*, not the blend. Property: buy X at t0, buy X at t1 ⇒ `streakStart ≈ (t0+t1)/2` |
| 16 | **`tierBps` boundaries** (`:398-405`) | `public pure`; exactly 1 h / 1 d / 3 d / 7 d / 14 d are never probed. One table test |
| 17 | **Hostile `_isPool` responder** | `PROBE_GAS` and the `returndatasize() > 31` guard (`:520-521`) exist for a reason no test applies |
| 18 | **`_send`'s non-revert failure modes** (`:489`) | an IMD returning `false`; an IMD that consumes all 60,000 gas |
| 19 | **`_tip` edge paths** (`:494-504`) | `pot < amt`; the send-fails-restore-state branch; budget exhaustion |
| 20 | **`flush` when `teamOwed < callerTip`** (`:432-433`) | untested |
| 21 | **`nonReentrant` on `flush`/`flushHolders`** (`:185-190`) | no reentrancy test |
| 22 | **`totalToTeam` over-counts by the tip** | `:442` adds `toTeam` while the team receives `toTeam - tip`. Site-facing stat; asserted nowhere |
| 23 | **`tx.origin` keying of the launch cap** (`:334,336`) | mutation-survived: swapping to `msg.sender` changes nothing, because `vm.prank(alice, alice)` makes them identical. **Operationally this matters**: under ERC-4337 the bundler is `tx.origin`, so every smart-wallet buyer in the first 600 s shares one 25-IMD cap |
| 24 | **`donate` is not hook-gated** | `beforeDonate`/`afterDonate` flags are `false` (`:210-211`), so `manager.donate` works on this pool untaxed. Untested, low impact |
| 25 | **`_requireLocked`'s slot constant against the *real* PoolManager** | `PimdEngine.sol:63` hardcodes `0xc090fc46…`. It matches the pinned lib (`v4-core/src/libraries/Lock.sol:8`) ✓, but if the deployed manager at `0x8366a39C…` is a different release, `exttload` returns zero and **the whole flash-borrow defence is silently off.** Local tests deploy the pinned `PoolManager`, so they can never catch this. One fork test fixes it: run `Unlocker` against the real manager and assert it reverts |

## A10. Fuzz and invariant testing: none

`foundry.toml:26-27` configures `[profile.default.fuzz] runs = 256` and **nothing uses it**. Verified:
no `invariant_` function, no `StdInvariant`, no `targetContract`/`targetSelector`, and **not one test
function anywhere takes a parameter**. All 52 tests are fixed-scenario unit tests.

For a protocol whose entire job is conserving a pot of somebody else's token across a permissionless
state machine, that is the single largest structural gap. The three invariants worth the most:

**I-1 — Hook claim solvency.** Every wei of tax minted is either owed or already paid; never both,
never neither.
```solidity
function invariant_hook_claims_are_fully_accounted() public view {
    assertEq(
        hook.holdersOwed() + hook.teamOwed(),
        manager.balanceOf(address(hook), hook.quoteId()),
        "ledger must equal ERC-6909 claims"
    );
    assertEq(
        hook.totalTaxed(),
        hook.totalToHolders() + hook.totalToTeam() + hook.holdersOwed() + hook.teamOwed(),
        "lifetime tax must be conserved"
    );
}
// handler: _buy / _sell / _buyExactOut / _sellExactOut / flush / flushHolders, fuzzed amounts and actors
```
Targets the fact that `fee` is *reassigned* in `afterSwap` (`PimdHook.sol:319`) after being loaded from
`_FEE_SLOT` (`:296`). The two branches are mutually exclusive by construction today; an invariant is
what keeps them that way. Also covers dust-rounding in `_split` (`:496-498`), which no unit test probes.
*(Note the second assertion fails today unless `totalToTeam` is corrected for the tip — finding #22.)*

**I-2 — Engine ledger solvency.** The engine never promises IMD it does not hold.
```solidity
function invariant_engine_never_promises_imd_it_lacks() public view {
    assertLe(engine.pot() + engine.epochQuote(), imd.balanceOf(address(engine)),
             "pot + epochQuote must be backed");
}
// handler: seed / register / prune / fire / tally / pay / direct IMD transfers, with time warps
```
If this ever inverts, the last holders of an epoch silently fail to be paid and the failure is
indistinguishable from an IMD blacklist. Today it is asserted once, weakly, at `PimdAttacks.t.sol:111`
and only in the state where `epochQuote == 0`.

**I-3 — Epoch liveness.** No permissionless action sequence can leave the engine unable to finish an
epoch. **This is the one that fails today (A2).**
```solidity
function invariant_an_epoch_can_always_be_completed() public {
    if (engine.phase() == PimdEngine.Phase.Tally) {
        try engine.tally(type(uint256).max) {}
        catch { fail("Tally is unreachable: the engine is bricked"); }
    }
    if (engine.phase() == PimdEngine.Phase.Pay) {
        try engine.pay(type(uint256).max) {}
        catch { fail("Pay is unreachable: the epoch is stranded"); }
    }
}
// handler must include: prune() during Tally, register() during Tally and Pay, duplicate registers,
//                       register of the distributor, and a holder selling to dust mid-epoch
```
A 256-run fuzz with `prune` in the handler set would have found A2 on day one.

---

# PART B — DEPLOY AND LAUNCH DAY

## B.0 What is already on chain (verified, chain 4663)

The deploy script has been broadcast for real **twice**, and the repo's own records disagree with the code.

```
broadcast/.../4663/run-1791384102805.json   from 0x244FA8fd…A172D
  nonce 0  CREATE   PimdEngine  0xc053381854ac4b9bc41af6d239d3a702f3dd3352   status 0x1
  nonce 1  CREATE2  PimdToken   0x9cbc347741f6b56c1c9a6043fef967e6332f84f9   status 0x1
  nonce 2  CREATE2  PimdHook    0x627a87933dc20e31fd8c49436d060f97432478cc   status 0x1

broadcast/.../4663/run-1791403799322.json   from 0x244FA8fd…A172D
  nonce 3  CREATE   PimdEngine  0x92a9abeb52031d529ab1ae3638ca073fa12be01d   status 0x1
```

| Address | What | Live? | Status |
|---|---|---|---|
| `0x92A9ABEB…Be01d` | `PimdEngine` **(current)** | yes | matches `PimdHook.ENGINE_ADDRESS` ✓, `bound() == false` ✓ |
| `0xC0533818…D3352` | `PimdEngine` (superseded) | yes, 11.4 KB | zombie |
| `0x627a8793…478cc` | `PimdHook` (superseded, 300/700 economics) | yes, 17.6 KB | zombie |
| `0x9CBc3477…F84F9` | `PimdToken` (superseded) | yes, 4.0 KB | zombie, holds the old 1e9 supply |

**The live engine's immutables, read off chain and decoded from the broadcast args:**

| field | live value | what the tests use | |
|---|---|---|---|
| `poolManager` | `0x8366a39C…40951` | same | ✓ |
| `imd` | `0x5F7Bb593…b7127` | mock | ✓ matches `QUOTE_TOKEN` |
| `team` | `0x0960E8Bd…4559B` | same | ✓ matches `TEAM_WALLET` |
| `binder` | `0x0960E8Bd…4559B` | `address(this)` | **the team wallet is the binder** |
| `dripBpsPerPeriod` | 400 | 400 | ✓ |
| `minInterval` | 120 | 120 | ✓ |
| `minBalance` | 100,000e18 | same | ✓ |
| `fireTip` | 0.01e18 | **0.02e18** | ✗ |
| `tipPerHolder` | 0.0001e18 | **0.0005e18** | ✗ |
| `maxCatchup` | **3,600 (1 h)** | **21,600 (6 h)** | ✗✗✗ |

### B1 (HIGH). The deployed economics are not the tested economics.

`PimdBase.t.sol:198-200` and `PimdFork.t.sol:88-90` both construct the engine with
`maxCatchup: 6 hours`. **The engine that is actually on chain has `maxCatchup == 3600`.** This is
frozen — `maxCatchup` is `immutable` (`PimdEngine.sol:79`) and the engine is already deployed.

Consequence: the maximum any one epoch can release is `1 − 0.96^(3600/900)` = **15.1% of the pot**, not
the 62.5% that `PimdAttacks.t.sol:245-250` asserts and explains in prose. That test's bounds
(`released < 63%`, `released > 55%`, `pot > 33%`) describe a configuration that does not exist.
`fireTip` and `tipPerHolder` are likewise 2× and 5× the live values, so every keeper-tip and
tip-budget path (`PimdEngine.sol:281`, `:494-504`) is exercised at the wrong magnitude — relevant
because `tipBudget` is 5% of a *drip that is now four times smaller*, so the clamp at `:496` will bite
far more often in production than in any test.

**Decide now:** either re-deploy the engine with `maxCatchup = 6 hours` (cheap — it is unbound, nothing
references it yet except the hook's constant, which would then also need updating and re-pushing before
the launch request), or change `PimdBase.t.sol`, `PimdFork.t.sol` and the comment at
`PimdAttacks.t.sol:245` to 1 hour and re-derive the bounds. **Do not launch with the suite asserting one
set of economics and the chain running another.**

### B2 (HIGH). `deployments.pimd.4663.json` is stale and actively dangerous.

It is gitignored (`.gitignore:5`) but present in the working tree, and it is the obvious thing for a
script, a keeper or a frontend to read:

| field | file says | reality |
|---|---|---|
| `engine` | `0xC053381854aC4b9bC41af6D239d3a702f3DD3352` | **superseded**; current is `0x92A9ABEB…` |
| `hook` | `0x627a87933DC20e31fD8C49436D060f97432478cc` | superseded zombie |
| `token` | `0x9CBc347741f6B56C1c9A6043Fef967e6332F84F9` | superseded zombie |
| `startTick` | `143580` | `LAUNCH_TICK` is **129000 ± 300** — this tick is **14,580 out** and would revert `WrongStartingPrice` |
| `tickLower` | `97560` | tests use `82980` |
| `buyTaxBps` / `sellTaxBps` | `300` / `700` | `240` / `560` |
| `launchAdmin` / `team` | `0x0960E8Bd…` | ✓ correct |

Anyone who copies `startTick` out of this file to brief the launch burns the launch. **Delete it or
regenerate it from live state before launch day**, and keep the regeneration in the runbook.

## B1a. `DeployPimd.s.sol` — internal consistency

**Engine-only: confirmed clean.** The only import is `PimdEngine` (`:5`); the only `new` is
`new PimdEngine(ec)` (`:56`). No stale hook or token deployment remains anywhere in `script/`. The
header comment (`:7-17`) accurately describes the new division of labour. Constructor args are all
correct against `PimdEngine.Config` (`PimdEngine.sol:81-92`) — field order and types line up, and both
constructor guards (`dripBpsPerPeriod ≤ 5000`, `PERIOD ≤ maxCatchup ≤ 7 days`) are satisfied by every
branch. The chain gate (`:33-35`) and the two code-presence checks (`:39-40`) are good practice and
would have caught a wrong-RPC run. Post-deploy assertions at `:58-59` are correct (the second,
`!engine.bound()`, is tautological but harmless).

Four problems:

1. **No address assertion. This is the most dangerous gap in the deploy path.** The script prints
   "write this address into `PimdHook.ENGINE_ADDRESS`" (`:65`), but `PimdHook.sol:93` already contains
   `0x92A9ABEB…`. The script deploys with **`CREATE`**, so the address is a function of the deployer's
   nonce — and the history above shows a re-run has *already* produced a second, different engine. A
   third `--broadcast` yields a third address, silently inconsistent with the compiled hook, and the
   mismatch surfaces only when `bind` reverts **after the paid launch**.
   Fix — one line, and make it unskippable:
   ```solidity
   require(address(engine) == 0x92A9ABEB52031D529AB1ae3638CA073fa12Be01d,
           "engine address does not match PimdHook.ENGINE_ADDRESS");
   ```
   Better: deploy with `CREATE2` from a fixed salt so the address is nonce-independent and the hook's
   constant can be fixed before the engine exists.
   Better still: have the script read the live engine and **refuse to deploy a second one** —
   `require(0x92A9ABEB….code.length == 0, "engine already deployed")`.
2. **`binder` defaults to the team wallet** (`:30`, `BINDER` unset at deploy → live `binder` is
   `0x0960E8Bd…`, confirmed on chain). So the one-shot `bind` power sits on the same hot wallet that
   receives the fee stream. If that key is compromised before `bind`, the attacker binds first — and
   because `bind` does not validate `token_` at all (A9 #13) and takes an arbitrary `alsoExclude`
   list, they can permanently misdirect or neuter the drip. `bind` is irreversible. Set `BINDER` to a
   cold address or a multisig for the one transaction.
3. **The mainnet branch is dead weight that invites a wrong-chain deploy.** `:21-22`, `:33`, `:37-38`,
   `:47-52` all support `block.chainid == 1`, but the hook's constants are Robinhood-only
   (`QUOTE_TOKEN = 0x5F7Bb593…`), so a mainnet engine can never be bound by any hook you will deploy.
   Delete the branch or gate it behind an explicit env flag.
4. **Nothing cross-checks the script's constants against the hook's.** `DEFAULT_TEAM` (`:25`),
   `ROBINHOOD_IMD` (`:20`) and `ROBINHOOD_POOL_MANAGER` (`:19`) match `PimdHook.sol:91,96` and the
   engine's live `poolManager` today — I verified each by hand. A one-character drift is invisible to
   the suite. See the two-test fix in A4.

## B2a. `foundry.toml` — verified line by line

| Requirement | Status |
|---|---|
| **No `fs_permissions`** | ✓ **absent.** `grep` over the file confirms. The comment at `:14-15` records why |
| **No `ffi`** | ✓ **absent** |
| **`bytecode_hash = "none"`** | ✓ present at `:13` — but see B3, it does not do the whole job |
| `solc = "0.8.26"` pinned | ✓ `:7` |
| `evm_version = "cancun"` | ✓ `:8`, and **safe on this chain**: ArbOS 116 (measured), far past the ArbOS 32 that introduced EIP-1153. `TSTORE`/`TLOAD` (`PimdHook.sol:511,517`) and `exttload` (`PimdEngine.sol:461`) will work |
| Libraries pinned | ✓ `lib/forge-std` and `lib/v4-periphery` are **committed as files** (1,974 tracked paths, no `.gitmodules`), so a fresh clone gets byte-identical sources |
| Runtime size | ✓ hook runtime is 14,513 bytes, well under EIP-170 |
| Builds under Foundry 1.8.3 | ✓ verified — full compile and 46/46 green in this session |

### B3 (MEDIUM). `bytecode_hash = "none"` leaves the solc version in the deployed bytes.

The stated purpose (`foundry.toml:12`) is "a launch compares deployed bytes against a local build, so
the metadata hash must not be in them." It is only half-achieved. Inspecting the built artifact:

```
out/PimdHook.sol/PimdHook.json  →  deployedBytecode ends with:
  a164736f6c634300081a        = CBOR { "solc": 0.8.26 }   (10-byte blob + 2-byte length)
```

`bytecode_hash = "none"` removes the IPFS/bzzr digest; it does **not** suppress the CBOR section. Any
verifier on a different solc patch produces different trailing bytes and a byte-comparison fails for a
reason that has nothing to do with the code. Add:

```toml
cbor_metadata = false      # solc >= 0.8.18; strips the trailing {"solc": …} blob entirely
```

### B4 (MEDIUM). `via_ir = true` with `optimizer_runs = 44444444` is a reproducibility bet.

`foundry.toml:9-11`. The IR pipeline's output is sensitive to the exact solc patch version and the Yul
optimiser sequence, and `44444444` is an unusual value that must be matched exactly. This matters more
than usual here because **the launch factory deploys the hook at a mined `CREATE2` salt**: the salt is
computed from `keccak256(creationCode ‖ abi.encode(poolManager, token))`, so if the salt is mined
against one build and the factory deploys a differently-compiled artifact, the deployed address does not
carry the `0x3ACC` permission bits and `Hooks.validateHookPermissions` reverts in the constructor —
launch dead.

Also note the hook's address depends on the **token's** address (it is a constructor argument), which
the factory deploys in the same transaction. So the salt mining has an ordering dependency that no test
exercises.

Mitigations, all cheap:
- Pin the toolchain in-repo (`foundry.toml` → `[profile.default] solc_version` is already pinned; add a
  committed note of `forge --version` = `1.8.3 / cae51ad` and the artifact's
  `keccak256(creationCode)`).
- Add a CI/pre-launch check that re-builds and asserts the hook creation-code hash is unchanged.
- Hand the factory operator the exact `foundry.toml` and solc version, and have them confirm the mined
  address before the launch transaction is paid for.

### B5 (LOW). No verifier configured.

There is no `[etherscan]` / `[verify]` block, so `forge verify-contract` has no API URL for chain 4663.
If verification is outstanding, that is why. Add the chain's explorer endpoint before launch so
verification is one command rather than a research task on launch day.

## B6. Launch-day runbook

Gas prices measured on chain 4663 at the time of writing: **20,206,000 wei (0.0202 gwei)**.
Binder/team wallet `0x0960E8Bd…`: **389,133,096,969,168 wei ≈ 19.3 M gas of headroom** — enough for
`bind` (~250 k) many times over, but **not** enough to run the keeper from that wallet long-term.
Deployer `0x244FA8fd…`: 3,626,354,797,463,532 wei, nonce 4.

### Phase 0 — before anything costs money

- [ ] **Resolve B1.** Pick 1 h or 6 h for `maxCatchup` and make the chain and the suite agree. If you
      re-deploy the engine, `PimdHook.ENGINE_ADDRESS` changes and must be pushed **before** the launch
      request goes out.
- [ ] **Delete or regenerate `deployments.pimd.4663.json`** (B2). In particular never brief
      `startTick: 143580`.
- [ ] Add the `require(address(engine) == 0x92A9ABEB…)` guard to `DeployPimd.s.sol` (B1a #1), or an
      "already deployed, refusing" guard. **Do not run the script again without it.**
- [ ] Add `cbor_metadata = false` and rebuild (B3). Record the resulting
      `keccak256(PimdHook.creationCode)`.
- [ ] Confirm `forge --version` is `1.8.3 (cae51ad)` on whatever machine mines the salt (B4).
- [ ] Fix the five false-green liquidity tests (A1) and the three honest reverts in A8 #7–9. Add the
      `prune` tests (A2) — **they fail, and the contract needs the fix before launch.**
- [ ] Decide `minBalance` against the measured per-tx gas limit (A3). It is immutable after deploy.
- [ ] Set `BINDER` to a cold address or multisig (B1a #2).

### Phase 1 — settle the factory's behaviour (free, and launch-blocking if skipped)

- [ ] `cast run <txhash>` on a prior launch by `0xA25B02A1e93903b790E6aaf7dA1b8B8d50294645`. From the
      trace, read off:
      - who is `msg.sender` at the `PoolManager.initialize` frame → must equal `LAUNCH_FACTORY`
      - who is `msg.sender` at each `PoolManager.modifyLiquidity` frame → must equal `LAUNCH_FACTORY`
      - **how many** `modifyLiquidity` frames there are → must be exactly **one** positive add
      - whether any frame has a **negative** `liquidityDelta` anywhere in the factory's lifecycle
        (a finalise / refund / burn step) → if yes, `beforeRemoveLiquidity` reverts it **forever**
      - whether the factory swaps in the launch transaction → bytecode says no, confirm
- [ ] Confirm with the pad operator that the token's `CREATE2` salt is mined so the token sorts
      **above** IMD (`0x5F7Bb593…`), keeping IMD as `currency0`.
- [ ] Confirm the fee tier the factory will use. The hook accepts 500 / 3000 / 10000 / 12500
      (`PimdHook.sol:234-236`) but the economics assume **12,500**, and the wrong tier opens silently
      (A9 #11).
- [ ] Confirm the opening tick. `LAUNCH_TICK = 129000 ± 300` ≈ **±3.05% in price**, i.e. within ~3% of
      2.5e-6 IMD per PIMD. (2,500 IMD over 1e9 supply works out to tick ≈ 128,993 — 7 ticks in, plenty
      of room, *if* the pad is briefed in ticks. If it is briefed in "opening market cap" and computes
      the price itself, verify the arithmetic lands inside the band before paying.)
- [ ] Confirm the seed range's ticks are multiples of `tickSpacing = 60`. `82980` ✓ and `129000` ✓ both
      are; a misaligned upper bound reverts `TickMisaligned`.
- [ ] **Get the airdrop distributor's address.** Nothing can proceed safely without it.
- [ ] Run the fork suite: `forge test --match-path test/pimd/PimdFork.t.sol --fork-url robinhood`.
      Add the `assertGt(hook.initBlock(), block.number)` assertion first (A6).
- [ ] Add and run the fork test that asserts `_requireLocked` reverts against the **real** PoolManager
      (A9 #25).

### Phase 2 — deploy the engine (if re-deploying)

- [ ] Dry-run first (no `--broadcast`). Read the predicted address.
- [ ] `PRIVATE_KEY=… BINDER=<cold> forge script script/DeployPimd.s.sol:DeployPimd --rpc-url robinhood --broadcast`
- [ ] Verify on chain: `team()`, `binder()`, `maxCatchup()`, `dripBpsPerPeriod()`, `minBalance()`,
      `bound() == false`.
- [ ] Write the address into `PimdHook.ENGINE_ADDRESS`, rebuild, **re-record the creation-code hash**,
      commit, push.
- [ ] **Never re-run with `--broadcast`.** It has already happened once and left a zombie engine.

### Phase 3 — the launch (paid, one-shot)

- [ ] Hand the factory operator: the exact commit, `foundry.toml`, `forge 1.8.3`, the expected hook
      creation-code hash, the opening tick, the seed range, the fee tier.
- [ ] Have them confirm the **mined hook address ends in the `0x3ACC` permission bits**
      (`uint160(addr) & 0x3FFF == 0x3ACC`) before paying.
- [ ] Launch. Immediately verify on chain: `hook.launched()`, `hook.seeded()`,
      `hook.quote() == 0x5F7Bb593…`, `hook.engine() == <engine>`, `hook.team() == 0x0960E8Bd…`,
      `hook.poolKey()` currencies and fee, and the actual opening tick inside ±300 of 129000.
- [ ] **Nobody swaps in the initialization L2 block** — `beforeSwap` reverts `InitBlockSwap`
      (`PimdHook.sol:273`). Tell anyone watching.

### Phase 4 — bind (ONE SHOT)

- [ ] **Only after the pool is open.** `bind` reads `hook.quote()`, which is `address(0)` until
      `beforeInitialize` runs, so an early bind reverts `BadConfig` (recoverable — the one-shot is not
      consumed on revert — but it wastes time under pressure).
- [ ] Confirm the binder wallet has native gas. Currently ~19.3 M gas of headroom at 0.0202 gwei ✓.
- [ ] Build the `alsoExclude` list. **The airdrop distributor is mandatory.** It holds ~10% of supply,
      it is not pool-shaped so `_isPool` (`PimdEngine.sol:510`) does not see it, and it cannot forward
      an IMD payout. `register` is **permissionless**, so if it is omitted from the list *anyone* can
      register it and ~10% of every drip is burnt into a dead contract **permanently** — there is no
      `exclude()` after bind, and `prune` cannot remove it while it holds ≥ `minBalance`.
      Also include, as cheap insurance:
      - the launch factory `0xA25B02A1e93903b790E6aaf7dA1b8B8d50294645` (it may hold the undistributed
        remainder)
      - the burn / paying wallet that buys-and-burns off the pool's 1.25%
      - the three project hot wallets
      - any bridge or CEX deposit contract known in advance

      Already automatic (`PimdEngine.sol:201`): the hook, the PoolManager, the engine, `team`,
      `address(0)`, `DEAD`.
- [ ] **Triple-check `token_`.** `bind` validates the hook three ways (`:193-195`) and the token
      **not at all** (`:188` is a non-zero check). A wrong token address binds successfully and
      silently misallocates every drip, for ever.
- [ ] `engine.bind(token, hook, [distributor, factory, burnWallet, …])`
- [ ] Verify: `bound() == true`, `token()`, `hook()`, and `excluded(x) == true` for every address in
      the list — read each one back individually.

### Phase 5 — keeper

- [ ] Fund the keeper wallet separately (not the binder/team wallet).
- [ ] Register the first holders; watch `holderCount()` against the measured tally ceiling (A3).
- [ ] First `fire` can be 2 minutes after bind (`minInterval = 120`). Nothing pays out inside the first
      hour by design (`tierBps` returns 0 below 1 h).
- [ ] `hook.flush()` is permissionless and safe before bind — the IMD sits at the engine and the first
      `fire` books it via `_book` (`PimdEngine.sol:449-457`).
- [ ] Alert on `phase() == Tally` persisting across more than one `minInterval` — that is the A2 brick
      signature.

## B7. Unrecoverable if done in the wrong order

Every one-shot in the system, and what you lose.

| One-shot action | Why it is one-shot | Irreversible consequence |
|---|---|---|
| **`PimdEngine` `CREATE` deploy** | address is nonce-derived and is compiled into the hook as a constant | A mismatch with `PimdHook.ENGINE_ADDRESS` means `flush()` sends real IMD to a dead address for ever. `bind` reverts, so you find out — but only after the paid launch, and the hook has no setter, no owner and no upgrade path. **Already went wrong once**: two engines exist. |
| **The hook's four constants** (`PimdHook.sol:91,93,96,100`) | `internal constant`, frozen at the factory's deploy; no owner, no setter | `TEAM_WALLET` wrong → 25% of every trade's tax to a stranger, for ever, **with nothing reverting to tell you**. `QUOTE_TOKEN` or `LAUNCH_FACTORY` wrong → `beforeInitialize` reverts and the paid launch is burned. |
| **`beforeInitialize` → `launched = true`** (`:256`) | `if (launched) revert AlreadyLaunched()` (`:228`) | One pool per hook, for ever. A *failed* initialize is recoverable (the whole tx reverts, `launched` rolls back). A *successful but wrong* one is not: an accepted fee tier of 500/3000/10000 instead of 12500, or a price 300 ticks off, is permanent. |
| **`beforeInitialize` → `initBlock`, `launchStart`** (`:257-258`) | written once | The launch-cap window cannot be restarted, extended or re-armed. If `L2Block` fell back at this moment (A6), the per-origin cap is silently off for the whole launch. |
| **`beforeAddLiquidity` → `seeded = true`** (`:354`) | `if (seeded) revert LiquidityIsLocked()` (`:353`) | **Exactly one liquidity add, ever.** A short seed, a wrong range, or a stranger's one-wei squat consumes it. The amount and range of the protocol's entire liquidity are fixed by that single call. |
| **`beforeRemoveLiquidity`** (`:379`) | refuses every negative delta from every caller, with no exception and no owner | **The seeded liquidity can never be withdrawn by anyone, including the position owner, for ever.** If the pad's own flow includes a withdraw, burn, migrate or "take our cut" step, that step reverts permanently and the relationship is unworkable. Settle this with the operator **before** paying. |
| **`engine.bind`** (`PimdEngine.sol:185`) | `if (bound) revert AlreadyBound()` (`:187`) | `token`, `hook` and the **entire exclusion set** are frozen. A missing airdrop distributor = ~10% of every drip stranded in a dead contract for ever (and `register` is permissionless, so you cannot even avoid it by discipline). A wrong `token_` = total, silent misallocation. |
| **`excluded[…]`** (`:203`, `:207`) | only ever written inside `bind` | No address can be added to or removed from the exclusion set after bind. There is no `exclude()`. |
| **Engine config** (`:66-79`, all `immutable`) | constructor-only | `minBalance` fixes the tally gas ceiling (A3); `maxCatchup` fixes the release clamp (B1). Both are wrong-ish today relative to the tests. |
| **Every holder's `streakStart`** (`:236`) | "the clock starts at registration, never earlier" | Registering a holder early does not retro-credit them; registering late silently resets nothing but costs them tier. No way to backdate. |

**And one that is not a one-shot but behaves like one:** the A2 brick. `prune` during `Tally` is a
single permissionless transaction, costs ~30 k gas, requires no capital, and ends the drip permanently.
It is the only item on this page an *outsider* can trigger. Fix it before launch.

---

## Appendix — commands used, for reproduction

```bash
export PATH="$PATH:/c/Users/johnk/.foundry/bin"
R=https://robinhood-rpc.publicnode.com

forge test --match-path "test/pimd/{Pimd,PimdAttacks,Gas}.t.sol"   # 46 passed
cast block latest --rpc-url $R                                      # gasLimit 2^50, l1BlockNumber 26145766
cast call 0x…064 "arbOSVersion()(uint256)"    --rpc-url $R          # 116  → Cancun/EIP-1153 available
cast call 0x…064 "arbBlockNumber()(uint256)"  --rpc-url $R          # 83089587  (vs block.number 26145766)
cast code 0x…064                              --rpc-url $R          # 0xfe  → INVALID; forks fall back
cast estimate 0x…064 "arbBlockNumber()"       --rpc-url $R          # 22033 → precompile ≈ 1k gas
cast call 0x92A9ABEB52031D529AB1ae3638CA073fa12Be01d "bound()(bool)"        --rpc-url $R   # false
cast call 0x92A9ABEB52031D529AB1ae3638CA073fa12Be01d "maxCatchup()(uint256)" --rpc-url $R  # 3600
cast call 0x92A9ABEB52031D529AB1ae3638CA073fa12Be01d "binder()(address)"     --rpc-url $R  # 0x0960E8Bd…
cast code 0xA25B02A1e93903b790E6aaf7dA1b8B8d50294645 --rpc-url $R > factory.hex   # 17320 bytes
cast sig "initialize((address,address,uint24,int24,address),uint160)"             # 0x6276cbbe → present
cast sig "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)"
                                                                                  # 0x5a6bcfda → present
cast sig "modifyLiquidities(bytes,uint256)"                                       # 0xdd46508f → ABSENT
cast gas-price --rpc-url $R                                                       # 20206000
```

Mutation testing: copy `src/pimd/{PimdHook,PimdEngine}.sol` aside, delete the guard, re-run that
guard's own tests, restore, re-run the full suite and confirm the gas numbers are byte-identical. All
mutations in this pass were reverted; `git diff --stat` over `src/ script/ test/ foundry.toml` is empty.
