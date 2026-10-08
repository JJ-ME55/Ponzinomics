# 04 — Arithmetic, casts, rounding and precision

Scope read line by line: `src/pimd/PimdEngine.sol` (524), `src/pimd/PimdHook.sol` (525),
`src/pimd/PimdToken.sol` (49). Supporting reads: `src/libraries/L2Block.sol`,
`script/DeployPimd.s.sol`, and the vendored v4-core (`PoolManager.sol`, `libraries/Hooks.sol`,
`libraries/SafeCast.sol`, `libraries/FullMath.sol`) because three of the hook's casts are only
safe because of v4-core's own bounds.

**Source version.** A parallel mutation-testing process is editing the working tree
(`PimdHook.beforeAddLiquidity`/`beforeRemoveLiquidity` and `PimdEngine.tally` line 311 currently
carry `// MUTANT` edits). Everything below is against **committed HEAD** `b655c80`, which I
re-read with `git show HEAD:`. Where a PoC was run against the mutated tree I state that the
mutation does not change the result.

**Config used for concrete numbers** (`script/DeployPimd.s.sol`):

| | mainnet | Robinhood | test harness |
|---|---|---|---|
| `dripBpsPerPeriod` | 150 | 400 | 400 |
| `minInterval` | 120 s | 120 s | 120 s |
| `minBalance` | 1,000,000e18 | 100,000e18 | 100,000e18 |
| `fireTip` | 0.05e18 | 0.01e18 | 0.02e18 |
| `tipPerHolder` | 0.003e18 | 0.0001e18 | 0.0005e18 |
| `maxCatchup` | 6 h | 1 h | 6 h |

`PERIOD = 900`, `BPS = 10_000`, `WAD = 1e18`, supply = `1e27`.

PoCs: `test/pimd/ZZArith.t.sol` (7 tests, all passing) and `test/pimd/ZZArith2.t.sol` (2 tests).

---

## 1. The 25 casts

Storage widths first, because every bound below depends on them:

```
struct Holder { uint128 lastBal; uint64 streakStart; uint64 index1; uint128 weight; uint128 received; }
```

Key bounds, computed not asserted:

* supply `S = 1e27`; `uint64` max `= 1.8447e19`. **`S / uint64max = 5.42e7`** — a PIMD balance
  would overflow `uint64` by 54 million times. Nothing stores a balance in `uint64`; `streakStart`
  and `index1` are the only `uint64` fields and neither holds a token amount.
* max single weight `= S * 30_000 / 10_000 = 3e27`; `uint128` max `= 3.4028e38`.
  **headroom 1.13e11×.**
* max `totalWeight` (uint256) `= 3e27`, because `Σ balances ≤ S` and `tierBps ≤ 30_000`.
* `uint128` max in 18-decimal tokens `= 3.4028e20`.
* `int128` max `= 1.7014e38`.

| # | file:line | cast expression | proven max of the value | target max | verdict |
|---|---|---|---|---|---|
| 1 | PimdEngine.sol:234 | `uint64(holders.length)` | gas-bounded; each `push` ≥ 20k gas, so `< 2^32` on any real chain | 1.8447e19 | **SAFE** |
| 2 | PimdEngine.sol:235 | `uint128(bal)` | `1e27` (PIMD supply) | 3.4028e38 | **SAFE** |
| 3 | PimdEngine.sol:236 | `uint64(block.timestamp)` | `< 2e10` for any plausible chain life | 1.8447e19 | **SAFE** |
| 4 | PimdEngine.sol:256 | `uint64(idx1)` | `idx1` is read out of the `uint64 index1` field, so `< 2^64` by construction | 1.8447e19 | **SAFE** |
| 5 | PimdEngine.sol:321 | `uint64(nowTs)` | as #3 | 1.8447e19 | **SAFE** |
| 6 | PimdEngine.sol:324 | `uint64((last*streakStart + (bal-last)*nowTs)/bal)` | weighted mean of `streakStart` and `nowTs`, both `≤ nowTs` ⇒ result `≤ nowTs < 2e10`. Intermediates: `last*streakStart ≤ 1e27·2e10 = 2e37`, `(bal-last)*nowTs ≤ 2e37`, sum `≤ 4e37` vs uint256 max `1.1579e77` (and checked, so it would revert, not wrap) | 1.8447e19 | **SAFE** |
| 7 | PimdEngine.sol:326 | `uint128(bal)` | `1e27` | 3.4028e38 | **SAFE** |
| 8 | PimdEngine.sol:329 | `uint128(w)` | `w = bal·tierBps/BPS ≤ 1e27·3 = 3e27`; intermediate `bal·tierBps ≤ 3e31` | 3.4028e38 | **SAFE** |
| 9 | PimdEngine.sol:370 | `uint128(amt)` | `amt ≤ epochQuote ≤` lifetime IMD routed to the engine. Breach needs `h.received > 3.4028e20` IMD | 3.4028e38 | **SAFE** given IMD supply ≪ 3.4e20 — see F-4; and even a breach cannot misdirect a transfer, only a counter |
| 10 | PimdHook.sol:257 | `uint64(L2Block.number())` | block number `< 2^64` on every real chain | 1.8447e19 | **SAFE** — see F-9 for the `initBlock == 0` sentinel |
| 11 | PimdHook.sol:258 | `uint64(block.timestamp)` | as #3 | 1.8447e19 | **SAFE** |
| 12 | PimdHook.sol:288 | `uint128(fee)` | `fee < 2^127 = 1.7014e38`, enforced one line earlier by `poolManager.mint` → `SafeCast.toInt128(uint256)` which reverts on `x >= 1<<127`. The only other path is `fee == 0` | 3.4028e38 | **SAFE**, by an external invariant — see F-12 |
| 13 | PimdHook.sol:288 | `int128(uint128(fee))` | same `< 1.7014e38`, so the sign bit is never set | 1.7014e38 | **SAFE** (same external invariant) |
| 14 | PimdHook.sol:309 | `uint128(-a0q)` | `a0q : int128`; `-a0q ∈ [0, 2^127-1]`; `-type(int128).min` **reverts** in 0.8.26 rather than wrapping | 3.4028e38 | **SAFE** |
| 15 | PimdHook.sol:309 | `uint256(uint128(...))` | widening | — | **SAFE** |
| 16 | PimdHook.sol:309 | `uint128(a0q)` | taken only on the `a0q >= 0` branch, so `≤ 2^127-1` | 3.4028e38 | **SAFE** |
| 17 | PimdHook.sol:309 | `uint256(uint128(...))` | widening | — | **SAFE** |
| 18 | PimdHook.sol:317 | `uint128(-a0)` | as #14 | 3.4028e38 | **SAFE** |
| 19 | PimdHook.sol:317 | `uint256(uint128(...))` | widening | — | **SAFE** |
| 20 | PimdHook.sol:317 | `uint128(a0)` | as #16 | 3.4028e38 | **SAFE** |
| 21 | PimdHook.sol:317 | `uint256(uint128(...))` | widening | — | **SAFE** |
| 22 | PimdHook.sol:321 | `uint128(fee)` | `quoteAmt ≤ int128max = 1.7014e38` ⇒ sell `fee ≤ 1.7014e38·560/10000 = 9.5279e36`; buy `fee ≤ 1.7014e38·240/9760 = 4.1838e36` | 3.4028e38 | **SAFE** by a *local* bound (35.7× and 81.3× headroom) |
| 23 | PimdHook.sol:321 | `int128(uint128(fee))` | `≤ 9.5279e36` | 1.7014e38 | **SAFE** (17.9× headroom) |
| 24 | PimdHook.sol:333 | `uint128(-delta.amount0())` | reached only under `params.zeroForOne`, where the raw swap delta's `amount0` is the swapper's IMD *input* and is `≤ 0`, so `-amount0 ∈ [0, 2^127-1]` | 3.4028e38 | **SAFE**, and fail-closed: a hypothetical positive `amount0` yields ≈3.4e38 and trips `LaunchBuyCap`, it does not under-count |
| 25 | PimdHook.sol:333 | `uint256(uint128(...))` | widening | — | **SAFE** |

