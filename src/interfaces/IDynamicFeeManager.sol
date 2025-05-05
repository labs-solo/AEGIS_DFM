// SPDX-License-Identifier:	BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolPolicy} from "./IPoolPolicy.sol";

/**
 * @title IDynamicFeeManager
 * @notice Minimal interface for a gas-lean dynamic-fee manager.
 *
 * Any hook that wants surge / CAP accounting MUST:
 *  • call `initialize` once (factory/deployer)
 *  • call `notifyOracleUpdate(poolId, tickWasCapped)` on	every	swap
 */
interface IDynamicFeeManager {
    /* ─────── Events ───────────────────────────────────────────────────── */

    /**
     * @notice Emitted whenever the fee state changes.
     * @param poolId       Pool identifier
     * @param baseFeePpm   New base-fee (parts-per-million)
     * @param surgeFeePpm  New surge-fee (ppm, may be zero). Note: Value is as of emission block timestamp;
     *                     client-side recalculation might differ slightly if block timestamp changes post-transaction.
     * @param inCapEvent   True if the pool is currently in a CAP event window
     * @param timestamp    Emission block timestamp
     */
    event FeeStateChanged(
        PoolId indexed poolId,
        uint256 baseFeePpm,
        uint256 surgeFeePpm,
        bool inCapEvent,
        uint32 timestamp
    );

    /* ─────── Mutators (called by hook / factory) ──────────────────────── */

    /**
     * @notice One-shot pool bootstrap.  SHOULD be called by the factory.
     * @param poolId      Pool identifier
     * @param initialTick Current oracle tick at pool creation (passed through
     *                    for analytics; the manager itself ignores it).
     */
    function initialize(PoolId poolId, int24 initialTick) external;

    /**
     * @notice Hot-path update called by the hook once per swap.
     * @param poolId         Pool identifier
     * @param tickWasCapped  True if the hook had to cap the tick change
     */
    function notifyOracleUpdate(PoolId poolId, bool tickWasCapped) external;

    /* ─────── Views ────────────────────────────────────────────────────── */

    /**
     * @return baseFee  current base fee (ppm)
     * @return surgeFee current surge fee (ppm)
     */
    function getFeeState(PoolId poolId) external view returns (uint256 baseFee, uint256 surgeFee);

    /**
     * @return True if the pool is in a CAP event right now.
     */
    function isCAPEventActive(PoolId poolId) external view returns (bool);

    /// @notice Pool-level policy contract that drives fee parameters
    function policy() external view returns (IPoolPolicy);

    /// @notice The hook that is authorized to call this contract
    function authorizedHook() external view returns (address);

    // ── ✂───────────────────────────────────────────────────────────────
    //  The old alias is now removed – call-sites must use `policy()`.
    // ───────────────────────────────────────────────────────────────────
}
