// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PimdEngine} from "../src/pimd/PimdEngine.sol";

/// @title DeployPimd
/// @notice Deploys the engine, and only the engine.
///
/// The hook and the token are deployed by the IMD launch factory, which constructs the hook with just the
/// pool manager and the token and opens the pool itself. Everything else the hook needs is written into its
/// source, so the engine has to exist first and its address has to be in `PimdHook.ENGINE_ADDRESS` before
/// the launch request goes out.
///
/// Run it, take the address it prints, write it into the hook, push, then quote the launch.
///
///   PRIVATE_KEY=0x… forge script script/DeployPimd.s.sol:DeployPimd --rpc-url robinhood --broadcast
contract DeployPimd is Script {
    address constant ROBINHOOD_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant ROBINHOOD_IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant MAINNET_IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    /// @dev Receives the team's 25% of the tax, in IMD, and is the wallet that may call `bind` once.
    address constant DEFAULT_TEAM = 0x0960E8Bd80462e3842Bb6620c7C5289A44c4559B;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address team = vm.envOr("TEAM_MULTISIG", DEFAULT_TEAM);
        address binder = vm.envOr("BINDER", team);
        require(team != address(0) && binder != address(0), "team and binder required");

        bool mainnet = block.chainid == 1;
        bool robinhood = block.chainid == 4663 || block.chainid == 46630;
        require(mainnet || robinhood, "unsupported chain");

        address pm = vm.envOr("POOL_MANAGER", mainnet ? MAINNET_POOL_MANAGER : ROBINHOOD_POOL_MANAGER);
        address imd = vm.envOr("IMD", mainnet ? MAINNET_IMD : ROBINHOOD_IMD);
        require(pm.code.length > 0, "PoolManager has no code");
        require(imd.code.length > 0, "IMD has no code");

        PimdEngine.Config memory ec = PimdEngine.Config({
            poolManager: pm,
            imd: imd,
            team: team,
            binder: binder,
            dripBpsPerPeriod: vm.envOr("DRIP_BPS", mainnet ? uint256(150) : uint256(400)),
            minInterval: vm.envOr("MIN_INTERVAL", uint256(2 minutes)),
            minBalance: vm.envOr("MIN_BALANCE", mainnet ? uint256(1_000_000e18) : uint256(100_000e18)),
            fireTip: vm.envOr("FIRE_TIP", mainnet ? uint256(0.05e18) : uint256(0.01e18)),
            tipPerHolder: vm.envOr("TIP_PER_HOLDER", mainnet ? uint256(0.003e18) : uint256(0.0001e18)),
            maxCatchup: vm.envOr("MAX_CATCHUP", mainnet ? uint256(6 hours) : uint256(1 hours))
        });

        vm.broadcast(pk);
        PimdEngine engine = new PimdEngine(ec);

        require(engine.team() == team && engine.binder() == binder, "engine wiring wrong");
        require(!engine.bound(), "engine should not be bound yet");

        console2.log("PimdEngine  ", address(engine));
        console2.log("team        ", team);
        console2.log("binder      ", binder);
        console2.log("");
        console2.log("Next: write this address into PimdHook.ENGINE_ADDRESS, push, then quote the launch.");
        console2.log("After the launch lands, the binder calls engine.bind(token, hook).");
    }
}