**No cast in scope is UNSAFE.** Two deserve flagging anyway: #12/#13 are safe only because
v4-core reverts first (F-12), and #9's bound is a property of somebody else's token (F-4).

### The one int128 truncation that would be theft, disproved properly

`toBeforeSwapDelta(int128(uint128(fee)), 0)` at PimdHook.sol:288 is the direct theft primitive the
brief names: for `fee ∈ [2^127, 2^128)`, `uint128(fee)` keeps the value but `int128(...)` flips it
**negative**, and a negative specified delta is credited to the *swapper*, not the hook.

`fee` is derived from `params.amountSpecified`, which is a caller-supplied `int256` with no bound
in v4 beyond "non-zero". For an exact-out sell `fee = amt·560/9440 ≈ 0.0593·amt`, so
`amt ≈ 2.87e39` would put `fee` in the truncating window — well inside `int256`.

It is unreachable because line 282 runs first:

```solidity
if (fee > 0) poolManager.mint(address(this), quoteId, fee);   // line 282
return (..., toBeforeSwapDelta(int128(uint128(fee)), 0), 0);   // line 288
```

`PoolManager.mint` does `_accountDelta(currency, -(amount.toInt128()), msg.sender)` and
v4-core's `SafeCast.toInt128(uint256 x)` is `if (x >= 1 << 127) revert`. So the reachable range at
line 288 is exactly `[0, 2^127)` — the truncating window `[2^127, 2^128)` is precisely what `mint`
rejects. The boundary lines up exactly, with zero margin. See F-12.

---

## 2. The release curve

```solidity
function _released(uint256 p, uint256 elapsed) internal view returns (uint256) {
    if (p == 0 || elapsed == 0) return 0;
    if (elapsed > maxCatchup) elapsed = maxCatchup;
    uint256 keepPerPeriod = WAD - (dripBpsPerPeriod * WAD) / BPS;
    uint256 keep = _pow(keepPerPeriod, elapsed / PERIOD);
    uint256 frac = elapsed % PERIOD;
    keep = (keep * (WAD - (dripBpsPerPeriod * WAD * frac) / (BPS * PERIOD))) / WAD;
    return p - FullMath.mulDiv(p, keep, WAD);
}
```

**Can `released > pot`? No — proven.** `dripBpsPerPeriod ∈ [1, 5000]` (constructor), so
`keepPerPeriod = WAD - ⌊dripBps·WAD/BPS⌋ ∈ [5e17, 999_900_000_000_000_000] ⊆ [0, WAD]`.
`_pow` only ever computes `⌊r·base/WAD⌋` and `⌊base²/WAD⌋` from `r, base ≤ WAD`, both of which are
`≤ WAD`, and `r` starts at `WAD`; so `keep ≤ WAD`. The fractional line multiplies by
`(WAD - x)/WAD ≤ 1`, so still `keep ≤ WAD`. Therefore `FullMath.mulDiv(p, keep, WAD) ≤ p` and
`p - …` cannot underflow. **`released ≤ p` always.**

**No underflow in the fractional term.** `dripBps·WAD·frac ≤ 5000·1e18·899 = 4.495e24`;
`BPS·PERIOD = 9e6`; quotient `≤ 4.994e17 < WAD`, so `WAD - …` stays positive with 5e17 to spare.
Numerator `4.495e24` vs uint256 max `1.1579e77` — 2.6e52× headroom.

