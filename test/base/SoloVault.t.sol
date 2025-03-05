// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey, PoolIdLibrary} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {SoloVault} from "src/base/SoloVault.sol";
import {ExtendedBaseHook} from "src/base/ExtendedBaseHook.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/**
 * @title SoloVaultTest
 * @notice Tests for SoloVault
 */
contract SoloVaultTest is Test, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    // ----------------------
    // Core and Mocks
    // ----------------------
    PoolManager public poolManager;
    SoloVault public vault;
    MockERC20 public token0;
    MockERC20 public token1;

    address public user; // The address that will hold tokens and call the vault

    // Two pool configurations
    PoolKey public poolKey1;
    PoolKey public poolKey2;

    // Ticks used
    int24 constant MIN_TICK = -120;
    int24 constant MAX_TICK = 120;

    // Share types
    uint8 constant SHARE_TYPE_A = 1;
    uint8 constant SHARE_TYPE_B = 2;
    uint8 constant SHARE_TYPE_AB = 0;

    // ----------------------
    // Setup
    // ----------------------

    function setUp() public {
        // 1) Deploy pool manager
        poolManager = new PoolManager(address(this));

        // 2) Deploy tokens
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);
        // enforce ordering
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // 3) Create a user address (this is the real EOA in tests)
        user = makeAddr("User");

        // Mint tokens to that user
        token0.mint(user, 100e18);
        token1.mint(user, 100e18);

        // 4) Deploy the vault (hook) via HookMiner
        uint160 flags =
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_DONATE_FLAG |
            Hooks.AFTER_DONATE_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(SoloVault).creationCode,
            abi.encode(address(poolManager))
        );
        vault = new SoloVault{salt: salt}(poolManager);
        assertEq(address(vault), hookAddress);

        // 5) Approvals from user => vault + poolManager
        vm.startPrank(user);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        // 6) Define two poolKeys
        poolKey1 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(vault))
        });
        poolKey2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 500,
            tickSpacing: 20,
            hooks: IHooks(address(vault))
        });
    }

    // implement IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        return vault.unlockCallback(data);
    }

    // Helper to get the poolId
    function getPoolId(PoolKey memory key) internal pure returns (bytes32) {
        return PoolId.unwrap(key.toId());
    }

    // ----------------------
    // Tests
    // ----------------------

    function testMultiplePoolsInitialization() public {
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));
        vm.prank(user);
        poolManager.initialize(poolKey2, uint160(1 << 96));

        bytes32 id1 = getPoolId(poolKey1);
        bytes32 id2 = getPoolId(poolKey2);

        PoolKey memory stored1 = vault.getPoolKey(id1);
        PoolKey memory stored2 = vault.getPoolKey(id2);
        assertEq(address(stored1.hooks), address(vault));
        assertEq(address(stored2.hooks), address(vault));
    }

    function testToken0Deposit() public {
        bytes32 poolId = getPoolId(poolKey1);
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));

        vm.startPrank(user);
        vault.deposit(poolId, 0.1 ether, 0);
        vm.stopPrank();

        uint256 shareA = vault.liquidityShares(user, poolId, SHARE_TYPE_A);
        assertEq(shareA, 0.1 ether);
    }

    function testToken1Deposit() public {
        bytes32 poolId = getPoolId(poolKey1);
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));

        vm.startPrank(user);
        vault.deposit(poolId, 0, 0.2 ether);
        vm.stopPrank();

        uint256 shareB = vault.liquidityShares(user, poolId, SHARE_TYPE_B);
        assertEq(shareB, 0.2 ether);
    }

    function testBothTokensDeposit() public {
        bytes32 poolId = getPoolId(poolKey1);
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));

        vm.startPrank(user);
        vault.deposit(poolId, 0.5 ether, 0.5 ether);
        vm.stopPrank();

        uint256 shareAB = vault.liquidityShares(user, poolId, SHARE_TYPE_AB);
        assertEq(shareAB, 1 ether);
    }

    // -----------
    // addLiquidity
    // -----------

    function testAddLiquiditySingleTokenA() public {
        bytes32 pid = getPoolId(poolKey1);
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));

        // deposit 0.08 token0
        SoloVault.AddLiquidityParams memory p = SoloVault.AddLiquidityParams({
            amount0Desired: 0.08 ether,
            amount1Desired: 0,
            amount0Min: 0.079 ether,
            amount1Min: 0,
            to: user,
            deadline: block.timestamp + 1000,
            tickLower: -120,
            tickUpper: -60,
            salt: bytes32("token0-only-test")
        });

        vm.startPrank(user);
        BalanceDelta delta = vault.addLiquidity(pid, p);
        vm.stopPrank();

        // Check user shares
        uint256 shareA = vault.liquidityShares(user, pid, SHARE_TYPE_A);
        assertEq(shareA, p.amount0Desired);

        // delta => user paying token0 => delta.amount0 < 0
        assertLt(delta.amount0(), 0);
        assertEq(delta.amount1(), 0);
    }

    function testAddLiquiditySingleTokenB() public {
        bytes32 pid = getPoolId(poolKey1);
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));

        // deposit 0.1 token1
        SoloVault.AddLiquidityParams memory p = SoloVault.AddLiquidityParams({
            amount0Desired: 0,
            amount1Desired: 0.1 ether,
            amount0Min: 0,
            amount1Min: 0.099 ether,
            to: user,
            deadline: block.timestamp + 1000,
            tickLower: 60,
            tickUpper: 120,
            salt: bytes32("token1-only-test")
        });

        vm.startPrank(user);
        BalanceDelta delta = vault.addLiquidity(pid, p);
        vm.stopPrank();

        // check user shares
        uint256 shareB = vault.liquidityShares(user, pid, SHARE_TYPE_B);
        assertEq(shareB, p.amount1Desired);

        // check delta
        assertEq(delta.amount0(), 0);
        assertLt(delta.amount1(), 0);
    }

    function testAddLiquidityFullRange() public {
        bytes32 pid = getPoolId(poolKey1);
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));

        // deposit 0.06 token0 + 0.04 token1
        SoloVault.AddLiquidityParams memory p = SoloVault.AddLiquidityParams({
            amount0Desired: 0.06 ether,
            amount1Desired: 0.04 ether,
            amount0Min: 0.058 ether,
            amount1Min: 0.038 ether,
            to: user,
            deadline: block.timestamp + 1000,
            tickLower: MIN_TICK,
            tickUpper: MAX_TICK,
            salt: bytes32("fullrange-test")
        });

        vm.startPrank(user);
        BalanceDelta delta = vault.addLiquidity(pid, p);
        vm.stopPrank();

        // we store shares as sqrt(...) in the code
        uint256 expectedShares = FixedPointMathLib.sqrt(0.06 ether * 0.04 ether);
        uint256 mintedAB = vault.liquidityShares(user, pid, SHARE_TYPE_AB);
        assertEq(mintedAB, expectedShares);
    }

    // -----------
    // removeLiquidity
    // -----------

    function testRemoveLiquidity() public {
        // 1) initialize
        bytes32 pid = getPoolId(poolKey1);
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));

        // 2) add some full-range
        SoloVault.AddLiquidityParams memory ap = SoloVault.AddLiquidityParams({
            amount0Desired: 0.1 ether,
            amount1Desired: 0.1 ether,
            amount0Min: 0.09 ether,
            amount1Min: 0.09 ether,
            to: user,
            deadline: block.timestamp + 1000,
            tickLower: MIN_TICK,
            tickUpper: MAX_TICK,
            salt: bytes32("removal-test")
        });
        vm.startPrank(user);
        vault.addLiquidity(pid, ap);
        vm.stopPrank();

        uint256 mintedAB = vault.liquidityShares(user, pid, SHARE_TYPE_AB);
        assertTrue(mintedAB > 0);

        // 3) remove half
        SoloVault.RemoveLiquidityParams memory rp = SoloVault.RemoveLiquidityParams({
            liquidity: mintedAB / 2,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1000,
            tickLower: MIN_TICK,
            tickUpper: MAX_TICK,
            salt: bytes32("removal-test")
        });

        vm.startPrank(user);
        BalanceDelta delta = vault.removeLiquidity(pid, rp);
        vm.stopPrank();

        // confirm user AB shares updated
        uint256 remaining = vault.liquidityShares(user, pid, SHARE_TYPE_AB);
        assertEq(remaining, mintedAB - rp.liquidity);
    }

    function testRemoveLiquiditySingleTokenA() public {
        bytes32 pid = getPoolId(poolKey1);
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));

        // deposit token0 only
        SoloVault.AddLiquidityParams memory ap = SoloVault.AddLiquidityParams({
            amount0Desired: 0.08 ether,
            amount1Desired: 0,
            amount0Min: 0.079 ether,
            amount1Min: 0,
            to: user,
            deadline: block.timestamp + 1000,
            tickLower: -120,
            tickUpper: -60,
            salt: bytes32("token0-removal-test")
        });
        vm.startPrank(user);
        vault.addLiquidity(pid, ap);
        vm.stopPrank();

        uint256 shares0 = vault.liquidityShares(user, pid, SHARE_TYPE_A);
        assertEq(shares0, 0.08 ether);

        // remove half
        SoloVault.RemoveLiquidityParams memory rp = SoloVault.RemoveLiquidityParams({
            liquidity: shares0 / 2,
            amount0Min: 0.039 ether,
            amount1Min: 0,
            deadline: block.timestamp + 1000,
            tickLower: -120,
            tickUpper: -60,
            salt: bytes32("token0-removal-test")
        });
        vm.startPrank(user);
        BalanceDelta delta = vault.removeLiquidity(pid, rp);
        vm.stopPrank();

        // check updated shares
        uint256 remainA = vault.liquidityShares(user, pid, SHARE_TYPE_A);
        assertEq(remainA, shares0 - rp.liquidity);
    }

    function testRemoveLiquiditySingleTokenB() public {
        bytes32 pid = getPoolId(poolKey1);
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));

        // deposit token1 only
        SoloVault.AddLiquidityParams memory ap = SoloVault.AddLiquidityParams({
            amount0Desired: 0,
            amount1Desired: 0.1 ether,
            amount0Min: 0,
            amount1Min: 0.099 ether,
            to: user,
            deadline: block.timestamp + 1000,
            tickLower: 60,
            tickUpper: 120,
            salt: bytes32("token1-removal-test")
        });
        vm.startPrank(user);
        vault.addLiquidity(pid, ap);
        vm.stopPrank();

        uint256 shares1 = vault.liquidityShares(user, pid, SHARE_TYPE_B);
        assertEq(shares1, 0.1 ether);

        // remove half
        SoloVault.RemoveLiquidityParams memory rp = SoloVault.RemoveLiquidityParams({
            liquidity: shares1 / 2,
            amount0Min: 0,
            amount1Min: 0.049 ether,
            deadline: block.timestamp + 1000,
            tickLower: 60,
            tickUpper: 120,
            salt: bytes32("token1-removal-test")
        });
        vm.startPrank(user);
        BalanceDelta delta = vault.removeLiquidity(pid, rp);
        vm.stopPrank();

        uint256 remainB = vault.liquidityShares(user, pid, SHARE_TYPE_B);
        assertEq(remainB, shares1 - rp.liquidity);
    }

    function testFailRemoveLiquidityInsufficientSharesA() public {
        bytes32 pid = getPoolId(poolKey1);
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));

        // deposit 0.08 token0
        SoloVault.AddLiquidityParams memory ap = SoloVault.AddLiquidityParams({
            amount0Desired: 0.08 ether,
            amount1Desired: 0,
            amount0Min: 0.079 ether,
            amount1Min: 0,
            to: user,
            deadline: block.timestamp + 1000,
            tickLower: -120,
            tickUpper: -60,
            salt: bytes32("token0-removal-test")
        });
        vm.prank(user);
        vault.addLiquidity(pid, ap);

        // attempt removing double
        SoloVault.RemoveLiquidityParams memory rp = SoloVault.RemoveLiquidityParams({
            liquidity: 0.16 ether,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1000,
            tickLower: -120,
            tickUpper: -60,
            salt: bytes32("token0-removal-test")
        });
        vm.prank(user);
        vault.removeLiquidity(pid, rp); // should revert
    }

    function testFailRemoveLiquidityInsufficientSharesB() public {
        bytes32 pid = getPoolId(poolKey1);
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));

        // deposit 0.1 token1
        SoloVault.AddLiquidityParams memory ap = SoloVault.AddLiquidityParams({
            amount0Desired: 0,
            amount1Desired: 0.1 ether,
            amount0Min: 0,
            amount1Min: 0.099 ether,
            to: user,
            deadline: block.timestamp + 1000,
            tickLower: 60,
            tickUpper: 120,
            salt: bytes32("token1-removal-test")
        });
        vm.prank(user);
        vault.addLiquidity(pid, ap);

        // try removing 0.2
        SoloVault.RemoveLiquidityParams memory rp = SoloVault.RemoveLiquidityParams({
            liquidity: 0.2 ether,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1000,
            tickLower: 60,
            tickUpper: 120,
            salt: bytes32("token1-removal-test")
        });
        vm.prank(user);
        vault.removeLiquidity(pid, rp); // revert
    }

    function testFailRemoveLiquidityInsufficientSharesAB() public {
        bytes32 pid = getPoolId(poolKey1);
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));

        // deposit 0.1 token0 + 0.1 token1
        SoloVault.AddLiquidityParams memory ap = SoloVault.AddLiquidityParams({
            amount0Desired: 0.1 ether,
            amount1Desired: 0.1 ether,
            amount0Min: 0.09 ether,
            amount1Min: 0.09 ether,
            to: user,
            deadline: block.timestamp + 1000,
            tickLower: MIN_TICK,
            tickUpper: MAX_TICK,
            salt: bytes32("removal-test")
        });
        vm.prank(user);
        vault.addLiquidity(pid, ap);

        uint256 ab = vault.liquidityShares(user, pid, SHARE_TYPE_AB);
        assertTrue(ab > 0);

        // attempt removing double
        SoloVault.RemoveLiquidityParams memory rp = SoloVault.RemoveLiquidityParams({
            liquidity: ab * 2,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1000,
            tickLower: MIN_TICK,
            tickUpper: MAX_TICK,
            salt: bytes32("removal-test")
        });
        vm.prank(user);
        vault.removeLiquidity(pid, rp);
    }

    // -----------
    // unlockCallback
    // -----------

    function testFullRangePositions() public {
        bytes32 pid = getPoolId(poolKey1);
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));

        // deposit 0.04 + 0.06
        SoloVault.AddLiquidityParams memory p = SoloVault.AddLiquidityParams({
            amount0Desired: 0.04 ether,
            amount1Desired: 0.06 ether,
            amount0Min: 0.039 ether,
            amount1Min: 0.059 ether,
            to: user,
            deadline: block.timestamp + 1000,
            tickLower: MIN_TICK,
            tickUpper: MAX_TICK,
            salt: "fullrange-position-test"
        });
        vm.startPrank(user);
        vault.addLiquidity(pid, p);
        vm.stopPrank();

        uint256 ab = vault.liquidityShares(user, pid, SHARE_TYPE_AB);
        assertTrue(ab > 0);

        uint256 expected = FixedPointMathLib.sqrt(0.04 ether * 0.06 ether);
        assertEq(ab, expected);

        // remove half
        SoloVault.RemoveLiquidityParams memory rp = SoloVault.RemoveLiquidityParams({
            liquidity: ab / 2,
            amount0Min: 0.019 ether,
            amount1Min: 0.029 ether,
            deadline: block.timestamp + 1000,
            tickLower: MIN_TICK,
            tickUpper: MAX_TICK,
            salt: "fullrange-position-test"
        });
        vm.startPrank(user);
        BalanceDelta delta = vault.removeLiquidity(pid, rp);
        vm.stopPrank();

        uint256 remain = vault.liquidityShares(user, pid, SHARE_TYPE_AB);
        assertEq(remain, ab - rp.liquidity);
        // user should receive positive amounts
        assertGt(delta.amount0(), 0);
        assertGt(delta.amount1(), 0);
    }

    function testUnlockCallback() public {
        bytes32 pid = getPoolId(poolKey1);
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));

        // 1) full range deposit
        {
            SoloVault.AddLiquidityParams memory p = SoloVault.AddLiquidityParams({
                amount0Desired: 0.04 ether,
                amount1Desired: 0.06 ether,
                amount0Min: 0.039 ether,
                amount1Min: 0.059 ether,
                to: user,
                deadline: block.timestamp + 1000,
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                salt: "callback-test"
            });
            vm.startPrank(user);
            vault.addLiquidity(pid, p);
            vm.stopPrank();

            uint256 ab = vault.liquidityShares(user, pid, SHARE_TYPE_AB);
            assertTrue(ab > 0);
        }

        // 2) add single token0
        {
            SoloVault.AddLiquidityParams memory p2 = SoloVault.AddLiquidityParams({
                amount0Desired: 0.05 ether,
                amount1Desired: 0,
                amount0Min: 0.049 ether,
                amount1Min: 0,
                to: user,
                deadline: block.timestamp + 1000,
                tickLower: -120,
                tickUpper: -60,
                salt: "token0-callback-test"
            });
            vm.startPrank(user);
            vault.addLiquidity(pid, p2);
            vm.stopPrank();

            uint256 shareA = vault.liquidityShares(user, pid, SHARE_TYPE_A);
            assertEq(shareA, 0.05 ether);
        }
    }

    // -----------
    // Additional checks
    // -----------

    function testMultipleDepositsOfSameTokenType() public {
        bytes32 pid = getPoolId(poolKey1);
        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));

        vm.startPrank(user);
        vault.deposit(pid, 0.1 ether, 0);
        vault.deposit(pid, 0.2 ether, 0);
        vm.stopPrank();

        uint256 a = vault.liquidityShares(user, pid, SHARE_TYPE_A);
        assertEq(a, 0.3 ether);
    }

    function testSeparatePoolDeposits() public {
        bytes32 pid1 = getPoolId(poolKey1);
        bytes32 pid2 = getPoolId(poolKey2);

        vm.prank(user);
        poolManager.initialize(poolKey1, uint160(1 << 96));
        vm.prank(user);
        poolManager.initialize(poolKey2, uint160(1 << 96));

        // add to pool1
        {
            SoloVault.AddLiquidityParams memory p1 = SoloVault.AddLiquidityParams({
                amount0Desired: 0.04 ether,
                amount1Desired: 0.06 ether,
                amount0Min: 0.039 ether,
                amount1Min: 0.059 ether,
                to: user,
                deadline: block.timestamp + 1000,
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                salt: "pool1-test"
            });
            vm.startPrank(user);
            vault.addLiquidity(pid1, p1);
            vm.stopPrank();
        }

        // add to pool2
        {
            SoloVault.AddLiquidityParams memory p2 = SoloVault.AddLiquidityParams({
                amount0Desired: 0.07 ether,
                amount1Desired: 0.03 ether,
                amount0Min: 0.069 ether,
                amount1Min: 0.029 ether,
                to: user,
                deadline: block.timestamp + 1000,
                tickLower: 10,   // compatible with tickSpacing=20
                tickUpper: 60,
                salt: "pool2-test"
            });
            vm.startPrank(user);
            vault.addLiquidity(pid2, p2);
            vm.stopPrank();
        }

        uint256 ab1 = vault.liquidityShares(user, pid1, SHARE_TYPE_AB);
        uint256 ab2 = vault.liquidityShares(user, pid2, SHARE_TYPE_AB);
        assertTrue(ab1 > 0);
        assertTrue(ab2 > 0);
    }

    function testDirectInitialization() public {
        bytes32 pid2 = getPoolId(poolKey2);

        vm.prank(user);
        poolManager.initialize(poolKey2, uint160(1 << 96));

        PoolKey memory stored = vault.getPoolKey(pid2);
        assertEq(address(stored.hooks), address(vault));

        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolKey2.toId());
        assertTrue(sqrtPriceX96 > 0);
    }
}