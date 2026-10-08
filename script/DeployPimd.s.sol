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

        // Which chain's addresses to use, and whether this is a real launch, are two different questions.
        // Conflating them is how the engine already on Robinhood ended up with every economic parameter set
        // to its test value: the flag was `block.chainid == 1`, which is Ethereum, but it also chose the
        // economics, and Robinhood mainnet is not Ethereum. `production` is the one that picks numbers.
        bool ethereum = block.chainid == 1;
        bool robinhoodMainnet = block.chainid == 4663;
        bool testnet = block.chainid == 46630;
        require(ethereum || robinhoodMainnet || testnet, "unsupported chain");
        bool production = !testnet;

        address pm = vm.envOr("POOL_MANAGER", ethereum ? MAINNET_POOL_MANAGER : ROBINHOOD_POOL_MANAGER);
        address imd = vm.envOr("IMD", ethereum ? MAINNET_IMD : ROBINHOOD_IMD);
        require(pm.code.length > 0, "PoolManager has no code");
        require(imd.code.length > 0, "IMD has no code");

        PimdEngine.Config memory ec = PimdEngine.Config({
            poolManager: pm,
            imd: imd,
            team: team,
            binder: binder,
            dripBpsPerPeriod: vm.envOr("DRIP_BPS", production ? uint256(150) : uint256(400)),
            minInterval: vm.envOr("MIN_INTERVAL", uint256(2 minutes)),
            minBalance: vm.envOr("MIN_BALANCE", production ? uint256(1_000_000e18) : uint256(100_000e18)),
            fireTip: vm.envOr("FIRE_TIP", production ? uint256(0.05e18) : uint256(0.01e18)),
            tipPerHolder: vm.envOr("TIP_PER_HOLDER", production ? uint256(0.003e18) : uint256(0.0001e18)),
            maxCatchup: vm.envOr("MAX_CATCHUP", production ? uint256(6 hours) : uint256(1 hours)),
            // `tally` weighs the whole holder set in one call, so the set has to fit one transaction.
            // The budget is NOT the 2^50 in the block header -- that is an Arbitrum placeholder. It is
            // ArbOS's maxTxGasLimit, which this chain's ArbGasInfo precompile (0x6C,
            // getGasAccountingParams) reports as 32,000,000. Cost per weighted holder is 37-38k once
            // balances move between tallies, which is the case that counts; the 34.6k in Gas.t.sol is
            // the cheap state where no balance changed. So 700 is about 26M, 81% of the budget, under a
            // constructor ceiling of 800 (29.6M). 1,200 was 44M and could never have been weighed.
            maxHolders: vm.envOr("MAX_HOLDERS", uint256(700))
        });

        vm.broadcast(pk);
        PimdEngine engine = new PimdEngine(ec);

        require(engine.team() == team && engine.binder() == binder, "engine wiring wrong");
        require(!engine.bound(), "engine should not be bound yet");

        // This script has already been broadcast twice and two engines are live. The hook names exactly one
        // of them in a compile-time constant, so a further deploy that nobody notices leaves the hook
        // pointing at an engine that will never be bound, and the launch is paid for before anyone finds
        // out. Set EXPECT_ENGINE to the address you intend and the script refuses to drift from it.
        address expected = vm.envOr("EXPECT_ENGINE", address(0));
        require(expected == address(0) || expected == address(engine), "engine address is not the expected one");

        console2.log("PimdEngine  ", address(engine));
        console2.log("team        ", team);
        console2.log("binder      ", binder);
        console2.log("");
        console2.log("-- parameters actually deployed (check these against intent) --");
        console2.log("production  ", production);
        console2.log("dripBps     ", engine.dripBpsPerPeriod());
        console2.log("minBalance  ", engine.minBalance());
        console2.log("fireTip     ", engine.fireTip());
        console2.log("tipPerHolder", engine.tipPerHolder());
        console2.log("maxCatchup  ", engine.maxCatchup());
        console2.log("maxHolders  ", engine.maxHolders());
        console2.log("");
        console2.log("Next: write this address into PimdHook.ENGINE_ADDRESS, push, then quote the launch.");
        console2.log("After the launch lands, the binder calls engine.bind(token, hook, [distributor]).");
        console2.log("The airdrop distributor MUST be in that list, or it earns drips nobody can claim.");
    }
}
