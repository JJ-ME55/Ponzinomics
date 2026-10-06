// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title PimdToken
/// @notice Ponzinomics ($PIMD). A plain, fixed-supply ERC-20: one billion units minted once at construction
/// and never again. There is no owner, no mint function, no pause, no blacklist, no transfer tax and no
/// rebase. Supply only ever falls, because `burn` is the only thing that moves `totalSupply` after deploy.
///
/// @dev Deliberately dumb. Everything that makes Ponzinomics interesting lives in the hook (which taxes trades
/// in IMD) and the engine (which pays that IMD out by hold-streak). Holders' streaks are read from `balanceOf`
/// by the engine, so this contract needs no hooks, no holder registry and no per-transfer bookkeeping: a
/// transfer of PIMD costs what a transfer of any ERC-20 costs, and nothing here can stop one.
///
/// v1's token minted emissions, which is what made scanners call PULSE mintable and made balances move with no
/// transfer behind them. This one cannot mint, so neither is true.
contract PimdToken is ERC20 {
    /// @notice Total supply at construction: 1,000,000,000 PIMD. Never increases.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000e18;

    /// @notice Lifetime PIMD destroyed, for the site's burn counter.
    uint256 public totalBurned;

    event Burned(address indexed from, uint256 amount);

    error BadReceiver();

    /// @param receiver gets the entire supply. On a real launch this is the hook, which puts all of it into the
    /// single-sided range and burns whatever dust the position maths leaves behind.
    constructor(address receiver) ERC20("Ponzinomics", "PIMD", 18) {
        if (receiver == address(0)) revert BadReceiver();
        _mint(receiver, INITIAL_SUPPLY);
    }

    /// @notice Destroys `amount` from the caller. Used by the hook after it buys PIMD back with the burn slice
    /// of the tax, and open to anyone who wants to burn their own.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        unchecked {
            totalBurned += amount;
        }
        emit Burned(msg.sender, amount);
    }

    /// @notice Destroys `amount` from `from`, spending the caller's allowance.
    function burnFrom(address from, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _burn(from, amount);
        unchecked {
            totalBurned += amount;
        }
        emit Burned(from, amount);
    }

    /// @notice Supply that was minted at construction and has not been burned. Same as `totalSupply`; kept as a
    /// named getter so the site and the swarm's oracle recipes have one obvious thing to read.
    function circulatingSupply() external view returns (uint256) {
        return totalSupply;
    }
}
