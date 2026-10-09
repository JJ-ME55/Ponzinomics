# Ponzinomics ($PIMD)

A fixed-supply token paired with **IMD**. Every trade pays a tax **in IMD**, and most of that IMD is pushed
straight into holders' wallets, weighted by how long they have held.

- **2.4% on buys, 5.6% on sells**, taken in IMD by the hook. The pool charges its own 1.25% on top, so a
  trade costs about 3.65% to buy and 6.85% to sell all in
- the hook's tax splits **75% holders / 25% team**. There is no buy-and-burn in these contracts
- holders are paid **in IMD**, pushed to their wallets, nothing to claim and nothing to connect
- **hold longer, get more**: 0x under an hour, then 0.5x / 1x / 1.5x / 2x / 3x at 1 hour, 1, 3, 7 and 14 days
- **one billion supply, fixed, for ever.** No mint function exists and no burn function either: `totalSupply`
  is 1,000,000,000e18 at construction and still is. Burning is a plain transfer to `DEAD`, which is just as
  final and leaves the supply figure alone

## The three contracts

| | what it is |
|---|---|
| [`PimdToken`](src/pimd/PimdToken.sol) | a plain solmate ERC-20. No owner, no mint, no burn, no pause, no blacklist, no transfer tax, no rebase |
| [`PimdHook`](src/pimd/PimdHook.sol) | the Uniswap V4 hook. Taxes every trade in IMD as ERC-6909 claims on the quote side, splits it 75/25, and refuses every liquidity withdrawal for ever |
| [`PimdEngine`](src/pimd/PimdEngine.sol) | holds the holders' IMD, releases it on a time curve and pushes it out by balance x hold-streak |

The IMD launch factory deploys the token and the hook and opens the pool itself. The token's supply mints to
`msg.sender` — the factory — which seeds the pool single-sided with all of it. The liquidity position belongs
to the factory, and `beforeRemoveLiquidity` refuses every negative `liquidityDelta` for ever, from any caller
including the factory and the hook, while allowing a zero delta so the pool's own fee collection still works.

## There is no owner

Not "ownership renounced after the fact" — there is no owner role in any of the three contracts. No admin, no
pause, no setter, no upgrade path, no proxy. What is fixed at construction and can never change:

- `team`, where the 25% goes
- `PimdEngine.binder`, which may call `bind()` exactly once
- `PimdEngine.keeper`, the addresses that may call `tally()`

`bind` is the only one-shot power and it is spent during the launch. It is a constructor argument rather than
`msg.sender` **on purpose**: these contracts are built to be deployed by somebody else's wallet without that
wallet gaining anything (`test_a_stranger_can_deploy_it_and_hold_nothing`).

**One step is not permissionless, and it matters.** `fire`, `pay`, `register`, `prune` and `abortEpoch` are
open to anyone. `tally` — weighing an epoch — is restricted to the keeper addresses. It has to be: weighing
reads `balanceOf`, and an address that could choose the instant it was read could stand in front of that read
holding a bag borrowed for the length of one transaction. Taking the choice of instant away is the only thing
that closes it. The cost, stated plainly: **if every keeper is lost, no epoch is ever weighed again.** Nothing
is stolen and nothing is trapped — anyone can still release a stalled epoch, which returns its IMD to the pot,
and the pot goes on accruing — but the drip stops and nobody can appoint a replacement.

## What an auditor should look at first

**The pool only works if IMD sorts below PIMD.** Everything in the hook assumes IMD is `currency0`. The deploy
mines a CREATE2 salt so the token's address lands above IMD's, and `beforeInitialize` refuses to open a pool
that gets it backwards, along with a second pool on this hook, a fee tier outside the permitted set, a pairing
that is not PIMD, or an opening tick more than 300 from `LAUNCH_TICK`.

**The engine refuses to run while the PoolManager is unlocked.** Weights are read from `balanceOf`, and inside
a V4 unlock anyone can hold an enormous balance for the length of one callback. `fire`, `tally`, `pay`,
`register` and `prune` all check the PoolManager's transient unlock flag and revert with `PoolUnlocked`.

**`tally` weighs the whole set in one call** and refuses a partial one (`TallyMustBeWhole`). That is what stops
one bag being counted once per wallet it is moved through: every holder is read once, at the same instant, and
nothing can move in between. It is also why the holder set is bounded — see `maxHolders` below.

