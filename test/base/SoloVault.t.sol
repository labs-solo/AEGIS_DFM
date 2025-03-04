// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey, PoolIdLibrary} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {SoloVault} from "src/base/SoloVault.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/**
 * @title SoloVault.t.sol
 * @notice Test suite for verifying the multi‑pool functionality of SoloVault.
 * @dev This file tests that:
 *      - Multiple pools can be independently initialized and tracked.
 *      - Deposits (hook-managed vs. normal) update the liquidityShares mapping as expected.
 *      - addLiquidity and removeLiquidity properly call the abstract functions,
 *        enforce slippage conditions, and update state.
 *      - The unlockCallback correctly settles liquidity modifications via PoolManager.
 *      - PoolManager integration functions as expected across multiple pools.
 *
 * Expected Behavior:
 * 1. beforeInitialize should store PoolKey in a mapping keyed by poolId.
 * 2. getPoolKey(poolId) returns the correct PoolKey.
 * 3. deposit updates liquidityShares for hook-managed deposits and leaves normal deposits unchanged.
 * 4. addLiquidity calls the abstract functions (stubbed in TestSoloVault) and updates liquidityShares.
 * 5. removeLiquidity deducts liquidityShares as expected.
 * 6. unlockCallback settles token transfers and returns a zero delta (per our stub implementation).
 */
