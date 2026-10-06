# Ponzinomics ($PIMD)

A fixed-supply token paired with **IMD**. Every trade pays a tax **in IMD**, and most of that IMD is pushed
straight into holders' wallets, weighted by how long they have held without selling.

- **3% on buys, 7% on sells**, taken in IMD by the hook
- split **60% holders / 20% buy-and-burn / 20% team**
- holders are paid **in IMD**, pushed to their wallets, nothing to claim and nothing to connect
- **hold longer, get more**: 0x under an hour, 0.5x to a day, then 1x / 1.5x / 2x / 3x at 1, 3, 7 and 14 days
- selling or sending tokens out restarts your streak; buying more blends it by size
- **one billion supply, fixed.** No mint function exists. Supply only falls, because the burn slice buys PIMD
  off the market and destroys it

## The three contracts

| | what it is |
|---|---|
| [`PimdToken`](src/pimd/PimdToken.sol) | a plain solmate ERC-20. No owner, no mint, no pause, no blacklist, no transfer tax, no rebase |
| [`PimdHook`](src/pimd/PimdHook.sol) | the Uniswap V4 hook. Launches the pool single-sided, taxes every trade in IMD, splits it three ways, buys PIMD back and burns it |
| [`PimdEngine`](src/pimd/PimdEngine.sol) | holds the holders' IMD, releases it on a time curve and pushes it out by balance x hold-streak |

## There is no owner

Not "ownership renounced after the fact" — there is no owner role in any of the three contracts. No admin, no
pause, no setter, no upgrade path, no proxy. Three things are fixed forever at construction:

- `team`, where the 20% goes
- `PimdHook.launcher`, which may call `launch()` exactly once
- `PimdEngine.binder`, which may call `bind()` exactly once

Both of those one-shot powers are spent during the launch itself, after which nobody can change anything.
They are constructor arguments rather than `msg.sender` **on purpose**: these contracts are built to be
deployed by somebody else's wallet without that wallet gaining anything. There is a test for exactly that
(`test_a_stranger_can_deploy_it_and_hold_nothing`).

The token's whole supply mints directly to the hook and never passes through a wallet. The liquidity position
is held by the hook and cannot be withdrawn by anyone, including us.

## Two things an auditor should look at first

**The pool only works if IMD sorts below PIMD.** Everything in the hook assumes IMD is `currency0`, exactly as
native ETH was in the version this is ported from. The deploy script mines a CREATE2 salt so the token's
address lands above IMD's, and `launch()` reverts with `BadCurrencyOrder` if it somehow does not.

**Payouts refuse to run while the PoolManager is unlocked.** Weights are read from `balanceOf`, and inside a V4
unlock anyone can hold an enormous balance for the length of one callback. `fire`, `tally` and `pay` all check
the PoolManager's transient unlock flag and revert with `PoolUnlocked`. Three tests drive this from inside a
real unlock.

Also deliberate: every IMD transfer out is a gas-capped low-level call whose failure is caught and logged, so
one address that IMD refuses cannot stall everybody else's payout, and its share returns to the pot.

## Tests

```bash
forge test                                                        # 32 local tests
forge test --match-path "test/pimd/PimdFork.t.sol" --fork-url robinhood   # 6 against live state
```

The fork tests run the whole protocol against the **real IMD contract** and the real PoolManager: a buy pays
exactly 3% in real IMD, a sell pays 7%, `flush` moves real IMD and cuts `totalSupply`, and a real IMD payout
lands in a wallet. They are parameterised, so the same six run against either chain's IMD:

```bash
IMD=0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7 \
POOL_MANAGER=0x000000000004444c5dc75cB358380D2e3dE08A90 \
START_TICK=146460 TICK_LOWER=100440 FORK_RPC=https://eth.drpc.org \
forge test --match-path "test/pimd/PimdFork.t.sol"
```

`test/pimd/Gas.t.sol` reports what one epoch costs, which is how the payout cadence is chosen per chain.

## Deploying

```bash
PRIVATE_KEY=0x… TEAM_MULTISIG=0x… forge script script/DeployPimd.s.sol:DeployPimd \
  --fork-url robinhood            # add --broadcast to send it
```

One script: deploy the engine, mine the hook for its V4 permission bits, mine the token's salt so it sorts
above IMD, deploy both, open the pool single-sided with the entire supply, bind the engine, and write
`deployments.pimd.<chainId>.json`. It asserts its own end state rather than assuming it, including that the
pool opened at the intended tick and that the hook kept nothing.

Set `LAUNCH_ADMIN` when a different wallet is doing the deploying. The script then deploys only, checks that
the one-shot powers and the fee wallet landed where they were told to, and prints the two calls `LAUNCH_ADMIN`
must make to finish:

```
1. hook.launch(token, tickLower, startTick, 60)
2. engine.bind(token, hook)
```

## Parameters

| | Robinhood Chain | Ethereum mainnet |
|---|---|---|
| IMD | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| opening market cap | ~$5k (start tick 147780) | ~$5k (start tick 146460) |
| range | 100x, up to roughly $500k | same |
| drip | 4% of the pot per 15 min | 1.5% per 15 min |
| catch-up clamp | 1 hour | 6 hours |
| minimum paid bag | 100,000 PIMD (0.01%) | 1,000,000 PIMD (0.1%) |

The opening tick is priced in IMD, so it is recomputed against IMD's price on the day and passed as
`START_TICK`. The payout cadence is a keeper policy, not a contract rule: the contract only enforces a two
minute floor between epochs.

## Licence

MIT.