Also deliberate: every IMD transfer out is a gas-capped low-level call whose failure is caught and logged, so
one address that IMD refuses cannot stall everybody else's payout, and its share returns to the pot.

## Known limits, on purpose

These are documented rather than fixed. The contracts are immutable, so they are permanent.

- **Weight is balance times tier, and a balance can be rented.** Holding a borrowed bag across the hour it
  takes to leave tier 0, and still holding it at the next count, earns like any other bag. The ladder is the
  only obstacle. There is nowhere to borrow PIMD at launch; a lending market or a second pool appearing is
  what would change that.
- **A contract that cannot forward an IMD payout can be registered by a stranger** and its share is then
  stuck. The exclusion list at `bind` covers the token, IMD, the hook, the launch factory, the PoolManager,
  the engine, the team, the zero address, `DEAD` and anything the binder names; precompiles are refused at
  `register`. It cannot cover a locker or wrapper that acquires PIMD later. Registration stays open to anyone
  so that a keeper can enrol holders who never send a transaction themselves.
- **The keeper tip floors order the draw, they do not ration between actors.** One party holding several roles
  collects every share it turns up for. The 5% `TIP_BUDGET_BPS` ceiling is what bounds it.
- **`fireTip` is a ceiling, not a guarantee** — the fire floor caps it at a tenth of the epoch's budget.
- **`pay` wants a concrete page size.** `pay(type(uint256).max)` works on the first page and reverts on later
  ones; `pay(700)` always works. Keepers should pass a number.
- **`tipBudget()` and `epochTipBudget()` read stale between epochs.** Nothing can spend a stale budget, but
  do not present either as live.

## Tests

```bash
forge test                                                        # 85 local
forge test --match-path "test/pimd/PimdFork.t.sol"                # 6 against live state
```

The fork tests run the whole protocol against the **real IMD contract** and the real PoolManager: a buy pays
exactly 2.4% in real IMD, a sell 5.6%, `flush` moves real IMD, and a real IMD payout lands in a wallet. They
are parameterised, so the same six run against either chain's IMD.

`test/pimd/Gas.t.sol` reports what one epoch costs, which is how `maxHolders` is chosen.

## Deploying

The script deploys **only the engine**. The token, the hook and the pool come from the IMD launch factory.

```bash
PRIVATE_KEY=0x… forge script script/DeployPimd.s.sol:DeployPimd \
  --rpc-url robinhood            # add --broadcast to send it
```

It prints the parameters it actually deployed, so they can be read against intent, and refuses to drift from
an address given as `EXPECT_ENGINE`. Then:

1. write the engine's address into `PimdHook.ENGINE_ADDRESS` and push
2. the launch runs against that commit, deploying the token and hook and opening the pool
3. the binder calls `engine.bind(token, hook, [distributor])`

**The airdrop distributor must be in that list**, or it earns drips nobody can claim — as must any other
holder known at launch that cannot forward IMD. `bind` is one-shot, so that list cannot be added to later.

## Parameters

| | Robinhood Chain (production) | testnet |
|---|---|---|
| IMD | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` | — |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | — |
| opening tick | 129,000 ± 300, i.e. 2.5e-6 IMD per PIMD — a 2,500 IMD opening cap on a billion supply | same |
| drip | 1.5% of the pot per 15 minutes | 4% |
| minimum between epochs | 15 minutes | 2 minutes |
| catch-up clamp | 6 hours | 1 hour |
| minimum paid bag | 1,000,000 PIMD (0.1%) | 100,000 PIMD |
| holder set bound | 700, under a constructor ceiling of 800 | — |
| keeper tips | 0.05 IMD to fire, 0.003 IMD per holder, all of it inside 5% of the epoch's drip | 0.01 / 0.0001 |
| launch window cap | 25 IMD per `tx.origin` for 600 seconds or 6,000 blocks, ceiling 1 hour | same |

The opening tick is **denominated in IMD, not in dollars**, so it does not need recomputing against IMD's
price on the day. `maxHolders` is 700 because `tally` weighs the whole set in one transaction and costs about
37k gas a holder in the worst case, against the 32,000,000 `maxTxGasLimit` this chain's ArbOS reports — not
the 2^50 placeholder in the block header.

## Licence

MIT.
