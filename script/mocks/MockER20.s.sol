// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

/*
 * This file has been commented out as part of migrating to local Uniswap V4 testing.
 * It is kept for reference but is no longer used in the project.
 */

/*

import "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract MockToken is MockERC20 {
    constructor(string memory _name, string memory _symbol) MockERC20(_name, _symbol, 18) {}
}

contract MockTokenScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        new MockToken("MockTokenA", "MOCKA");
        new MockToken("MockTokenB", "MOCKB");
        vm.stopBroadcast();
    }
}
*/
