// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolPolicy} from "../../src/interfaces/IPoolPolicy.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/*  VERY-LIGHT policy stub – **does not** inherit the full interface       */
/*  (only selectors the oracle touches are implemented).                   */
/* ----------------------------------------------------------------------- */
contract MockPolicyManager is IPoolPolicy {
    uint32  internal constant STEP      = 20_000;   // 2 %
    uint32  internal constant INTERVAL  = 1 days;
    uint24  internal constant DEF_CAP   = 50;
    uint256 internal constant DEF_FEE   = 5_000;

    /* ------------------------------------------------------------------ */
    /*                     simple allow-lists for tests                    */
    /* ------------------------------------------------------------------ */
    mapping(uint24 => bool) private _tickSupported;
    mapping(address => bool) private _currencySupported;

    constructor() {
        // tick-spacing used in the test poolKey
        _tickSupported[60] = true;
        // currencies used in the test poolKey
        _currencySupported[address(0xA11CE)] = true;
        _currencySupported[address(0xB0B  )] = true;
    }

    // --- Functions already implemented (or deprecated) ---
    function getBaseFeeStepPpm(PoolId)                     external pure override returns (uint32)  { return STEP; } // Deprecated but present
    function getMaxStepPpm(PoolId)                         external pure override returns (uint32)  { return STEP; } // Deprecated but present
    function getBaseFeeUpdateIntervalSeconds(PoolId)       external pure override returns (uint32)  { return INTERVAL; } // Deprecated but present
    function getDefaultMaxTicksPerBlock(PoolId)            external view override returns (uint24)  { return DEF_CAP; }
    function getDefaultDynamicFee()                        external view override returns (uint256) { return DEF_FEE; }
    function isTickSpacingSupported(uint24 tickSpacing) external view override returns (bool) {
        return _tickSupported[tickSpacing];
    }
    function isSupportedCurrency(Currency currency) external view override returns (bool) {
        return _currencySupported[Currency.unwrap(currency)];
    }

    // --- Stubs for missing IPoolPolicy functions ---
    function getSoloGovernance() external view override returns (address) { return address(0); }
    function initializePolicies(PoolId, address, address[] calldata) external override {} 
    function handlePoolInitialization(PoolId, PoolKey calldata, uint160, int24, address) external override {}
    function getPolicy(PoolId, PolicyType) external view override returns (address implementation) { return address(0); }
    function getFeeAllocations(PoolId)
        external view override
        returns (uint256 polShare, uint256 fullRangeShare, uint256 lpShare) { return (0, 0, 0); }
    function getMinimumPOLTarget(PoolId, uint256, uint256)
        external view override
        returns (uint256) { return 0; }
    function getMinimumTradingFee() external view override returns (uint256) { return 0; }
    function getFeeClaimThreshold() external view override returns (uint256) { return 0; }
    function getPoolPOLMultiplier(PoolId) external view override returns (uint256) { return 0; }
    function setFeeConfig(uint256, uint256, uint256, uint256, uint256, uint256) external override {}
    function setPoolPOLMultiplier(PoolId, uint32) external override {}
    function setDefaultPOLMultiplier(uint32) external override {}
    function setPoolPOLShare(PoolId, uint256) external override {}
    function setPoolSpecificPOLSharingEnabled(bool) external override {}
    function getPoolPOLShare(PoolId) external view override returns (uint256) { return 0; }
    function getTickScalingFactor() external view override returns (int24) { return 0; }
    function updateSupportedTickSpacing(uint24, bool) external override {}
    function batchUpdateAllowedTickSpacings(uint24[] calldata, bool[] calldata) external override {}
    function isValidVtier(uint24, int24) external view override returns (bool) { return true; } // Assume valid for tests
    function getProtocolFeePercentage(PoolId) external view override returns (uint256 feePercentage) { return 0; }
    function getFeeCollector() external view override returns (address) { return address(0); }
    function getSurgeDecayPeriodSeconds(PoolId) external view override returns (uint256) { return 0; }
    function getTargetCapsPerDay(PoolId) external view override returns (uint32) { return 0; }
    function getDailyBudgetPpm(PoolId) external view override returns (uint32) { return 0; }
    function getCapBudgetDecayWindow(PoolId) external view override returns (uint32) { return 0; }
    function getFreqScaling(PoolId) external view override returns (uint256) { return 0; }
    function getMinBaseFee(PoolId) external view override returns (uint256) { return 0; }
    function getMaxBaseFee(PoolId) external view override returns (uint256) { return 0; }
    function getSurgeFeeMultiplierPpm(PoolId) external view override returns (uint24) { return 0; }
    function getSurgeDecaySeconds(PoolId) external view override returns (uint32) { return 0; }
    function getBudgetAndWindow(PoolId) external view override returns (uint32 budgetPerDay, uint32 decayWindow) { return (0,0); }
} 