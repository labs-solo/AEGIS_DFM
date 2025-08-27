// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract LM {
    /* simplistic counters to prove calls happened */
    uint256 public deposits;
    uint256 public withdrawals;

    function deposit(PoolId, uint256, uint256, uint256, uint256, address receiver)
        external
        payable
        returns (uint256 s, uint256 a0, uint256 a1)
    {
        deposits++;
        /* ----------------------------------------------------------------
         * Forward the 1 wei "rebate" to **the recipient passed by Spot**,
         * not to `msg.sender`, so that the `Reentrant` helper contract
         * receives the funds and can recurse into `Spot.deposit()` while
         * the outer call is still in-flight.
         *
         * If the recipient re-enters **Spot** (as the re-entrancy test does)
         * the inner call will revert with `ReentrancyLocked()`.  We *must*
         * bubble that revert reason up so the outer test can detect it.
         * -------------------------------------------------------------- */
        (bool ok, bytes memory ret) = payable(receiver).call{value: 1 wei}("");

        if (!ok) {
            /// @solidity memory-safe-assembly
            assembly {
                revert(add(ret, 0x20), mload(ret)) // bubble original revert
            }
        }
        return (100, 1 ether, 1 ether);
    }

    function withdraw(PoolId, uint256, uint256, uint256, address) external returns (uint256 a0, uint256 a1) {
        withdrawals++;
        return (1 ether, 1 ether);
    }

    /* stubs needed by Spot */
    function reinvest(PoolId, uint256, uint256, uint128) external returns (uint128) {
        return 1;
    }

    function getPoolReserves(PoolId) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function positionTotalShares(PoolId) external pure returns (uint128) {
        return 1e18;
    }

    function storePoolKey(PoolId, PoolKey calldata) external {}
}
