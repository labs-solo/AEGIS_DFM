// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract LM {
    /* simplistic counters to prove calls happened */
    uint256 public deposits;
    uint256 public withdrawals;

    function deposit(
        PoolId,
        uint256, uint256,
        uint256, uint256,
        address receiver
    ) external payable returns (uint256 s, uint256 a0, uint256 a1) {
        deposits++;
        /* ----------------------------------------------------------------
         * Re-entrancy test-setup needs **full gas** inside the callback
         * (the 2300-gas stipend of `.transfer`/`.send` is too small).
         * Switch to a low-level `.call{value:…}` so the recipient gets
         * whatever gas remains.
         * ------------------------------------------------------------- */
        (bool ok,) = payable(msg.sender).call{value: 1 wei}("");
        require(ok, "refund failed");
        return (100, 1 ether, 1 ether);
    }

    function withdraw(
        PoolId,
        uint256, uint256, uint256,
        address
    ) external returns (uint256 a0, uint256 a1) {
        withdrawals++;
        return (1 ether, 1 ether);
    }

    /* stubs needed by Spot */
    function reinvest(PoolId, uint256, uint256, uint128) external returns (uint128) { return 1; }
    function getPoolReserves(PoolId) external pure returns (uint256, uint256) { return (0,0); }
    function positionTotalShares(PoolId) external pure returns (uint128) { return 1e18; }
    function storePoolKey(PoolId, PoolKey calldata) external {}
} 