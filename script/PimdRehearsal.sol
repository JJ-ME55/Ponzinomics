// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {PimdToken} from "../src/pimd/PimdToken.sol";

/// @title PimdRehearsal
/// @notice Fork-only launch rehearsal. Stands the real contracts up against a forked Robinhood Chain so the
///         keeper can be driven through whole epochs before a paid launch, which is the one thing no audit
///         covers: audits read the contracts, and the keeper is JavaScript.
///
/// Deliberately the REAL `PimdHook`, not the test harness: its constructor takes the pool manager, the token
/// and the launch factory, and every other address -- the engine, the team wallet, IMD -- is a source
/// constant. On a fork of the real chain those constants point at the real things, and the factory is simply
/// passed in, so the seeder can play that part directly. Nothing here is reachable on a real chain: it is not
/// deployed by `DeployPimd.s.sol` and the launch request does not name it.
///
/// Used by `pulse-imd/rehearse/rehearse.sh`.
contract PimdRehearsal {
    /// The hook's permission bits, which its address has to encode or `validateHookPermissions` reverts.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    address public token;
    address public hook;

    /// Deploys the token and the hook, and returns the seeder whose code the runner relocates to the hook's
    /// `LAUNCH_FACTORY`. One call, so the whole setup is one transaction and the fork's head cannot move
    /// underneath it -- Robinhood's public RPCs prune head state within seconds.
    /// Deploys the token only. The hook is CREATE2-deployed by the runner through the canonical deployer,
    /// with its salt mined by `cast create2`: embedding the hook's 15.5KB of creation code in here put this
    /// contract over the 24,576-byte create limit. The hook's constructor does not read `msg.sender`, so it
    /// does not care who deploys it -- unlike the token, which mints to its deployer.
    function deployToken(address imd) external returns (address) {
        token = _deployTokenAbove(imd);
        return token;
    }

    /// The hook address has to encode these or `validateHookPermissions` reverts in its constructor. 0x3ACC.
    function hookFlags() external pure returns (uint160) {
        return HOOK_FLAGS;
    }

    /// The hook's init code, uploaded in pieces. Passing 16KB of hex as a command-line argument broke the
    /// Windows argument limit once the hook grew, and embedding it here broke the 24,576-byte create limit,
    /// so it arrives in chunks and is assembled in memory at deploy time. Chunks are stored separately
    /// rather than concatenated on each append, so no single call rewrites the whole array.
    mapping(uint256 => bytes) private _chunks;
    uint256 public chunkCount;

    function appendCode(bytes calldata chunk) external {
        _chunks[chunkCount++] = chunk;
    }

    function resetCode() external {
        chunkCount = 0;
    }

    function initCode() public view returns (bytes memory out) {
        for (uint256 i; i < chunkCount; ++i) {
            out = bytes.concat(out, _chunks[i]);
        }
    }

    /// Lets the runner confirm the uploaded bytes are the ones the salt was mined against, before spending a
    /// deployment on them.
    function initCodeHash() external view returns (bytes32) {
        return keccak256(initCode());
    }

    /// CREATE2-deploys the hook from a salt mined by `cast create2 --deployer <this>`. Deploying from here
    /// rather than the canonical proxy means the mined deployer address is one we control and does not have
    /// to exist on the forked chain.
    function deployHookFromStore(bytes32 salt) external returns (address h) {
        bytes memory code = initCode();
        require(code.length != 0, "no init code uploaded");
        assembly {
            h := create2(0, add(code, 0x20), mload(code), salt)
        }
        require(h != address(0), "hook create2 failed");
        require(uint160(h) & 0x3fff == HOOK_FLAGS, "hook address does not encode the permissions");
        hook = h;
    }

    /// The mirror case, and the whole reason this exists: a token that sorts BELOW IMD, so V4 puts PIMD at
    /// currency0 and IMD at currency1. The factory produces this about 37% of the time and it parked three
    /// launches. The hook now takes it, and the rehearsal has to prove a real trade is still taxed the right
    /// way round when it does.
    function deployTokenBelow(address imd) external returns (address) {
        bytes32 initHash = keccak256(type(PimdToken).creationCode);
        for (uint256 i = 1; i < 400_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
            if (uint160(predicted) < uint160(imd)) {
                PimdToken t = new PimdToken{salt: salt}();
                require(address(t) == predicted, "token create2");
                token = address(t);
                return token;
            }
        }
        revert("no salt sorts below IMD");
    }

    /// What to open and seed with when PIMD is currency0. Mirrors `plan`: the range sits entirely ABOVE the
    /// opening price so the position is all currency0, and the amount is therefore solved against currency0.
    function planFlipped(address imd, int24 startTick, int24 tickUpper, uint256 amount)
        external
        view
        returns (PoolKey memory key, uint160 sqrtPriceX96, uint128 liquidity)
    {
        key = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(imd),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(startTick);
        liquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(startTick), TickMath.getSqrtPriceAtTick(tickUpper), amount
        );
    }

    /// PIMD sorting ABOVE IMD keeps IMD as currency0, the arrangement the hook was originally written for.
    function _deployTokenAbove(address imd) internal returns (address) {
        bytes32 initHash = keccak256(type(PimdToken).creationCode);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash))))
            );
            if (uint160(predicted) > uint160(imd)) {
                PimdToken t = new PimdToken{salt: salt}();
                require(address(t) == predicted, "token create2");
                return address(t);
            }
        }
        revert("no salt sorts above IMD");
    }

    /// Fans the holder bags out in one transaction. One `cast send` per wallet took eight minutes for 150
    /// and made the rehearsal look like it had hung.
    function fanOut(address[] calldata to, uint256 each) external {
        for (uint256 i; i < to.length; ++i) {
            require(PimdToken(token).transfer(to[i], each), "fanOut");
        }
    }

    /// Hands the minted supply on. The token mints to its deployer, which is this contract.
    function sweep(address to) external {
        PimdToken(token).transfer(to, PimdToken(token).balanceOf(address(this)));
    }

    /// What the pool should be opened with, so the runner does not recompute tick maths in bash.
    function plan(address imd, int24 startTick, int24 tickLower, uint256 amount)
        external
        view
        returns (PoolKey memory key, uint160 sqrtPriceX96, uint128 liquidity)
    {
        key = PoolKey({
            currency0: Currency.wrap(imd),
            currency1: Currency.wrap(token),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(startTick);
        // Single-sided in PIMD: the range sits entirely below the opening price, so the position is all
        // currency1 and the pool opens holding no IMD at all.
        liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(startTick), amount
        );
    }
}
