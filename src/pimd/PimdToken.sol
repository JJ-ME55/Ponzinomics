// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title PimdToken
/// @notice Ponzinomics ($PIMD). A plain, fixed-supply ERC-20: one billion units minted once at construction,
/// to whoever deploys it, and never again. No owner, no mint, no burn, no pause, no blacklist, no transfer
/// tax, no rebase and no upgrade path. `totalSupply` is 1,000,000,000e18 at construction and is still
/// 1,000,000,000e18 forever: nothing in this contract can move it.
///
/// @dev Deliberately dumb. Everything that makes Ponzinomics interesting lives in the hook (which taxes
/// trades in IMD) and the engine (which pays that IMD out by hold-streak). Holders' streaks are read from
/// `balanceOf` by the engine, so this needs no hooks, no registry and no per-transfer bookkeeping: a
/// transfer of PIMD costs what a transfer of any ERC-20 costs, and nothing here can stop one.
///
/// There is no constructor argument because the launch factory deploys this and then moves the supply
/// itself: most of it into the pool single-sided, the rest where the launch says.
///
/// Burning is a transfer to `DEAD` rather than a `burn` function, which is why there is no `burn` function.
/// A burn function makes `totalSupply` variable, and a launched token's supply has to be fixed. The economics
/// are identical: tokens at `DEAD` are unspendable by anyone, forever, because nobody holds its key.
///
/// v1's token minted emissions, which is what made scanners call PULSE mintable and made balances move with
/// no transfer behind them. This one cannot mint, so neither is true.
contract PimdToken is ERC20 {
    /// @notice Total supply at construction, and for the life of the contract: 1,000,000,000 PIMD.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000e18;

    /// @notice Where burned PIMD goes. Unspendable: no key exists for it.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    constructor() ERC20("Ponzinomics", "PIMD", 18) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @notice Lifetime PIMD destroyed, for the site's burn counter. Anyone can verify it: it is just the
    /// balance sitting at an address nobody can spend from.
    function totalBurned() external view returns (uint256) {
        return balanceOf[DEAD];
    }

    /// @notice Supply that is still spendable by somebody. `totalSupply` never falls, so this is the number
    /// that matters for scarcity, and the one the site and the oracle recipes should read.
    function circulatingSupply() external view returns (uint256) {
        return INITIAL_SUPPLY - balanceOf[DEAD];
    }
}
