// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title FullRangeOracleManager
 * @notice Manages block/tick-based throttling for oracle updates,
 *         referencing an external truncated geomean oracle contract.
 *
 * Phase 5 Requirements:
 *  1. blockUpdateThreshold & tickDiffThreshold gating
 *  2. lastOracleUpdateBlock and lastOracleTick tracking
 *  3. If thresholds are met, call external oracle updateObservation(...)
 *  4. 90%+ coverage in FullRangeOracleManagerTest
 */

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/**
 * @dev Minimal interface for a truncated geomean oracle used in our design
 */
interface ITruncGeoOracleMulti {
    function updateObservation(PoolKey calldata key) external;
}

contract FullRangeOracleManager {
    /// @dev The external truncated geomean oracle
    ITruncGeoOracleMulti public immutable truncGeoOracleMulti;

    /// @dev The reference to IPoolManager for reading current tick
    IPoolManager public immutable manager;

    /// @notice block threshold and tick diff threshold from prior specs
    uint256 public blockUpdateThreshold = 1;
    int24 public tickDiffThreshold = 1;

    /// @notice track last update block & tick
    mapping(bytes32 => uint256) public lastOracleUpdateBlock;
    mapping(bytes32 => int24)   public lastOracleTick;

    /// @dev Emitted whenever we do an actual oracle update
    event OracleUpdated(bytes32 indexed poolIdHash, int24 oldTick, int24 newTick);

    /// @param _manager The Uniswap V4 manager to read current tick from
    /// @param _truncGeoOracleMulti The external oracle for updateObservation
    constructor(IPoolManager _manager, address _truncGeoOracleMulti) {
        manager = _manager;
        truncGeoOracleMulti = ITruncGeoOracleMulti(_truncGeoOracleMulti);
    }

    /**
     * @notice updates the oracle observation if block/tick thresholds are met
     * @param key The PoolKey used to derive poolId
     */
    function updateOracleWithThrottle(PoolKey calldata key) external {
        if (!_shouldUpdateOracle(key)) {
            return; 
        }
        // do the actual update
        truncGeoOracleMulti.updateObservation(key);

        PoolId pid = PoolIdLibrary.toId(key);
        bytes32 idHash = PoolId.unwrap(pid);
        int24 oldTick = lastOracleTick[idHash];

        // get new current tick from manager
        (uint160 sqrtPriceX96, int24 currentTick, , ) = StateLibrary.getSlot0(manager, pid);

        lastOracleUpdateBlock[idHash] = block.number;
        lastOracleTick[idHash] = currentTick;

        emit OracleUpdated(idHash, oldTick, currentTick);
    }

    /**
     * @notice checks if block and tick thresholds are met
     * @param key The PoolKey
     * @return bool - true if we should update
     */
    function _shouldUpdateOracle(PoolKey calldata key) internal view returns (bool) {
        PoolId pid = PoolIdLibrary.toId(key);
        bytes32 idHash = PoolId.unwrap(pid);
        uint256 lastBlockUpdate = lastOracleUpdateBlock[idHash];
        
        // First update or enough blocks have passed - always update
        if (lastBlockUpdate == 0 || block.number >= lastBlockUpdate + blockUpdateThreshold) {
            return true;
        }
        
        // If not enough blocks have passed, check the tick difference
        (uint160 sqrtPriceX96, int24 currentTick, , ) = StateLibrary.getSlot0(manager, pid);
        int24 lastTick = lastOracleTick[idHash];
        
        // Calculate absolute difference between ticks
        uint24 tickDiff = _absDiff(currentTick, lastTick);
        
        // Debug log for DEVELOPMENT ONLY - can be removed for production
        // log_named_uint("tickDiff", tickDiff);
        // log_named_uint("tickDiffThreshold", uint24(tickDiffThreshold));
        
        // If tick difference is significant, we should update
        if (tickDiff >= uint24(tickDiffThreshold)) {
            return true;
        }
        
        // Default case: don't update
        return false;
    }

    /**
     * @notice simple abs difference for int24
     * @return diff Absolute difference as uint24 (always positive)
     */
    function _absDiff(int24 a, int24 b) private pure returns (uint24) {
        if (a >= b) {
            return uint24(uint24(a) - uint24(b));
        } else {
            return uint24(uint24(b) - uint24(a));
        }
    }

    /// @dev setter for blockUpdateThreshold
    function setBlockUpdateThreshold(uint256 newThreshold) external {
        // For demonstration, no access control
        blockUpdateThreshold = newThreshold;
    }

    /// @dev setter for tickDiffThreshold
    function setTickDiffThreshold(int24 newDiff) external {
        // For demonstration, no access control
        tickDiffThreshold = newDiff;
    }
} 