**No overflow in `_pow`.** `r·base ≤ 1e36` and `base² ≤ 1e36`, both 1.16e41× under uint256 max.
`n = elapsed/PERIOD ≤ maxCatchup/900 ≤ 604800/900 = 672`, so at most 10 loop iterations.

**Precision.** Measured against exact rationals (`fractions.Fraction`) on a `p = 1e24` pot:

| config | elapsed | implementation | relative error vs exact |
|---|---|---|---|
| 1.5 %/15 min, 6 h cap | 1 s | 16,666,666,666,666,000,000 | −4.0e-14 |
| 1.5 %/15 min, 6 h cap | 900 s | 15,000,000,000,000,000,000,000 | 0 (exact) |
| 1.5 %/15 min, 6 h cap | 21,600 s (clamp) | 304,223,859,391,774,029,000,000 | +9.07e-18 |
| 4 %/15 min, 6 h cap | 1 s | 44,444,444,444,444,000,000 | −1.0e-14 |
| 4 %/15 min, 6 h cap | 21,600 s (clamp) | 624,586,753,272,897,589,000,000 | +1.21e-18 |
| 4 %/15 min, 1 h cap | 3,600 s (clamp) | 150,653,440,000,000,000,000,000 | 0 (exact) |
| 0.01 %/15 min, 900 s cap | 1 s | 111,111,111,111,000,000 | −1.0e-12 |
| 50 %/15 min, 7 d cap | 604,800 s (clamp) | 1,000,000,000,000,000,000,000,000 (= the whole pot) | +5.1e-203 |

Worst observed relative error **1e-12**, at the 1-second / `dripBps = 1` corner, and the error is
**negative** there — the implementation releases slightly *less* than the exact curve, which
favours the pot. At whole-period boundaries it is exact. `_pow(0.96e18, 24) = 375413246727102411` against an exact `0.96^24·WAD = 375413246727102411.7558…`
— the implementation returns the exact floor, with no compounded error at all for this exponent.

`_pow` does truncate a small base to zero (`_pow(5e17, 672) = 0`, i.e. 0.5^672 ≈ 1e-202 → 0), which
makes `released == pot` exactly. That is the mathematically right answer, and `released == pot` is
reachable only in that degenerate configuration; `released > pot` is impossible.

**Is the clamp binding?** Yes, and exactly. `maxCatchup ∈ [900, 604800]` is enforced in the
constructor. With `elapsed = 1e9` the result is bit-identical to `elapsed = maxCatchup` in every row
above. PoC `test_D_released_never_exceeds_pot_and_rounds_up` asserts both the clamp value and
`released ≤ pot`.

**Can `released` be 0 when it should not be?** No. For `elapsed ≥ 1`, the fractional term
`⌊dripBps·WAD·frac/(BPS·PERIOD)⌋ ≥ ⌊1e18/9e6⌋ = 111_111_111_111 ≥ 1`, so `keep ≤ WAD - 1`, so
`⌊p(WAD-1)/WAD⌋ ≤ p-1` and `released ≥ 1` for any `p ≥ 1`. The final subtraction effectively rounds
**up**, by at most 1 wei. That is the one place the pot rounds against itself; it also produces F-8.

**Cadence invariance (and why the tip cap holds).** Whole periods compound exactly multiplicatively:
`keep(1800) = 0.975² = 0.950625 = keep(900)²`, so firing every 900 s and firing once per 1800 s
release the same total. Sub-period firing releases marginally *less* (linear partial-period keep
`1 - r·f > (1-r)^f`): two 450-second fires give `0.9875² = 0.97515625` kept against `0.975` for one
900-second fire — the drip is 0.6 % slower, never faster. There is no cadence an attacker can pick
that accelerates the curve.

---

## 3. Weight and share maths

`w = (bal * tierBps(age)) / BPS`, `share = FullMath.mulDiv(epochQuote, w, totalWeight)`.

**Numerator bound the brief asks for.** With the real types, `FullMath.mulDiv` computes the full
512-bit product, so there is nothing to overflow. Had it been written `total * w / tw`, overflow
would need `epochQuote > 1.1579e77 / 3e27 = 3.86e49` wei of IMD = 3.86e31 tokens — unreachable, but
the use of `FullMath` makes the question moot rather than merely improbable. Correct choice.

**Rounding direction at every division:**

| site | expression | rounds | who gains the dust |
|---|---|---|---|
| Engine:328 | `bal * tierBps / BPS` | down | nobody — a smaller weight, ≤ 1 wei of weight lost. At `tierBps = 10_000` or `30_000` it is exact; only the 0.5×/1.5× bands can lose a wei |
| Engine:367 | `mulDiv(total, w, tw)` | down | the pot (returned via `leftover`) |
| Engine:281 | `drip * 500 / BPS` | down | the pot (smaller tip budget) |
| Engine:324 | blended `streakStart` | down ⇒ **age rounds up** | the holder, by < 1 s |
| Engine:468/471/478/479 | the curve | mixed, net \|err\| ≤ 1e-12 relative | immaterial |
| Hook:281/319 | `amt*bps/BPS`, `amt*bps/(BPS-bps)` | down | **the trader**, ≤ 1 wei per swap |
| Hook:496 | `fee * 7500 / BPS` | down | **the team** gets `⌈fee/4⌉`, holders `⌊3fee/4⌋` |

**Can the sum of shares exceed `epochQuote`?** No. `Σᵢ ⌊total·wᵢ/tw⌋ ≤ ⌊total·(Σwᵢ)/tw⌋ = total`
because `Σwᵢ = tw` exactly: `tally` accumulates `tw` over `i ∈ [0, epochCount)` in the same single
pass, and `pay` reads `h.weight` over the same index range and zeroes each one before use, so no
weight is counted twice and none is missed. The `leftover = total - epochPaidQuote` on Engine:387
therefore cannot underflow. **No over-payment path, no insolvency.**

