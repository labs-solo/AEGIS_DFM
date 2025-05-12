// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;
import "forge-std/Script.sol";
import "forge-std/Test.sol";

contract CheckWarpRoll is Script, Test {
    function run() external {
        emit log_named_uint("initial timestamp", block.timestamp);
        vm.warp(block.timestamp + 1);
        emit log_named_uint("after warp", block.timestamp);
        vm.roll(block.number + 1);
        emit log_named_uint("after roll", block.timestamp);
    }
} 