// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title L2Block
/// @notice On Arbitrum and Arbitrum Orbit chains `block.number` returns the parent-chain (L1) block number,
///         which advances about every 12 seconds and is shared by many L2 blocks. Anything that means
///         "N L2 blocks" must read the ArbSys precompile instead. Falls back to `block.number` anywhere the
///         precompile does not answer (local tests, other EVM chains, forks that cannot run precompiles).
library L2Block {
    address internal constant ARBSYS = address(100);

    /// @dev Gas is capped: on forks and non-Arbitrum EVMs address(100) may hold non-executable bytes that would
    ///      otherwise swallow all forwarded gas. The real precompile needs far less than this.
    uint256 internal constant ARBSYS_GAS = 20_000;

    function number() internal view returns (uint256) {
        (bool ok, bytes memory ret) = ARBSYS.staticcall{gas: ARBSYS_GAS}(abi.encodeWithSignature("arbBlockNumber()"));
        if (!ok || ret.length < 32) return block.number;
        return abi.decode(ret, (uint256));
    }
}
