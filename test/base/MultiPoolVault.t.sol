// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey, PoolIdLibrary} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ExtendedBaseHook} from "src/base/SoloVault.sol"; // Note: SoloVault now extends ExtendedBaseHook
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/**
 * @title MultiPoolVault.t.sol
 * @notice Test suite for verifying that SoloVault (the updated ExtendedBaseHook contract)
 *         can manage liquidity for multiple pools.
 *
 * @dev The tests below are designed to work with the actual PoolManager and Uniswap V4 files.
 *      They stub out test scenarios to ensure that:
 *      - Multiple pools can be initialized.
 *      - Liquidity deposits and withdrawals are tracked separately per pool.
 *      - State updates for each pool do not conflict.
 *
 *      The tests are written in plain English and with NatSpec comments to guide future development.
 */
contract MultiPoolVaultTest is Test {
    PoolManager public poolManager;
    SoloVault public vault;
    MockERC20 public token0;
    MockERC20 public token1;

    // Two different pool configurations for testing multi-pool functionality
    PoolKey public poolKey1;
    PoolKey public poolKey2;

    // Helper: compute PoolId using PoolIdLibrary (assumes PoolKey has a toId() method)
    function getPoolId(PoolKey memory key) internal pure returns (bytes32) {
        return PoolIdLibrary.toId(key);
    }

    function setUp() public {
        // Deploy the actual PoolManager from Uniswap V4
        poolManager = new PoolManager(address(this));

        // Deploy two test tokens
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);

        // Deploy our SoloVault contract (which now inherits from ExtendedBaseHook)
        vault = new SoloVault(poolManager);

        // Initialize two distinct pool keys with different parameters.
        // In a production multi-pool setup, these would be stored in a mapping keyed by PoolId.
        poolKey1 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,           // 0.3% fee tier
            tickSpacing: 60,
            hooks: IHooks(address(vault))
        });
        poolKey2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 500,            // 0.05% fee tier (different from poolKey1)
            tickSpacing: 20,
            hooks: IHooks(address(vault))
        });

        // The following steps simulate pool initialization for both pools.
        // In the future, the contract should be refactored to use a mapping of pool keys.
        // For now, we can assume that separate calls to beforeInitialize and afterInitialize are made per pool.
    }

    /**
     * @notice Test that multiple pools can be initialized and tracked independently.
     * @dev This test initializes two pools and checks that their PoolIds differ.
     */
    function testMultiplePoolsInitialization() public {
        // Initialize pool 1
        vm.prank(address(poolManager));
        bytes4 initSelector1 = vault.beforeInitialize(address(this), poolKey1, 1000);
        assertEq(initSelector1, IHooks.beforeInitialize.selector);

        // Initialize pool 2 (simulate a different pool by using a different PoolKey)
        vm.prank(address(poolManager));
        bytes4 initSelector2 = vault.beforeInitialize(address(this), poolKey2, 2000);
        assertEq(initSelector2, IHooks.beforeInitialize.selector);

        // Check that the derived PoolIds are different
        bytes32 poolId1 = getPoolId(poolKey1);
        bytes32 poolId2 = getPoolId(poolKey2);
        assertTrue(poolId1 != poolId2, "PoolIds should be distinct");
    }

    /**
     * @notice Test that liquidity deposits for different pools are tracked separately.
     * @dev This stub test should verify that a deposit in pool 1 does not affect liquidity shares in pool 2.
     */
    function testSeparateLiquidityDeposits() public {
        // Initialize pool 1 and pool 2 (simulate initialization)
        vm.prank(address(poolManager));
        vault.beforeInitialize(address(this), poolKey1, 1000);
        vm.prank(address(poolManager));
        vault.beforeInitialize(address(this), poolKey2, 2000);

        // Simulate a deposit into pool 1:
        // For testing purposes, we assume the addLiquidity function works and returns a non-zero BalanceDelta.
        // In a full test, you would call vault.addLiquidity with proper parameters.
        // Here we simply stub the call and assume deposits are tracked per pool.
        // (This is where you would assert that the liquidityShares mapping for poolId1 increases, 
        // and that poolId2 remains unchanged.)
    }

    /**
     * @notice Test that removals from one pool do not affect the state of another pool.
     * @dev This stub test should simulate liquidity removal from pool 1 and then verify that pool 2's
     *      liquidity remains intact.
     */
    function testSeparateLiquidityRemovals() public {
        // Initialize both pools
        vm.prank(address(poolManager));
        vault.beforeInitialize(address(this), poolKey1, 1000);
        vm.prank(address(poolManager));
        vault.beforeInitialize(address(this), poolKey2, 2000);

        // Stub liquidity deposit in both pools, then remove liquidity from pool 1.
        // Verify that pool 2's state (such as total liquidity and share balances) remains unchanged.
    }

    /**
     * @notice Test that PoolManager integration works correctly for multiple pools.
     * @dev This test should invoke PoolManager functions (e.g., getSlot0, modifyLiquidity) for different pools
     *      and verify that the operations affect only the targeted pool.
     */
    function testPoolManagerIntegration() public {
        // For each pool, call poolManager.getSlot0() using the poolKey and verify that the returned state is as expected.
        // This is a stub test. In a full implementation, deploy two pools and perform actual liquidity operations.
    }

    /**
     * @notice Test that normal deposits (bypassing hook-controlled liquidity) are handled separately.
     * @dev This test should simulate a "normal" deposit via PoolManager directly and verify that the SoloVault's
     *      internal custom deposit logic is not triggered.
     */
    function testNormalDeposits() public {
        // Simulate a deposit not using the hookData flag for hook-managed deposits.
        // Verify that state updates are applied through PoolManager only.
    }

    /**
     * @notice Test that hook-managed deposits (with deposit indicator flag) correctly classify deposits.
     * @dev This test should simulate a hook-managed deposit and then verify that liquidity shares are minted
     *      as A, B, or AB shares based on the deposit composition.
     */
    function testHookManagedDepositClassification() public {
        // Simulate a deposit with a hookData indicator flag set to true.
        // Verify that the deposit is classified as either A, B, or AB shares.
    }
}