**Single holder:** `mulDiv(total, w, w) = total` exactly — one holder takes 100 % with zero dust.

**Can rounding be farmed?** No, and the direction is why. Every division that splits the epoch
floors, so splitting a bag over N addresses *loses* up to N−1 wei of weight at the 0.5×/1.5× bands
and up to N wei of share, and all of it falls into `leftover` which goes back to the pot. The
sign is wrong for a farmer in both places. Many small swaps likewise only under-charge the tax
by ≤ 1 wei each (F-5), which is 1e-18 IMD against a V4 swap's gas.

**Division before multiplication:** none, anywhere in scope. Every ratio multiplies first
(Engine:324, 328, 468, 471; Hook:281, 319, 496). `_pow` divides by `WAD` between steps, which is
inherent to fixed-point exponentiation and is bounded above.

**Concentration/split symmetry (sanity check on the blend).** Two wallets of `L` at 14 days (3×)
carry `6L` of weight. Merge them: the receiver sees `bal = 2L > last = L`, so
`age_new = L·14d/2L = 7d` → 2× band → `4L`; the sender resets to 0. Split a `2L` bag instead: the
sender's `bal < last` resets it to 0 and the new wallet starts at age 0 → `0`. Both directions lose.
The dilution identity `age_new = last · age_old / bal` is exact: PoC
`test_G_blend_dilutes_age_proportionally` doubles a 14-day bag and measures `age = 604800` s —
exactly 7 days, to the second.

---

## 4. Hook fee maths, all four swap directions

Verified against the vendored `PoolManager.swap` (lines 187–227) and `Hooks.beforeSwap`/`afterSwap`
(lines 248–315). The decisive detail: **the hook's `afterSwap` receives the raw `swapDelta` from
`_swap`, before `swapDelta - hookDelta`.** Every number below depends on that.

Let `a = |amountSpecified|`, `f` = fee, `p` = the pool's own 1.25 % LP fee (inside the swap).

| direction | branch | fee formula | raw `delta.amount0()` | `wanted` | gross tax rate |
|---|---|---|---|---|---|
| exact-in buy (`spec<0`, `0→1`) | beforeSwap (IMD specified) | `a·240/10000` | `-(a-f)` | `spec - fee = a-f` ✓ | `f/a = 2.4 %` |
| exact-out sell (`spec>0`, `1→0`) | beforeSwap (IMD specified) | `a·560/9440` | `+(a+f)` | `spec + fee = a+f` ✓ | `f/(a+f) = 5.6 %` |
| exact-out buy (`spec>0`, `0→1`) | afterSwap (IMD unspecified) | `q·240/9760` | `-q` | n/a (`specified == 0`) | `f/(q+f) = 2.4 %` |
| exact-in sell (`spec<0`, `1→0`) | afterSwap (IMD unspecified) | `q·560/10000` | `+q` | n/a | `f/q = 5.6 %` |

The two branch tests are exact complements — `(amountSpecified<0)==zeroForOne` in `beforeSwap`
against `!=` in `afterSwap` — so **exactly one fee is charged per swap**, and the `fee` local in
`afterSwap` is either the tloaded one (specified case, unspecified branch not taken) or 0 then
overwritten (unspecified case). No double charge, no missed charge.

`amt·bps/BPS` vs `amt·bps/(BPS-bps)` is the right pair: the first takes the fee *out of* a gross
specified amount, the second grosses *up* a net one. Both floor, so both round in the **trader's**
favour by at most 1 wei. The two formulae are not interchangeable: swapping them would charge
2.4 %/(1−2.4 %) = 2.459 % on exact-in buys.

`_split` is exactly conservative: `toHolders + (fee - toHolders) = fee`, so minted claims always
equal `holdersOwed + teamOwed`. PoC `test_F_split_dust_goes_to_team` asserts
`Δholders + Δteam == fee` and `Δholders == fee·7500/10000` on a 10,000 IMD buy
(fee 240e18 → 180e18 / 60e18, exact).

Launch-cap arithmetic: `spent = |delta.amount0()| + fee`, which is `(a-f)+f = a` for an exact-in buy
and `q+f` for an exact-out buy — in both cases the full IMD leaving the buyer's wallet, correctly.
`uint256(initBlock) + launchCapBlocks` and `uint256(launchStart) + launchCapSeconds` widen before
adding, so no `uint64` wrap. `launchBuys[tx.origin] + spent` is checked uint256.

`flush`: `if (tip > toTeam) tip = toTeam;` then `toTeam - tip` — cannot underflow.

---

## 5. PimdToken

`INITIAL_SUPPLY = 1_000_000_000e18 = 1e27`, `decimals = 18`. `_mint` is called once in the
constructor and solmate's `_burn` is never reachable, so `totalSupply == INITIAL_SUPPLY` forever.

`circulatingSupply() = INITIAL_SUPPLY - balanceOf[DEAD] - balanceOf[address(0)]`
**cannot underflow**: `Σ balanceOf == totalSupply == INITIAL_SUPPLY`, and `DEAD` and `address(0)` are
two distinct addresses, so `balanceOf[DEAD] + balanceOf[address(0)] ≤ INITIAL_SUPPLY`. No
double-count for the same reason — the two mapping slots are disjoint, and solmate's `transfer`
debits the sender and credits exactly one recipient. `totalBurned()` is the same sum and is
consistent with `circulatingSupply()` by construction (`totalBurned + circulatingSupply ==
INITIAL_SUPPLY` identically). **Both correct.**

---

