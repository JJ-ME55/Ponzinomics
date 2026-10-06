// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {PimdToken} from "../src/pimd/PimdToken.sol";
import {PimdHook, IPimdToken} from "../src/pimd/PimdHook.sol";
import {PimdEngine} from "../src/pimd/PimdEngine.sol";

/// One script for the whole launch: deploy the engine, mine the hook for its permission bits, mine the token so
/// it sorts ABOVE IMD, deploy both, open the pool single-sided with the entire supply, bind the engine, and
/// write deployments.pimd.<chainId>.json.
///
/// After it runs there is no owner anywhere. The deployer's only two powers, `launch` and `bind`, are both
/// one-shot and both spent by the end of this script.
///
/// Env:
///   PRIVATE_KEY        the deployer (needs gas only)
///   TEAM_MULTISIG      where the team's 20% goes
///   IMD                quote token          (default: Robinhood Chain IMD)
///   START_TICK         opening price        (default: 147780, about a $5k open with IMD near $13)
///   TICK_LOWER         bottom of the range  (default: START_TICK - 46020, a 100x span)
///   LAUNCH_BUY_CAP     IMD per buyer in the first 10 minutes (default 25e18; 0 disables the cap)
///   POOL_MANAGER       override             (default: Robinhood Chain PoolManager)
///   DEPLOY_POOL_MANAGER=true                for local devnets
contract DeployPimd is Script {
    using StateLibrary for IPoolManager;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant ROBINHOOD_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant ROBINHOOD_IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant MAINNET_IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    // Opening ticks for a ~$5k market cap. Price moves, so recompute on the day and pass START_TICK.
    int24 constant MAINNET_START_TICK = 146460; // ~2.29M PIMD per IMD, IMD near $11.47
    int24 constant ROBINHOOD_START_TICK = 147780; // ~2.62M PIMD per IMD, IMD near $13
    int24 constant RANGE_TICKS = 46020; // the same ~100x span v1 used, so the range tops out near $500k
    int24 constant SPACING = 60;
    /// Where the team's 20% goes, and who holds the two one-shot powers. Baked in rather than read from the
    /// environment so that whoever runs this script, including a deployer that is not us, produces the same
    /// launch. Both are overridable for tests and rehearsals.
    address constant DEFAULT_TEAM = 0xdD48c714e71560670b8ba3f7C17040843B862846;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
    );

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address teamWallet = vm.envOr("TEAM_MULTISIG", DEFAULT_TEAM);
        require(teamWallet != address(0), "TEAM_MULTISIG required");
        // Whoever sends the deployment transaction, these two one-shot powers belong to LAUNCH_ADMIN: the hook's
        // launcher and the engine's binder. The swarm deploys from its own wallet, so this must not be msg.sender.
        address launchAdmin = vm.envOr("LAUNCH_ADMIN", teamWallet);
        require(launchAdmin != address(0), "LAUNCH_ADMIN required");

        bool mainnet = block.chainid == 1;
        bool robinhood = block.chainid == 4663 || block.chainid == 46630;

        address imd = vm.envOr("IMD", address(0));
        if (imd == address(0)) {
            require(mainnet || robinhood, "set IMD for this chain");
            imd = mainnet ? MAINNET_IMD : ROBINHOOD_IMD;
        }
        require(imd.code.length > 0, "IMD has no code");

        address pm = vm.envOr("POOL_MANAGER", address(0));
        if (pm == address(0)) {
            if (vm.envOr("DEPLOY_POOL_MANAGER", false)) {
                vm.broadcast(pk);
                pm = address(new PoolManager(deployer));
            } else if (mainnet) {
                pm = MAINNET_POOL_MANAGER;
            } else if (robinhood) {
                pm = ROBINHOOD_POOL_MANAGER;
            } else {
                revert("set POOL_MANAGER or DEPLOY_POOL_MANAGER=true");
            }
        }
        require(pm.code.length > 0, "PoolManager has no code");

        int24 startTick =
            int24(vm.envOr("START_TICK", int256(mainnet ? MAINNET_START_TICK : ROBINHOOD_START_TICK)));
        int24 tickLower = int24(vm.envOr("TICK_LOWER", int256(startTick - RANGE_TICKS)));
        require(startTick % SPACING == 0 && tickLower % SPACING == 0, "ticks must fit the spacing");
        require(tickLower < startTick, "tickLower >= startTick");

        PimdEngine.Config memory ec = PimdEngine.Config({
            poolManager: pm,
            imd: imd,
            team: teamWallet,
            binder: launchAdmin,
            // Mainnet runs a slower, cheaper cadence: ~6-hourly epochs, each releasing about 30% of the pot,
            // roughly three quarters of it per day. Robinhood's gas is cheap enough to drip every few minutes.
            dripBpsPerPeriod: vm.envOr("DRIP_BPS", mainnet ? uint256(150) : uint256(400)),
            minInterval: vm.envOr("MIN_INTERVAL", uint256(2 minutes)), // a floor, not the cadence
            // Paying one holder costs ~71k gas. On mainnet that is a few cents, so the smallest paid bag has to
            // be big enough that its share beats its own gas; on Robinhood a tenth of that is still fine.
            minBalance: vm.envOr("MIN_BALANCE", mainnet ? uint256(1_000_000e18) : uint256(100_000e18)),
            fireTip: vm.envOr("FIRE_TIP", mainnet ? uint256(0.05e18) : uint256(0.01e18)),
            tipPerHolder: vm.envOr("TIP_PER_HOLDER", mainnet ? uint256(0.003e18) : uint256(0.0001e18)),
            // Match the clamp to the cadence: too low and a slow keeper can never release the pot.
            maxCatchup: vm.envOr("MAX_CATCHUP", mainnet ? uint256(6 hours) : uint256(1 hours))
        });

        PimdHook.Config memory hc = PimdHook.Config({
            launchCapSeconds: 600,
            launchCapBlocks: 6000, // ~10 minutes at Robinhood's block rate; whichever bound hits first wins
            launchBuyCap: uint128(vm.envOr("LAUNCH_BUY_CAP", uint256(25e18))),
            burnThreshold: 1e18, // buy back and burn once 1 IMD of burn budget has built up
            burnCap: 100e18,
            callerTip: 0.01e18 // out of the team slice, never out of holders or burns
        });

        // 1. the engine, because the hook's constructor needs its address
        vm.broadcast(pk);
        PimdEngine engine = new PimdEngine(ec);

        // 2. mine the hook address for its permission bits
        bytes memory hookArgs = abi.encode(IPoolManager(pm), imd, address(engine), teamWallet, launchAdmin, hc);
        (address hookAddr, bytes32 hookSalt) =
            HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(PimdHook).creationCode, hookArgs);

        // 3. mine the token so it sorts ABOVE IMD. Everything in the hook assumes IMD is currency0, exactly as
        //    ETH was in v1; get this wrong and the pool is backwards.
        bytes32 tokenInitHash = keccak256(abi.encodePacked(type(PimdToken).creationCode, abi.encode(hookAddr)));
        bytes32 tokenSalt;
        address tokenAddr;
        for (uint256 i; i < 1_000_000; ++i) {
            address predicted = vm.computeCreate2Address(bytes32(i), tokenInitHash, CREATE2_DEPLOYER);
            if (uint160(predicted) > uint160(imd)) {
                tokenSalt = bytes32(i);
                tokenAddr = predicted;
                break;
            }
        }
        require(tokenAddr != address(0), "no token salt found");

        // 4. deploy both. Opening the pool and binding belong to LAUNCH_ADMIN, so this script only does them
        //    when it is that wallet. When somebody else deploys (the swarm launches from its own wallet), it
        //    stops here and prints the two calls LAUNCH_ADMIN has to make to finish.
        bool selfLaunch = launchAdmin == deployer;
        vm.startBroadcast(pk);
        PimdToken token = new PimdToken{salt: tokenSalt}(hookAddr);
        require(address(token) == tokenAddr, "token address mismatch");
        PimdHook hook = new PimdHook{salt: hookSalt}(IPoolManager(pm), imd, address(engine), teamWallet, launchAdmin, hc);
        require(address(hook) == hookAddr, "hook address mismatch");
        if (selfLaunch) {
            hook.launch(IPimdToken(address(token)), tickLower, startTick, SPACING);
            engine.bind(address(token), address(hook));
        }
        vm.stopBroadcast();

        // 5. prove the end state rather than assume it
        require(uint160(address(token)) > uint160(imd), "currency order wrong");
        require(hook.launcher() == launchAdmin && engine.binder() == launchAdmin, "one-shot powers misplaced");
        require(hook.team() == teamWallet && engine.team() == teamWallet, "fees point at the wrong wallet");
        if (!selfLaunch) {
            require(token.balanceOf(address(hook)) == token.totalSupply(), "supply is not on the hook");
            console2.log("DEPLOYED ONLY. LAUNCH_ADMIN must now call, in this order:");
            console2.log("  1. hook.launch(token, tickLower, startTick, 60) on", address(hook));
            console2.log("  2. engine.bind(token, hook) on", address(engine));
        }
        if (selfLaunch) {
            require(hook.launched(), "not launched");
            require(engine.bound(), "not bound");
            require(token.balanceOf(address(hook)) == 0, "hook kept tokens");
            require(token.balanceOf(pm) == token.totalSupply(), "supply is not all in the pool");
            require(hook.claimBalance() == 0, "hook holds claims before any trade");
            require(engine.excluded(address(hook)) && engine.excluded(pm), "exclusions missing");
        }
        if (selfLaunch) {
            (, int24 tickNow,,) = IPoolManager(pm).getSlot0(hook.poolId());
            require(tickNow == startTick, "pool did not open at the start tick");
        }

        string memory o = "pimd";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "poolManager", pm);
        vm.serializeAddress(o, "imd", imd);
        vm.serializeAddress(o, "token", address(token));
        vm.serializeAddress(o, "hook", address(hook));
        vm.serializeAddress(o, "engine", address(engine));
        vm.serializeAddress(o, "team", teamWallet);
        vm.serializeAddress(o, "deployer", deployer);
        vm.serializeAddress(o, "launchAdmin", launchAdmin);
        vm.serializeInt(o, "startTick", int256(startTick));
        vm.serializeInt(o, "tickLower", int256(tickLower));
        vm.serializeInt(o, "tickSpacing", int256(SPACING));
        vm.serializeUint(o, "buyTaxBps", hook.BUY_TAX_BPS());
        vm.serializeUint(o, "sellTaxBps", hook.SELL_TAX_BPS());
        vm.serializeUint(o, "launchBuyCap", hc.launchBuyCap);
        vm.serializeBool(o, "launched", selfLaunch);
        vm.serializeUint(o, "initBlock", hook.initBlock());
        vm.serializeUint(o, "launchedAt", block.timestamp);
        vm.serializeUint(o, "supply", token.totalSupply());
        string memory json = vm.serializeBytes32(o, "poolId", PoolId.unwrap(hook.poolId()));
        string memory outPath =
            vm.envOr("DEPLOY_OUT", string.concat("deployments.pimd.", vm.toString(block.chainid), ".json"));
        vm.writeJson(json, outPath);

        console2.log("PIMD token  ", address(token));
        console2.log("PIMD hook   ", address(hook));
        console2.log("PIMD engine ", address(engine));
        console2.log("quote (IMD) ", imd);
        console2.log("start tick  ", int256(startTick));
        console2.log("supply in pool", token.totalSupply() / 1e18);
        console2.log("no owner anywhere; launch and bind are both spent");
    }
}
