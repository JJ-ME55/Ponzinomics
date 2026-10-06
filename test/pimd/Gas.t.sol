// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PimdBaseTest} from "./PimdBase.t.sol";
import {console2} from "forge-std/Test.sol";

/// What one epoch actually costs, so the keeper budget can be worked out per chain.
contract GasTest is PimdBaseTest {
    function test_epoch_gas_for_100_holders() public {
        _pastLaunchCap();
        uint256 n = 100;
        address[] memory list = new address[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = address(uint160(0x20000 + i));
            _buy(list[i], 2e18);
        }
        engine.register(list);
        vm.warp(block.timestamp + 2 days);

        vm.startPrank(keeper);
        uint256 g = gasleft();
        engine.fire();
        uint256 gFire = g - gasleft();
        g = gasleft();
        engine.tally(n);
        uint256 gTally = g - gasleft();
        g = gasleft();
        engine.pay(n);
        uint256 gPay = g - gasleft();
        vm.stopPrank();

        uint256 total = gFire + gTally + gPay;
        console2.log("fire            ", gFire);
        console2.log("tally(100)      ", gTally);
        console2.log("pay(100)        ", gPay);
        console2.log("epoch total     ", total);
        console2.log("per holder      ", (gTally + gPay) / n);

        // and a hook flush, which the keeper also calls
        _buy(alice, 50e18);
        g = gasleft();
        vm.prank(keeper);
        hook.flush();
        console2.log("hook.flush      ", g - gasleft());
    }
}
