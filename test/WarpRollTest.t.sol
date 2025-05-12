// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";

contract WarpRollTest is Test {
    function testWarpRoll() public {
        emit log_named_uint("initial timestamp", block.timestamp);
        emit log_named_uint("initial block", block.number);

        vm.warp(block.timestamp + 1);
        emit log_named_uint("after warp timestamp", block.timestamp);
        emit log_named_uint("after warp block", block.number);

        vm.roll(block.number + 1);
        emit log_named_uint("after roll timestamp", block.timestamp);
        emit log_named_uint("after roll block", block.number);
    }
} 