## 6. Findings

### F-1 · HIGH · `tally` indexes past `holders.length`, wedging the epoch and freezing its IMD
`PimdEngine.sol:311-315` (and the escape hatch at `:248-261`)

`fire` snapshots `epochCount = holders.length`. `tally` then runs
`uint256 end = epochCount; for (uint256 i = start; i < end; ++i) { address a = holders[i]; … }`
with **no clamp against `holders.length`**. `prune` is deliberately permitted during `Phase.Tally`
(the NatSpec at :242-247 says so explicitly, as the escape hatch for a holder set too large for one
block) and it does `holders.pop()`. Nothing re-reads `holders.length`.

Trigger, with the harness config (`minBalance = 100_000e18`, `dripBps = 400`):

1. alice, bob, carol each hold 1,000,000e18 PIMD and are registered. `pot = 100,000e18` IMD.
2. 180 s pass; `fire()` → `drip = 100_000e18 · 400·180/(10_000·900) = 100_000e18 · 0.008 =
   800e18`. `pot -= 800e18`, `epochQuote = 800e18`, `phase = Tally`, `epochCount = 3`.
3. carol sends her bag away (or sells, or is the victim of a dust-down to below `minBalance`).
   Anyone calls `prune([carol])` → `holders.length = 2`, `epochCount` still `3`.
4. `tally(500)` passes `maxHolders >= epochCount`, sets `end = 3`, reaches `holders[2]` on a
   two-element array → **`Panic(0x32)`, array out of bounds.** No page size helps; `end` is
   `epochCount` regardless.

Consequence: `phase` is stuck at `Tally` forever. `fire()` reverts `WrongPhase`, `pay()` reverts
`WrongPhase`, `prune()` can only shrink further, and the 800e18 IMD in `epochQuote` is out of the
pot and unreachable. Recovery exists but is non-obvious and lossy: register fresh addresses until
`holders.length >= epochCount` again, each of which must itself hold `≥ minBalance` (1,000,000e18
PIMD on mainnet) **at the moment of its own `register` call** — so the bag has to be walked from
wallet to wallet, one transfer per address. The weights then come from a shuffled holder set.

Attack cost: one `prune` call. The precondition — a registered holder whose balance has fallen
below `minBalance` — arrives on its own the first time anybody sells out, and can be manufactured
by a holder who registers a `minBalance` bag and then moves it.

PoC: `test/pimd/ZZArith.t.sol::test_A_prune_during_tally_bricks_the_epoch`, passing, logs
`frozen epochQuote (wei IMD) 800000000000000000000`. (Independently reproduced by
`test/pimd/AuditProbe06.t.sol`, written by another agent in this swarm — same mechanism.) The
working tree's `// MUTANT` edit to line 311 does not change the outcome: with `maxHolders = 500`
the mutated `end = min(0+500, 3)` is still `3`.

This is a direct consequence of the earlier audit's finding-1 fix (see §7a): making the tally atomic
changed `end` from a page bound to the stale snapshot, and the clamp against the live array length
was not added with it.

### F-2 · LOW · Keeper tips are paid from the pot for epochs that distribute nothing
`PimdEngine.sol:281` and `:295`, `:336-340` and `:345`

`tipBudget = (drip * TIP_BUDGET_BPS) / BPS` is set **before** the
`if (drip != 0 && n != 0)` gate, and `_tip(fireTip)` runs unconditionally at the end of `fire`.
Likewise `tally`'s `_tip(tipPerHolder * (end - start))` runs after the `tw == 0` branch has handed
`epochQuote` straight back to the pot. So tips are paid out of holders' IMD in two states where
nothing is distributed:

* **No holders registered** (`n == 0`). Nothing opens, `lastFire` still advances, and
  `_tip(fireTip)` takes `min(fireTip, 0.05·drip)` from the pot every `minInterval`.
  Mainnet numbers: `drip(120 s) = 0.002·pot`, so the 5 % cap is `0.0001·pot`, which exceeds
  `fireTip = 0.05e18` for any pot above 500 IMD. Leak = **0.05 IMD per 120 s = 36 IMD/day**,
  permissionless, for as long as nobody is registered.
* **Nobody eligible yet** (`tw == 0`) — the whole first hour after any registration, because
  `tierBps(age < 1 hours) == 0`. Each `fire`+`tally` cycle costs the pot
  `fireTip + tipPerHolder·n`, capped at `0.05·drip`. Mainnet with 300 holders:
  `0.05 + 0.003·300 = 0.95 IMD` per 120-second cycle, 30 cycles in the first hour =
  **28.5 IMD paid to keepers while `totalDripped` stays 0**.

Measured: `test_B_fire_tips_forever_with_no_holders` — 10 fires on a 100,000e18 pot, zero holders:
`epoch() == 0`, `totalDripped() == 0`, keeper gained `200000000000000000` wei (0.2 IMD = 10 ×
`fireTip`), and the pot fell by exactly that. `test_C_tips_paid_while_nobody_is_eligible` — 25
fire+tally cycles inside the first hour with 2 holders: `totalDripped() == 0`, pot lost
`525000000000000000` wei (0.525 IMD = 25 × (0.02 + 2·0.0005)), keeper gained the same.

The 5 % cap *is* cadence-invariant (§2), so this is a bounded leak, not a drain: it can never exceed
5 % of what the curve would release over the same wall-clock time. But the cap is keyed to the
*notional* drip, not to an epoch that actually paid somebody, which is what the earlier audit's
finding 11 was about. See §7c.

### F-3 · LOW · `bind` does not pin `token_` to the hook's token, so the `uint128` bounds rest on an unchecked assumption
`PimdEngine.sol:185-198`

