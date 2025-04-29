// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {DefaultPoolCreationPolicy} from "src/DefaultPoolCreationPolicy.sol";

contract SmokeTest is Test {
    DefaultPoolCreationPolicy public policy;

    function setUp() public {
        policy = new DefaultPoolCreationPolicy(address(this));
    }

    function test_DefaultPoolCreationPolicy_Deployment() public {
        assertTrue(address(policy) != address(0), "Policy deployment failed");
    }

    function test_DefaultPoolCreationPolicy_Owner() public {
        assertEq(policy.owner(), address(this), "Incorrect owner set");
    }
}
