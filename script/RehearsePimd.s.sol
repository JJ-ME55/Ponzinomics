// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// Drives real trades against a launched pool on a local fork, so the keeper has something to do.
/// Buyers must already hold IMD (fund them by impersonating a holder with cast before running this).
///
///   forge script script/RehearsePimd.s.sol:RehearsePimd --rpc-url http://127.0.0.1:8545 --broadcast
contract RehearsePimd is Script {
    function run() external {
        string memory j = vm.readFile("deployments.pimd.4663.json");
        address token = vm.parseJsonAddress(j, ".token");
        address hook = vm.parseJsonAddress(j, ".hook");
        address imd = vm.parseJsonAddress(j, ".imd");
        address pm = vm.parseJsonAddress(j, ".poolManager");
        int24 spacing = int24(vm.parseJsonInt(j, ".tickSpacing"));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(imd),
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: spacing,
            hooks: IHooks(hook)
        });

        // one router for the rehearsal
        vm.startBroadcast(vm.envUint("DEPLOYER_KEY"));
        PoolSwapTest router = new PoolSwapTest(IPoolManager(pm));
        vm.stopBroadcast();
        console2.log("router", address(router));

        uint256[3] memory keys =
            [vm.envUint("BUYER1_KEY"), vm.envUint("BUYER2_KEY"), vm.envUint("BUYER3_KEY")];
        uint128[3] memory spend = [uint128(20e18), uint128(12e18), uint128(8e18)];

        for (uint256 i; i < keys.length; ++i) {
            address who = vm.addr(keys[i]);
            uint256 have = IERC20(imd).balanceOf(who);
            if (have < spend[i]) {
                console2.log("skipping, not enough IMD:", who, have);
                continue;
            }
            vm.startBroadcast(keys[i]);
            IERC20(imd).approve(address(router), type(uint256).max);
            router.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(uint256(spend[i])),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
            vm.stopBroadcast();
            console2.log("bought", who, IERC20(token).balanceOf(who) / 1e18);
        }

        // and one sell, so the 7% side is exercised too
        uint256 sellerKey = keys[2];
        address seller = vm.addr(sellerKey);
        uint256 bag = IERC20(token).balanceOf(seller);
        if (bag > 0) {
            vm.startBroadcast(sellerKey);
            IERC20(token).approve(address(router), type(uint256).max);
            router.swap(
                key,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(bag / 2),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
            vm.stopBroadcast();
            console2.log("sold half of", seller);
        }
    }
}