`bind` verifies `h.engine()`, `h.quote()` and `h.poolManager()` but never
`IPimdHookLike(hook_).token() == token_`. Every bound in casts #2, #7 and #8 is "PIMD's supply is
1e27". If `token` were ever a different ERC-20, the thresholds are concrete:

* `uint128(bal)` truncates for a balance `≥ 2^128 = 3.4028e38` (3.4e20 tokens at 18 dp).
* `uint128(w)` truncates first, at `bal ≥ 2^128·BPS/30_000 = 1.1343e38` — a truncated
  `weight` while `totalWeight` (uint256) keeps the full value, i.e. a holder's share collapses
  toward zero and the rest falls to `leftover`. Not theft, but a silent mis-split.
* `bal * tierBps` itself reverts (checked) above `1.1579e77/3e4 = 3.86e72`.

`bind` is one-shot and binder-only, so this is a deployment-integrity gap rather than an attack,
but it is the only thing standing between the cast table and a 1.1e11× safety margin. A one-line
`if (IPimdHookLike(hook_).token() != token_) revert BadConfig();` closes it. (The earlier audit's
finding 9 added the other three checks and stopped short of this one — §7e.)

### F-4 · LOW · `h.received += uint128(amt)` is the one cast whose bound belongs to someone else's token
`PimdEngine.sol:370`

`received` is `uint128`, so the counter saturates at `3.4028e38` wei = `3.4028e20` IMD at 18
decimals. Two distinct behaviours at the boundary, and it is worth being precise about which:

* the **cast** `uint128(amt)` would silently truncate for a single payout `≥ 2^128`;
* the **`+=`** is checked on a `uint128` storage field, so a cumulative breach **reverts**, taking
  the whole `pay` page with it and wedging the epoch exactly as F-1 does.

Neither can misdirect IMD — `_send(a, amt)` uses the full `uint256 amt` and runs before the counter
update — so the worst case is a bricked epoch plus a wrong stat. IMD's supply is not in this repo;
if it is below 3.4e20 tokens (it will be) this is informational. Record the threshold.

### F-5 · INFO · The tax floors to zero on sub-42-wei trades, and always rounds toward the trader
`PimdHook.sol:281` and `:319`

Exact thresholds where `fee == 0`:

| direction | formula | `fee == 0` for |
|---|---|---|
| exact-in buy | `amt·240/10000` | `amt ≤ 41` wei |
| exact-in sell | `amt·560/10000` | `amt ≤ 17` wei |
| exact-out buy | `amt·240/9760` | `amt ≤ 40` wei |
| exact-out sell | `amt·560/9440` | `amt ≤ 16` wei |

PoC `test_E_small_swaps_pay_no_tax`: a 41-wei buy moves `totalTaxed` by 0. Above those thresholds
the floor costs the protocol at most 1 wei of IMD per swap. Not farmable — one V4 swap's gas is
many orders of magnitude more than 1e-18 IMD — but it does mean `fee > 0` is not a guaranteed
consequence of a non-zero swap, which the code already handles correctly (`if (fee > 0)` guards both
the `mint` and `_split`, and `toBeforeSwapDelta(0,0)` is `ZERO_DELTA`, which v4-core short-circuits).

### F-6 · INFO · The 75/25 split's dust goes to the team
`PimdHook.sol:496-498`

`toHolders = ⌊3·fee/4⌋`, `teamOwed += fee - toHolders = ⌈fee/4⌉`. The team's excess over an exact
25 % is `(fee mod 4)/4`: 0.75 wei at `fee ≡ 1 (mod 4)`, 0.5 at `≡ 2`, 0.25 at `≡ 3`, 0 at `≡ 0`.
Maximum 0.75 wei of IMD per swap. Total across every swap the pool will ever see is a rounding
error on a rounding error; noted only because the brief asks who gains every dust.

### F-7 · INFO · Two unbounded-config multiplications can brick `tally`
`PimdEngine.sol:345`, `:393`, `:281`

`_tip(tipPerHolder * (end - start))` is a checked `uint256` multiply with `tipPerHolder` an
unvalidated constructor immutable (the constructor bounds only `dripBpsPerPeriod` and `maxCatchup`).
`tipPerHolder > 1.1579e77 / epochCount` makes `tally` revert permanently. Same shape for
`drip * TIP_BUDGET_BPS` (needs `drip > 1.1579e73`, unreachable). `minInterval`, `minBalance`,
`fireTip` and `tipPerHolder` are all unchecked; `minBalance == 0` in particular would let `register`
accept any address and grow the atomic `tally` without bound. Deployment hygiene, not an attack.

### F-8 · INFO · A dust pot produces endless epochs that pay nobody
`PimdEngine.sol:472`, `:285`, `:368`

Because `released ≥ 1` whenever `p ≥ 1` and `elapsed ≥ 1` (§2), a pot of a few wei still satisfies
`drip != 0`, so `fire` opens a full epoch with `epochQuote` of 1–2 wei. `pay` then computes
`mulDiv(1, w, tw) == 0` for every holder but at most one, `continue`s on all of them, and returns
the lot to the pot via `leftover`. The cycle repeats every `minInterval` forever. Gas waste only —
no IMD is lost, and `_tip` pays nothing because `tipBudget = ⌊1·500/10000⌋ = 0`.

### F-9 · INFO · `initBlock == 0` doubles as the "not launched" sentinel for `beforeSwap`
`PimdHook.sol:257`, `:272`

`initBlock = uint64(L2Block.number())` and `beforeSwap` gates on `if (initBlock == 0) revert
NotLaunched()`. Two ways that conflates a value with a flag: a chain where `L2Block.number()` is 0
at initialization, or a `L2Block.number()` that is an exact multiple of `2^64`. Either leaves the
pool permanently unswappable with no way to re-initialize (`launched` is already `true`).
`L2Block.number()` falls back to `block.number`, and it decodes whatever word `address(100)`
returns, so the value is not locally bounded — but on any chain this ships to it is. Prefer the
existing `launched` bool for the gate.

