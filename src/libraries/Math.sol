// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

library Math {
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    function setDynamicFeeOverride(uint24 dynamicFee) internal pure returns (uint24) {
        return dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }
}
