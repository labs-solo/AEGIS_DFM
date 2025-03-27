// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title FullRangeUtils
 * @notice Helper library for the FullRange hook contract. Provides reusable logic for math operations,
 *         token transfers, and pool policy data assembly.
 * @dev Functions in this library are internal, so they are inlined into the calling contract (FullRange) at compile time.
 */

import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {Errors} from "../errors/Errors.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolPolicy} from "../interfaces/IPoolPolicy.sol";

library FullRangeUtils {
    
    /**
     * @notice Calculate deposit amounts and shares based on pool state and current price.
     * @dev Delegates mathematical calculations to MathUtils for precision handling.
     */
    function computeDepositAmountsAndShares(
        uint128 totalShares,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 reserve0,
        uint256 reserve1,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256 actual0, uint256 actual1, uint256 sharesMinted) {
        (actual0, actual1, sharesMinted, ) = MathUtils.computeDepositAmountsAndSharesWithPrecision(
            totalShares, amount0Desired, amount1Desired, reserve0, reserve1
        );
        return (actual0, actual1, sharesMinted);
    }

    /**
     * @notice Calculate withdrawal amounts based on shares to burn.
     * @dev Uses MathUtils for precise computation of output amounts.
     */
    function computeWithdrawAmounts(
        uint128 totalShares,
        uint256 sharesToBurn,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (uint256 amount0Out, uint256 amount1Out) {
        return MathUtils.computeWithdrawAmountsWithPrecision(totalShares, sharesToBurn, reserve0, reserve1);
    }

    /**
     * @notice Transfers specified token amounts from a user to the contract, verifying allowance.
     * @dev Uses SafeTransferLib for safe ERC20 operations. Reverts if ETH is involved (should use depositETH instead).
     */
    function pullTokensFromUser(
        address token0,
        address token1,
        address user,
        uint256 actual0,
        uint256 actual1
    ) internal {
        // Pull token0
        if (actual0 > 0) {
            if (token0 == address(0)) revert Errors.TokenEthNotAccepted();
            SafeTransferLib.safeTransferFrom(ERC20(token0), user, address(this), actual0);
        }
        
        // Pull token1
        if (actual1 > 0) {
            if (token1 == address(0)) revert Errors.TokenEthNotAccepted();
            SafeTransferLib.safeTransferFrom(ERC20(token1), user, address(this), actual1);
        }
    }

    /**
     * @notice Assembles an array of policy implementation addresses for all policy types of a given pool.
     * @dev Fetches each policy via the IPoolPolicy interface. Used during pool initialization to initialize all policies.
     * @param policyManager The IPoolPolicy contract providing access to policy addresses.
     * @param poolId The unique PoolId of the pool.
     * @return implementations An address[6] array containing the implementation contract for each policy type.
     */
    function getPoolPolicyImplementations(IPoolPolicy policyManager, PoolId poolId)
        internal
        view
        returns (address[] memory implementations)
    {
        implementations = new address[](6);
        implementations[0] = policyManager.getPolicy(poolId, IPoolPolicy.PolicyType.FEE);
        implementations[1] = policyManager.getPolicy(poolId, IPoolPolicy.PolicyType.VTIER);
        implementations[2] = policyManager.getPolicy(poolId, IPoolPolicy.PolicyType.FEE);
        implementations[3] = policyManager.getPolicy(poolId, IPoolPolicy.PolicyType.TICK_SCALING);
        implementations[4] = policyManager.getPolicy(poolId, IPoolPolicy.PolicyType.REINVESTMENT);
        implementations[5] = address(0);
        return implementations;
    }
} 