### F-10 · INFO · The blend over-credits because it dilutes against `lastBal`, not the interval minimum
`PimdEngine.sol:319-325`

`age_new = last · age_old / bal` uses `last = h.lastBal`, the balance **at the previous tally**. The
engine cannot see what happened in between, so a holder who goes to zero and comes back above
`lastBal` is treated identically to one who simply bought more. Numbers: `last = 1,000,000` PIMD at
age 14 d (3×). Sell the lot, re-buy 1,050,000 before the next tally. The tally sees
`bal = 1.05e6 > last = 1e6`, blends to `age = 1e6·1,209,600/1.05e6 = 1,152,000` s = 13.33 days →
**2× band**, weight `2.1e6`, against the `0` the documented rule ("selling restarts the clock")
implies. The round trip through the pool costs 5.6 % + 2.4 % + LP fees, so it is not a cheap farm.

One correction to the earlier audit's finding 8, which priced this at "the 5.6 % and 2.4 % taxes
plus pool fees": a **PIMD transfer is untaxed** (`PimdToken` has no transfer hook of any kind), so
the `bal == last` variant — move the whole bag to a fresh wallet and back inside one tally interval
— is free, not 8 %. It gains nothing on its own (doing nothing preserves the streak equally), but it
means the enforced rule is "your balance at tally N must not be below your balance at tally N−1",
with no cost attached, rather than "do not move tokens".

### F-11 · INFO · Tier-ladder and `minBalance` boundaries, checked for off-by-one
`PimdEngine.sol:398-405`, `:231`, `:253`, `:328`

All strict-`<` bands, so the thresholds are inclusive-from-above: age exactly 3600 s → 5,000;
exactly 604,800 s (7 d) → **20,000**, not 15,000. PoC `test_G` doubles a 14-day bag and lands on
`age == 604800` exactly, measuring `tierBps == 20_000`. Correct and self-consistent, just worth
writing down because the 7-day case sits on the boundary for the most natural blend (doubling at 14
days), and the NatSpec ladder ("to a week 1.5x · to two weeks 2x") reads the other way at a glance.

`register` uses `bal < minBalance → skip` and `prune` uses `balanceOf >= minBalance → skip`, so the
two agree on exactly-`minBalance` being *in*. No window where an address is simultaneously
registerable and prunable. A holder at exactly `minBalance` in the 0.5× band gets
`w = minBalance/2`, which is `5e22` or `5e23` wei of weight — nowhere near rounding to zero.

### F-12 · INFO · `beforeSwap`'s `int128` safety is borrowed from v4-core, with zero margin
`PimdHook.sol:282` and `:288`

Stated here as a standing invariant rather than a bug, because it is the kind of thing a refactor
breaks silently. The cast at :288 is safe **only** because the `mint` at :282 runs first and
v4-core's `SafeCast.toInt128(uint256)` rejects `x >= 1 << 127`. Reorder those two lines, make the
`mint` conditional on anything else, or batch the mints, and `fee ∈ [2^127, 2^128)` reaches
`int128(uint128(fee))` as a **negative** specified delta — which v4-core credits to the swapper and
debits from the hook. By contrast the cast at :321 is bounded locally (cast #22: `quoteAmt` is an
`int128`, so `fee ≤ 9.53e36`) and needs no such help. A local
`if (fee > uint256(uint128(type(int128).max))) revert;` before :288 would make the file
self-contained.

---

## 7. Verification of the earlier audit's arithmetic-related fixes

(`pulse-imd/swarm/audit/AUDIT-1b073df.md`, unreviewed.)

**a) Finding 1 — paged tally weighing live balances. Fix: atomic tally.
Arithmetically sound, but it introduced F-1.**
`if (start != 0 || maxHolders < epochCount) revert TallyMustBeWhole(epochCount);` does close the
original hole exactly: one call means one balance snapshot, nothing can move tokens mid-loop, so
`Σwᵢ = tw` holds and the N-wallet double count is gone. The arithmetic of the fix is right. What
came with it is that `end` is now the stale `epochCount` rather than a page bound, and no clamp
against the live `holders.length` was added — while `prune` remains legal during `Tally` as the
fix's own escape hatch. That is F-1, HIGH.

**b) Finding 4 — tax charged on the specified amount, not the filled one. Fix: `PartialFill`.
Correct, verified against v4-core's real delta semantics.**
`wanted = amountSpecified < 0 ? specified - fee : specified + fee` is right in both specified
cases, and only because the hook's `afterSwap` receives the **raw** `swapDelta` (v4-core
`Hooks.afterSwap`, lines 289–300, passes `swapDelta` to the callback and subtracts `hookDelta`
afterwards). Exact-in buy: raw `amount0 = -(a-f)`, `wanted = a-f` ✓. Exact-out sell: raw
`amount0 = +(a+f)`, `wanted = a+f` ✓. Had the delta been post-subtraction, every exact-in buy
would revert `PartialFill(a-f, a)` — worth stating, because it is the whole correctness case.
`specified - fee` cannot underflow (`fee = a·bps/BPS < a`); `specified + fee` cannot overflow
(`specified ≤ 2^255-1`, `fee < 2^127`). The `specified != 0` sentinel is sound because v4-core
rejects `amountSpecified == 0` up front, so a taken branch always stores `≥ 1`, and `afterSwap`
zeroes both transient slots on every swap so a later untaxed swap in the same transaction reads 0.

