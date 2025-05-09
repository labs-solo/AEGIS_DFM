// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

contract AnalyzeAddress is Script {
    function run() public pure {
        revert("This script requires an address argument. Run with --sig \"run(address)\" <address>");
    }
}
