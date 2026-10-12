// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// Opens and seeds the pool the way the real factory does: an outside contract drives `initialize` and one
/// `modifyLiquidity` through the PoolManager, so nothing the hook does is special-cased for the caller.
/// Only immutables, no storage, so its runtime code can be relocated with `anvil_setCode` and still work.
contract RehearsalSeeder is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function open(PoolKey memory key, uint160 sqrtPriceX96) external {
        manager.initialize(key, sqrtPriceX96);
    }

    function seed(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        manager.unlock(abi.encode(key, tickLower, tickUpper, int256(uint256(liquidity))));
    }

    /// The real question the liquidity lock exists to answer: can the address that owns the position take it
    /// back out? Driving a negative delta through anything else proves nothing, because nothing else owns a
    /// position and the PoolManager refuses it before the hook is consulted.
    function unseed(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        manager.unlock(abi.encode(key, tickLower, tickUpper, -int256(uint256(liquidity))));
    }

    /// A zero delta, which is how the pool's own 1.25% fee is collected. The hook has to allow this while
    /// refusing every withdrawal.
    function collect(PoolKey memory key, int24 tickLower, int24 tickUpper) external {
        manager.unlock(abi.encode(key, tickLower, tickUpper, int256(0)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) =
            abi.decode(data, (PoolKey, int24, int24, int256));
        (BalanceDelta d,) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: 0}),
            ""
        );
        if (d.amount1() < 0) {
            manager.sync(key.currency1);
            IERC20Like(Currency.unwrap(key.currency1)).transfer(address(manager), uint256(uint128(-d.amount1())));
            manager.settle();
        } else if (d.amount1() > 0) {
            manager.take(key.currency1, address(this), uint256(uint128(d.amount1())));
        }
        if (d.amount0() < 0) {
            manager.sync(key.currency0);
            IERC20Like(Currency.unwrap(key.currency0)).transfer(address(manager), uint256(uint128(-d.amount0())));
            manager.settle();
        } else if (d.amount0() > 0) {
            manager.take(key.currency0, address(this), uint256(uint128(d.amount0())));
        }
        return "";
    }
}

interface IERC20Like {
    function transfer(address, uint256) external returns (bool);
}