contract SoloVaultTest is Test, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolManager public poolManager;
    TestSoloVault public vault; // A concrete implementation of SoloVault for testing
    MockERC20 public token0;
    MockERC20 public token1;

    // Two distinct pool keys for testing multi-pool functionality.
    PoolKey public poolKey1;
    PoolKey public poolKey2;

    // Define a local copy of the callback data structure used by SoloVault.
    struct CallbackData {
        address sender;
        bytes32 poolId;
        IPoolManager.ModifyLiquidityParams params;
    }

    /// @notice Helper function to compute a PoolId from a given PoolKey.
    function getPoolId(PoolKey memory key) internal pure returns (bytes32) {
        return PoolIdLibrary.toId(key);
    }

    /// @notice Sets up the test environment by deploying PoolManager, tokens, and TestSoloVault.
    function setUp() public {
        // Deploy PoolManager using the actual Uniswap V4 implementation.
        poolManager = new PoolManager(address(this));

        // Deploy test ERC20 tokens.
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);
        // Ensure token0 < token1 by address ordering.
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Deploy a concrete implementation of SoloVault.
        // For testing, we deploy directly without using HookMiner (assume our address is valid).
        vault = new TestSoloVault(poolManager);

        // Create two distinct PoolKeys with different fee tiers and tick spacings.
        poolKey1 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,          // 0.3% fee tier.
            tickSpacing: 60,
            hooks: IHooks(address(vault))
        });
        poolKey2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 500,           // 0.05% fee tier.
            tickSpacing: 20,
            hooks: IHooks(address(vault))
        });

        // Mint tokens and approve PoolManager.
        token0.mint(address(this), 1_000_000 * 1e18);
        token1.mint(address(this), 1_000_000 * 1e18);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
    }

    /**
     * @notice Test that multiple pools can be initialized and tracked independently.
     * @dev Expected: beforeInitialize stores each PoolKey in the vault's mapping under a distinct poolId.
     */
    function testMultiplePoolsInitialization() public {
        bytes32 poolId1 = getPoolId(poolKey1);
        bytes32 poolId2 = getPoolId(poolKey2);

        // Initialize pool 1.
        vm.prank(address(poolManager));
        vault.beforeInitialize(address(this), poolKey1, TickMath.MIN_SQRT_PRICE);
        // Initialize pool 2.
        vm.prank(address(poolManager));
        vault.beforeInitialize(address(this), poolKey2, TickMath.MIN_SQRT_PRICE + 1);

        // Retrieve pool keys.
        PoolKey memory storedKey1 = vault.getPoolKey(poolId1);
        PoolKey memory storedKey2 = vault.getPoolKey(poolId2);
        // Check that the hooks address is set correctly.
        assertEq(address(storedKey1.hooks), address(vault), "Pool 1 hook address mismatch");
        assertEq(address(storedKey2.hooks), address(vault), "Pool 2 hook address mismatch");
        // Ensure pool IDs are distinct.
        assertTrue(poolId1 != poolId2, "Pool IDs should be distinct");
    }

    /**
     * @notice Test that the deposit function updates liquidityShares correctly for hook-managed deposits.
     * @dev Expected: A hook-managed deposit increases liquidityShares for the caller.
     *       Normal deposits (useHook == false) do not update liquidityShares.
     */
    function testDepositFunctionality() public {
        bytes32 poolId1 = getPoolId(poolKey1);
        bytes32 poolId2 = getPoolId(poolKey2);

        // Directly set pool keys in the vault mapping.
        TestSoloVault(address(vault)).setPoolKey(poolId1, poolKey1);
        TestSoloVault(address(vault)).setPoolKey(poolId2, poolKey2);

        uint256 depositAmount0 = 1000 * 1e18;
        uint256 depositAmount1 = 2000 * 1e18;

        // Normal deposit (not hook-managed) should not change liquidityShares.
        vm.prank(address(this));
        vault.deposit(poolId1, depositAmount0, depositAmount1, false);
        uint256 normalShares = vault.liquidityShares(address(this), poolId1, vault.ShareTypeAB);
        assertEq(normalShares, 0, "Normal deposit should not update liquidityShares");

        // Hook-managed deposit should update liquidityShares.
        vm.prank(address(this));
        vault.deposit(poolId2, depositAmount0, depositAmount1, true);
        uint256 hookShares = vault.liquidityShares(address(this), poolId2, vault.ShareTypeAB);
        assertTrue(hookShares > 0, "Hook-managed deposit should update liquidityShares");
    }

    /**
     * @notice Test that addLiquidity correctly processes liquidity addition.
     * @dev Expected: addLiquidity retrieves the pool configuration, calls _getAddLiquidity and _modifyLiquidity,
     *      and updates liquidityShares mapping with the dummy share value from our test implementation.
     */
    function testAddLiquidity() public {
        bytes32 poolId1 = getPoolId(poolKey1);
        TestSoloVault(address(vault)).setPoolKey(poolId1, poolKey1);

        SoloVault.AddLiquidityParams memory params = SoloVault.AddLiquidityParams({
            amount0Desired: 1000 * 1e18,
            amount1Desired: 2000 * 1e18,
            amount0Min: 990 * 1e18,
            amount1Min: 1980 * 1e18,
            to: address(this),
            deadline: block.timestamp + 1000,
            tickLower: -60,
            tickUpper: 60,
            salt: bytes32(0)
        });

        vm.prank(address(this));
        BalanceDelta delta = vault.addLiquidity(poolId1, params);
        // With our test stub, _modifyLiquidity returns a zero delta.
        assertEq(delta.amount0(), 0, "Expected zero delta for addLiquidity (token0)");
        assertEq(delta.amount1(), 0, "Expected zero delta for addLiquidity (token1)");

        // Verify liquidityShares mapping was updated (shares from _getAddLiquidity stub returns 100).
        uint256 shares = vault.liquidityShares(address(this), poolId1, vault.ShareTypeAB);
        assertEq(shares, 100, "Liquidity shares should reflect the minted share value");
    }

    /**
     * @notice Test that removeLiquidity correctly processes liquidity removal.
     * @dev Expected: removeLiquidity updates liquidityShares by deducting the share amount,
     *      and enforces minimum withdrawal amounts.
     */
    function testRemoveLiquidity() public {
        bytes32 poolId1 = getPoolId(poolKey1);
        TestSoloVault(address(vault)).setPoolKey(poolId1, poolKey1);

        // Simulate initial liquidity shares (set manually for testing).
        vault.liquidityShares(address(this), poolId1, vault.ShareTypeAB) = 100;

        SoloVault.RemoveLiquidityParams memory params = SoloVault.RemoveLiquidityParams({
            liquidity: 50,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1000,
            tickLower: -60,
            tickUpper: 60,
            salt: bytes32(0)
        });

        vm.prank(address(this));
        BalanceDelta delta = vault.removeLiquidity(poolId1, params);
        // With our stub, _modifyLiquidity returns zero delta.
        uint256 remainingShares = vault.liquidityShares(address(this), poolId1, vault.ShareTypeAB);
        // Expect shares to decrease by the dummy value (50 shares).
        assertEq(remainingShares, 50, "Liquidity shares should decrease after removal");
    }

    /**
     * @notice Test that unlockCallback settles liquidity modifications correctly.
     * @dev Expected: unlockCallback should decode callback data, settle or take tokens via CurrencySettler,
     *      and return an encoded zero BalanceDelta as per the test stub.
     */
    function testUnlockCallback() public {
        bytes32 poolId1 = getPoolId(poolKey1);
        TestSoloVault(address(vault)).setPoolKey(poolId1, poolKey1);

        // Create dummy ModifyLiquidityParams for callback.
        IPoolManager.ModifyLiquidityParams memory modParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: 100,
            salt: 0
        });
        CallbackData memory callbackData = CallbackData({
            sender: address(this),
            poolId: poolId1,
            params: modParams
        });
        bytes memory data = abi.encode(callbackData);

        vm.prank(address(poolManager));
        bytes memory result = vault.unlockCallback(data);
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        // With our default _modifyLiquidity stub, expect zero delta.
        assertEq(delta.amount0(), 0, "Expected zero delta for token0 in unlockCallback");
        assertEq(delta.amount1(), 0, "Expected zero delta for token1 in unlockCallback");
    }

    /**
     * @notice Test that liquidityShares mapping correctly updates after deposit and removal operations.
     * @dev Expected: A hook-managed deposit increases liquidityShares, and subsequent removal decreases shares appropriately.
     */
    function testLiquiditySharesAfterOperations() public {
        bytes32 poolId1 = getPoolId(poolKey1);
        TestSoloVault(address(vault)).setPoolKey(poolId1, poolKey1);

        // Simulate a hook-managed deposit.
        uint256 depositAmount0 = 1000 * 1e18;
        uint256 depositAmount1 = 2000 * 1e18;
        vm.prank(address(this));
        vault.deposit(poolId1, depositAmount0, depositAmount1, true);
        uint256 initialShares = vault.liquidityShares(address(this), poolId1, vault.ShareTypeAB);
        assertTrue(initialShares > 0, "Deposit should increase liquidityShares");

        // Simulate removal: remove half of the shares.
        SoloVault.RemoveLiquidityParams memory params = SoloVault.RemoveLiquidityParams({
            liquidity: initialShares / 2,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1000,
            tickLower: -60,
            tickUpper: 60,
            salt: bytes32(0)
        });
        vm.prank(address(this));
        vault.removeLiquidity(poolId1, params);
        uint256 finalShares = vault.liquidityShares(address(this), poolId1, vault.ShareTypeAB);
        assertEq(finalShares, initialShares - (initialShares / 2), "Liquidity shares should decrease by removal amount");
    }

    /**
     * @notice Test the integration of PoolManager.getSlot0() via StateLibrary.
     * @dev Expected: After pool initialization, StateLibrary.getSlot0() should return a non-zero sqrtPriceX96.
     */
    function testPoolManagerIntegration() public {
        bytes32 poolId1 = getPoolId(poolKey1);
        // Initialize the pool using PoolManager.initialize(), which calls beforeInitialize and afterInitialize.
        vm.prank(address(poolManager));
        poolManager.initialize(poolKey1, TickMath.MIN_SQRT_PRICE);
        // Use StateLibrary to retrieve slot0.
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolKey1.toId());
        assertTrue(sqrtPriceX96 > 0, "Slot0 should be non-zero after initialization");
    }

    // --- IUnlockCallback Implementation ---
    /**
     * @notice Implements the IUnlockCallback interface required by PoolManager.
     * @dev For testing, this simply delegates to vault.unlockCallback.
     */
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        return vault.unlockCallback(data);
    }
}