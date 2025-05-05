// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

contract EmitHelper is Test {
    /**
     * @notice Helper to conditionally expect an event emission
     * @dev Use this to handle no-op guards where events only emit when state actually changes
     * @param willEmit True if an event is expected to be emitted
     */
    function expectOptionalEmit(bool willEmit) internal {
        if (willEmit) vm.expectEmit(false, false, false, true);
    }
}
