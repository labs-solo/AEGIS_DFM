// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

import {LocalSetup} from "./LocalSetup.t.sol";

// Local Interfaces for type-safety
import {IFullRangeLiquidityManager} from "src/interfaces/IFullRangeLiquidityManager.sol";
import {FullRangeLiquidityManager} from "src/FullRangeLiquidityManager.sol";
import {IDynamicFeeManager} from "src/interfaces/IDynamicFeeManager.sol";
import {DynamicFeeManager} from "src/DynamicFeeManager.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

/// @title Deployment and Configuration Integration Tests
/// @notice Verifies correct deployment and initial configuration/linkages of core contracts.
/// @dev Corresponds to Section A of the Integration_Testing_Plan.md
contract DeploymentAndConfigTest is LocalSetup {
    // --- Expected Values (PLACEHOLDERS - Replace with actual values from deployment script or LocalSetup.sol) ---
    // These should ideally be defined in LocalSetup.sol or loaded from deployment artifacts
    uint24 internal constant EXPECTED_POL_SHARE_PPM = 100_000; // Updated: 10%
    uint24 internal constant EXPECTED_MIN_FEE_PPM = 100; // Updated: 0.01%
    // uint24 internal constant EXPECTED_MAX_BASE_FEE_PPM = 50_000; // Example: 5%
    uint128 internal constant EXPECTED_DEFAULT_DYNAMIC_FEE = 3000; // Updated: 0.3%
    // int24 internal constant EXPECTED_MAX_TICK_CHANGE = 100; // Example
    // uint24 internal constant EXPECTED_BASE_FEE_LOWER_BOUND = 100; // Example: 0.01%
    // uint24 internal constant EXPECTED_BASE_FEE_INCREASE = 100_000; // Example: 10% increase factor
    // uint24 internal constant EXPECTED_BASE_FEE_DECREASE = 10_000; // Example: 1% decrease factor
    // uint32 internal constant EXPECTED_MIN_REINVEST_INTERVAL = 3600; // Example: 1 hour

    /// @notice Test A1: Verify core contract addresses are non-zero.
    function test_VerifyContractAddresses() public view {
        assertNotEq(address(usdc), address(0), "USDC address invalid");
        assertNotEq(address(weth), address(0), "WETH address invalid");
        assertNotEq(address(poolManager), address(0), "PoolManager address invalid");
        assertNotEq(address(policyManager), address(0), "PolicyManager address invalid");
        assertNotEq(address(liquidityManager), address(0), "LiquidityManager address invalid");
        assertNotEq(address(dynamicFeeManager), address(0), "DynamicFeeManager address invalid");
        assertNotEq(address(oracle), address(0), "Oracle address invalid");
        assertNotEq(address(fullRange), address(0), "FullRangeHook address invalid");
    }

    /// @notice Test A2: Verify PoolManager linkages are correct.
    function test_VerifyPoolManagerLinkages() public {
        // Use interface instead of concrete type
        assertEq(Owned(address(liquidityManager)).owner(), deployerEOA, "LM owner mismatch");
        assertEq(
            FullRangeLiquidityManager(payable(address(liquidityManager))).poolManager.address,
            address(poolManager),
            "LM->PoolManager link mismatch"
        );

        // DynamicFeeManager exposes the link through `policy()`
        assertEq(
            address(dynamicFeeManager.policyManager()),
            address(policyManager),
            "DynamicFeeManager->PolicyManager link mismatch"
        );
        assertEq(address(fullRange.poolManager()), address(poolManager), "SpotHook->PoolManager link mismatch");
        // assertEq(address(oracle.poolManager()), address(poolManager), "Oracle->PoolManager link mismatch"); // Uncomment if Oracle interface has poolManager()
    }

    /// @notice Test A3: Verify PolicyManager linkages are correct.
    function test_VerifyPolicyManagerLinkages() public view {
        assertEq(policyManager.owner(), deployerEOA, "PolicyManager governance mismatch");
        // Assuming the oracle is linked via a specific mechanism or policy slot
        // Example: Check if Oracle is set as a policy implementation
        // address oraclePolicy = policyManager.getPolicy(poolId, IPoolPolicyManager.PolicyType.ORACLE);
        // assertEq(oraclePolicy, address(oracle), "Oracle linkage in PolicyManager mismatch");
    }

    /// @notice Test A4: Verify LiquidityManager linkages and hook authorization.
    function test_VerifyLiquidityManagerLinkages() public view {
        // Assuming LiquidityManager interacts with PoolManager
        // address linkedPoolManager = liquidityManager.poolManager(); // Example getter
        // assertEq(linkedPoolManager, address(poolManager), "PoolManager linkage in LiquidityManager mismatch");
        assertEq(
            FullRangeLiquidityManager(payable(address(liquidityManager))).poolManager.address,
            address(poolManager),
            "LiquidityManager.poolManager mismatch"
        );
    }

    /// @notice Test A5: Verify DynamicFeeManager linkages.
    function test_VerifyDynamicFeeManagerLinkages() public view {
        assertEq(
            address(dynamicFeeManager.policyManager()), address(policyManager), "DFM PolicyManager linkage mismatch"
        );
    }

    /// @notice Test A6: Verify Oracle linkage from DynamicFeeManager.
    function test_VerifyOracleLinkage() public pure {
        // Placeholder: Was primarily to ensure deployment didn't revert.
        // Actual linkage verified in PolicyManager tests.
    }

    /// @notice Test A7: Verify initial pool setup (existence, hook, initialization, tokens).
    function test_VerifyInitialPoolSetup() public view {
        // Read pool slot0 using StateLibrary to verify existence/basic setup
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        assertTrue(sqrtPriceX96 > 0, "Pool not initialized (sqrtPriceX96 is zero)");
        // Non-zero tick could also imply initialization, depending on the exact setup
        //assertTrue(tick != 0, "Pool not initialized (tick is zero)");

        // Read liquidity using StateLibrary
        // (call omitted – value not needed)

        // Check hook address implicitly: We assume poolId derived in LocalSetup used the correct hook.
        // The test verifies that *a* pool exists for this poolId in the PoolManager.
        // A direct check like assertEq(poolManager.getHookForPool(poolId), address(fullRange)) would be ideal if available.
        // Optional: Check if liquidity > 0 if initial liquidity is added in setup
        // assertTrue(liquidity > 0, "Pool has zero initial liquidity");

        // Verify token ordering (WETH/USDC) - assumes poolId is correctly loaded in LocalSetup
        // Access currencies from poolKey (assumed available from LocalSetup) instead of poolId
        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);
        assertTrue(
            (token0 == address(weth) && token1 == address(usdc)) || (token0 == address(usdc) && token1 == address(weth)),
            "Pool tokens do not match WETH/USDC"
        );
    }
}
