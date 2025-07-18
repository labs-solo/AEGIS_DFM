// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Timelock} from "src/Timelock.sol";
import {UniswapV4Config} from "./base/UniswapV4Config.sol";

contract DeployTimelockScript is Script, UniswapV4Config {
    struct TimelockConfig {
        address admin;
        uint256 delay;
    }

    function run() external {
        string memory activeProfile = vm.envString("FOUNDRY_PROFILE");

        console.log("=== Timelock Deployment Configuration ===");
        console.log("Active profile:", activeProfile);
        console.log("Chain ID:", block.chainid);

        TimelockConfig memory config = getTimelockConfig();

        console.log("Admin address:", config.admin);
        console.log("Delay period:", config.delay, "seconds");
        console.log("Delay period:", config.delay / 1 days, "days");
        console.log("========================================");

        validateConfig(config);

        Timelock timelock = deployTimelock(config);

        logDeploymentResults(timelock);

        console.log("Timelock deployment completed successfully!");
    }

    function getTimelockConfig() internal view returns (TimelockConfig memory config) {
        config.admin = vm.envOr("TIMELOCK_ADMIN", msg.sender);
        config.delay = vm.envOr("TIMELOCK_DELAY", uint256(180));

        if (config.admin == address(0)) {
            config.admin = msg.sender;
        }

        return config;
    }

    function validateConfig(TimelockConfig memory config) internal pure {
        require(config.admin != address(0), "DeployTimelock: Admin address cannot be zero");
        require(config.delay >= 60, "DeployTimelock: Delay must be at least 2 days (minimum delay)");
        require(config.delay <= 30 days, "DeployTimelock: Delay cannot exceed 30 days (maximum delay)");
    }

    function deployTimelock(TimelockConfig memory config) internal returns (Timelock timelock) {
        console.log("Starting Timelock deployment...");

        vm.startBroadcast();

        timelock = new Timelock(config.admin, config.delay);

        vm.stopBroadcast();

        console.log("Timelock deployed at:", address(timelock));

        verifyDeployment(timelock, config);

        return timelock;
    }

    function verifyDeployment(Timelock timelock, TimelockConfig memory config) internal view {
        console.log("Verifying deployment...");

        require(timelock.admin() == config.admin, "DeployTimelock: Admin verification failed");
        require(timelock.delay() == config.delay, "DeployTimelock: Delay verification failed");
        require(timelock.pendingAdmin() == address(0), "DeployTimelock: Pending admin should be zero");

        require(timelock.MINIMUM_DELAY() == 60, "DeployTimelock: Minimum delay constant incorrect");
        require(timelock.MAXIMUM_DELAY() == 30 days, "DeployTimelock: Maximum delay constant incorrect");
        require(timelock.GRACE_PERIOD() == 14 days, "DeployTimelock: Grace period constant incorrect");

        console.log("Deployment verification successful!");
    }

    function logDeploymentResults(Timelock timelock) internal view {
        console.log("\n=== Timelock Deployment Results ===");
        console.log("Contract Address:", address(timelock));
        console.log("Admin:", timelock.admin());
        console.log("Delay:", timelock.delay(), "seconds");
        console.log("Delay (days):", timelock.delay() / 1 days);
        console.log("Pending Admin:", timelock.pendingAdmin());
        console.log("Minimum Delay:", timelock.MINIMUM_DELAY() / 1 days, "days");
        console.log("Maximum Delay:", timelock.MAXIMUM_DELAY() / 1 days, "days");
        console.log("Grace Period:", timelock.GRACE_PERIOD() / 1 days, "days");
        console.log("===================================\n");
    }
}
