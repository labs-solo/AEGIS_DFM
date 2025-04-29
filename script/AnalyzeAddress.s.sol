// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {Hooks} from "@uniswap/v4-core/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";

contract AnalyzeAddress is Script {
    function run() public pure {
        revert("This script requires an address argument. Run with --sig \"run(address)\" <address>");
    }
}
