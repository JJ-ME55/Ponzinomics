// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PimdBaseTest} from "./PimdBase.t.sol";
import {PimdEngine} from "../../src/pimd/PimdEngine.sol";
import {console2} from "forge-std/Test.sol";

/// An honest pair: reports PIMD as token0 with a clean word. _isPool must see it.
contract HonestPair {
    address public immutable t;

    constructor(address t_) {
        t = t_;
    }

    function token0() external view returns (address) {
        return t;
    }

    function token1() external view returns (address) {
        return address(0);
    }
}

/// The same pair, but token0() returns the PIMD address with dirty high-order bits. The ABI says the
/// top 12 bytes of an address return are zero; this one sets them. Any caller that masks reads PIMD.
contract DirtyPair {
    uint256 private immutable word;

    constructor(address t_) {
        word = uint256(uint160(t_)) | (uint256(1) << 255);
    }

    fallback() external {
        uint256 w = word;
        assembly {
            mstore(0, w)
            return(0, 32)
        }
    }
}

contract ZZArith2 is PimdBaseTest {
    function test_H_isPool_sees_a_clean_pair() public {
        _pastInit();
        HonestPair p = new HonestPair(address(token));
        token.transfer(address(p), 1_000_000e18);
        _register(address(p));
        // register() skips pool-shaped holders outright
        (bool reg,,,,) = engine.holderInfo(address(p));
        assertFalse(reg, "clean pair must be refused");
    }

    function test_H_isPool_misses_a_dirty_pair() public {
        _pastInit();
        DirtyPair p = new DirtyPair(address(token));
        (, bytes memory ret) = address(p).staticcall(abi.encodeWithSignature("token0()"));
        console2.log("token0() returns word:");
        console2.logBytes32(abi.decode(ret, (bytes32)));
        console2.log("low 20 bytes == PIMD:", address(uint160(uint256(abi.decode(ret, (bytes32))))) == address(token));

        token.transfer(address(p), 1_000_000e18);
        _register(address(p));
        (bool reg,,,,) = engine.holderInfo(address(p));
        console2.log("dirty pair registered:", reg);

        // if it registered, it also collects a real drip
        if (reg) {
            imd.mint(address(this), 100_000e18);
            imd.approve(address(engine), type(uint256).max);
            engine.seed(100_000e18);
            vm.warp(block.timestamp + 2 days);
            _runEpoch();
            console2.log("IMD paid to the pool:", imd.balanceOf(address(p)));
            assertGt(imd.balanceOf(address(p)), 0, "a pool collected a drip");
        }
    }
}
