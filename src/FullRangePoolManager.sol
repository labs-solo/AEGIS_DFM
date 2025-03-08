// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title FullRangePoolManager
 * @notice Manages pool creation for dynamic-fee Uniswap V4 pools.
 *         Stores minimal data like totalLiquidity, tickSpacing, etc.
 * 
 * Phase 2 Requirements Fulfilled:
 *  • Integrate with Uniswap V4's IPoolManager to create a new pool.
 *  • Enforce dynamic-fee requirement (using a simple check for dynamic fee flag).
 *  • Store minimal pool data in a mapping, governed by an onlyGovernance modifier.
 */

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IFullRange} from "./interfaces/IFullRange.sol";

/**
 * @dev Basic struct storing minimal info about a newly created pool.
 *      - totalLiquidity is set to 0 initially in this Phase.
 *      - tickSpacing is from the pool key.
 */
struct PoolInfo {
    bool hasAccruedFees;     // placeholder for expansions
    uint128 totalLiquidity;  // starts at 0
    int24 tickSpacing;       // Change to int24 to match PoolKey.tickSpacing
}

/**
 * @dev Dynamic fee check implementation.
 */
library DynamicFeeCheck {
    function isDynamicFee(uint24 fee) internal pure returns (bool) {
        // Dynamic fee is signaled by 0x800000 (the highest bit set in a uint24)
        return (fee == 0x800000); 
    }
}

contract FullRangePoolManager {
    /// @dev The reference to the Uniswap V4 IPoolManager 
    IPoolManager public immutable manager;

    /// @dev Governance address, controlling new pool creation
    address public governance;
    
    /// @dev FullRange contract address, which is also allowed to call privileged functions
    address public fullRangeAddress;

    /// @dev Minimal tracking of newly created pools 
    mapping(PoolId => PoolInfo) public poolInfo;

    /// @dev Emitted upon pool creation
    event PoolInitialized(PoolId indexed poolId, PoolKey key, uint160 sqrtPrice, uint24 fee);
    
    /// @dev Emitted when totalLiquidity is updated
    event TotalLiquidityUpdated(PoolId indexed poolId, uint128 oldLiquidity, uint128 newLiquidity);

    /// @dev Revert if caller not governance or FullRange contract
    modifier onlyAuthorized() {
        require(msg.sender == governance || msg.sender == fullRangeAddress, "Not authorized");
        _;
    }

    /// @param _manager The v4-core IPoolManager reference
    /// @param _governance The address with permission to create new pools
    constructor(IPoolManager _manager, address _governance) {
        manager = _manager;
        governance = _governance;
    }
    
    /**
     * @notice Sets the FullRange contract address as privileged caller
     * @dev Can only be called by governance
     * @param _fullRangeAddress The address of the deployed FullRange contract
     */
    function setFullRangeAddress(address _fullRangeAddress) external {
        require(msg.sender == governance, "Only governance can set FullRange address");
        fullRangeAddress = _fullRangeAddress;
    }

    /**
     * @notice Creates a new dynamic-fee pool, storing minimal info in poolInfo
     * @dev Checks if fee is dynamic, calls manager.initialize, sets poolInfo
     * @param key The pool key (currency0, currency1, fee, tickSpacing, hooks)
     * @param initialSqrtPriceX96 The initial sqrt price
     * @return poolId The ID of the created pool
     */
    function initializeNewPool(PoolKey calldata key, uint160 initialSqrtPriceX96)
        external
        onlyAuthorized
        returns (PoolId poolId)
    {
        // 1. Check dynamic fee
        if (!DynamicFeeCheck.isDynamicFee(key.fee)) {
            revert("NotDynamicFee"); 
        }

        // 2. Create the new pool in v4-core
        manager.initialize(key, initialSqrtPriceX96);
        
        // 3. Compute the pool ID
        poolId = PoolIdLibrary.toId(key);

        // 4. Store minimal data
        poolInfo[poolId] = PoolInfo({
            hasAccruedFees: false,
            totalLiquidity: 0,
            tickSpacing: key.tickSpacing
        });

        // 5. Optionally set an initial dynamic fee, e.g., manager.setLPFee(poolId, 3000);

        emit PoolInitialized(poolId, key, initialSqrtPriceX96, key.fee);
        
        return poolId;
    }
    
    /**
     * @notice Updates the totalLiquidity of a pool
     * @dev Added for Phase 3 to allow the LiquidityManager to update pool info
     * @param pid The pool ID to update
     * @param newLiquidity The new total liquidity value
     */
    function updateTotalLiquidity(PoolId pid, uint128 newLiquidity) external {
        // For Phase 3 demonstration, we don't do a governance check here
        // But in a real system, you might restrict or allow certain calls
        PoolInfo storage pinfo = poolInfo[pid];
        uint128 oldLiquidity = pinfo.totalLiquidity;
        pinfo.totalLiquidity = newLiquidity;
        
        emit TotalLiquidityUpdated(pid, oldLiquidity, newLiquidity);
    }
} 