**c) Finding 11 — `fire` tipping from the pot with nobody registered. Fix: `tipBudget`.
Bounds the leak, does not remove it.**
`tipBudget = drip·500/BPS` is cadence-invariant (§2: whole periods compound multiplicatively and
sub-period firing releases strictly less), so the tip cannot be accelerated by spamming `fire`, and
total tips can never exceed 5 % of what the curve releases over the same wall-clock period. That
much is sound. But the budget is keyed to the *notional* drip and is set before the
`drip != 0 && n != 0` gate, so `fire` still tips when no epoch opens and `tally` still tips when
`tw == 0`. Measured leak with mainnet config: 36 IMD/day with no holders; 28.5 IMD across the first
hour with 300 holders and nothing paid out. That is F-2.

**d) Finding 15 — `totalBurned`/`circulatingSupply` ignoring `address(0)`. Fix: include it.
Correct, and underflow-free.** See §5. `totalSupply` is immutable at `INITIAL_SUPPLY`, the two
mapping slots are disjoint, so `balanceOf[DEAD] + balanceOf[0] ≤ INITIAL_SUPPLY` and there is no
double count. `totalBurned() + circulatingSupply() == INITIAL_SUPPLY` identically.

**e) Finding 9 — `bind` not checking the hook. Fix: three identity checks.
Correct as far as it goes; the token is still unpinned.** `h.engine()`, `h.quote()` and
`h.poolManager()` are verified; `h.token()` is not, which is F-3 — and the token is precisely what
every `uint128` bound in the cast table depends on.

**f) Finding 2 — `beforeInitialize` not checking that currency0 is IMD. Fix:
`if (c0 != quoteToken()) revert WrongQuoteCurrency(c0);`. Correct, and load-bearing.** With both
`c1 != address(token)` and `c0 != quoteToken()` enforced, the "IMD is currency0" assumption behind
all four fee derivations in §4 is now a checked invariant rather than an assumption. I re-derived
all four directions against the real v4-core accounting and they are consistent: gross tax 2.4 % on
both buy forms and 5.6 % on both sell forms, with `hookDelta` landing on `amount0` in every case.

---

## 8. Checked and clean (negative results)

Worth recording so the next pass does not redo them.

* **`_probe`'s assembly-assigned `address` is masked before comparison.** The documented inline-
  assembly hazard (a value narrower than 256 bits may carry dirty high bits) would let a rogue pair
  return `0x8000…0000 | uint160(PIMD)` from `token0()`, defeat `_probe(a, …) == t`, and collect
  drips its LPs could capture. Tested: `ZZArith2.t.sol::test_H_isPool_misses_a_dirty_pair` builds
  exactly that contract (returned word
  `0x8000000000000000000000003131235fa26717447e9c03adf3cc7f80122d293f`) and `register` **still**
  skips it — solc 0.8.26 cleans the operand. `test_H_isPool_sees_a_clean_pair` confirms the honest
  case. **Not a bug.**
* **No `unchecked` block anywhere in scope** (confirmed by the hot-spot scan and by reading all
  1,098 lines), so every arithmetic overflow outside the casts reverts.
* **Unary minus on `int128`/`int256` is checked in 0.8.26**, so `-type(int128).min` and
  `-type(int256).min` revert rather than wrapping — relevant at Hook:279, :309, :317, :333.
* **No `block.timestamp` subtraction can underflow.** `block.timestamp - lastFire` (Engine:278,
  :439): `lastFire` is only ever assigned `block.timestamp`, and `fire` requires `bound`.
  `nowTs - h.streakStart` (Engine:328): `streakStart` is assigned `block.timestamp` at register, at
  a decrease, or the blend, which is a weighted mean of two values `≤ nowTs`; the blend is written
  *before* the read in the same iteration, so the ordering is safe too. `holderInfo`'s subtraction
  (:429) is inside a ternary guarded by `registered_`, and `block.timestamp - 0` is harmless anyway.
* **No insolvency in the `pot` / `epochQuote` / balance ledger.** Mid-`pay` the IMD balance is
  `pot + epochQuote - epochPaidQuote`, so the ledger's `pot` is exactly backed and `_tip`'s
  `if (pot < amt) return` cannot overdraw. At the end of `pay`,
  `leftover = total - epochPaidQuote` reconciles to the wei: `pot_final = pot_running + leftover`
  equals the real balance. `_book` only ever runs in `Phase.Idle`, where `epochQuote == 0` on every
  path into Idle, so income is never double-counted and a `seed` is never booked twice.
* **No double drip and no cadence exploit on `fire`.** With `minInterval == 0`, repeat calls in the
  same block give `elapsed == 0 → drip == 0 → tipBudget == 0`, so nothing is released and nothing
  is tipped; across blocks the multiplicative curve makes the total time-integral correct.
* **No duplicate entry in `holders`.** `register` skips `index1 != 0`; `prune`'s swap-and-pop is
  correct including the `a == last` case (the `delete` runs after the index write) and when the same
  address appears twice in one `prune` call (`idx1 == 0` on the second pass).
* **`pay(0)` is a free no-op, not a free tip**: `end == start`, loop body never runs,
  `_tip(tipPerHolder * 0) → _tip(0) → return`.
* **No weight survives an epoch.** `h.weight = 0` is written before the `amt == 0 → continue`, so
  every weight in `[0, epochCount)` is cleared by the time `pay` completes.
* **`FullMath.mulDiv` cannot overflow here** (512-bit intermediate, and `require(denominator >
  prod1)` also rules out `tw == 0`, which `tally`'s `tw == 0` branch already prevents by routing to
  `Idle`).
* **`uint32`/`uint128` constants in the hook widen before use**: `uint256(launchStart) +
  launchCapSeconds`, `uint256(initBlock) + launchCapBlocks`, `total > launchBuyCap`,
  `uint256 tip = callerTip`.
