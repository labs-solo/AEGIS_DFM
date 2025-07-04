// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVaultManagerCore} from "../src/interfaces/IVaultManagerCore.sol";

/// Example leveraging a vault in one transaction.
contract BatchLever {
    IVaultManagerCore public immutable vault;

    constructor(IVaultManagerCore _vault) {
        vault = _vault; // T1
    }

    function lever(address asset, uint256 amount, bytes32 poolId) external {
        // prepare actions according to T7 typed batching
        IVaultManagerCore.Action[] memory acts = new IVaultManagerCore.Action[](2); // T3
        acts[0] = IVaultManagerCore.Action({code: 0, data: abi.encode(asset, amount, msg.sender)}); // deposit T2
        acts[1] = IVaultManagerCore.Action({code: 2, data: abi.encode(poolId, amount, msg.sender)}); // borrow T5
        vault.executeBatchTyped(acts); // T4 caching, T6 invariants
    }
}
