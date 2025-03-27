// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/*
 * This test file has been moved to old-tests and commented out.
 * It is kept for reference but is no longer used in the project.
 * The new testing approach uses LocalUniswapV4TestBase.t.sol for local deployments.
 */

/*

/**
 * @title FullRangeHooksTest
 * @notice Unit tests for the hook/callback logic introduced in Phase 4.
 *         Achieves 90%+ coverage by testing:
 *         - valid salt => deposit or withdrawal
 *         - invalid salt => revert
 *         - zero liquidityDelta => revert
 */

import "forge-std/Test.sol";
import "../src/FullRangeHooks.sol";
import {CallbackData, PoolKey, ModifyLiquidityParams} from "../src/interfaces/IFullRange.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract FullRangeHooksTest is Test {
    FullRangeHooks hooks;
    
    // Event signatures for validation
    event DepositCallbackProcessed(address sender, int256 liquidityDelta);
    event WithdrawCallbackProcessed(address sender, int256 liquidityDelta);

    function setUp() public {
        hooks = new FullRangeHooks();
    }

    function testDepositCallbackSuccess() public {
        // Create test addresses for currencies
        address currency0 = makeAddr("currency0");
        address currency1 = makeAddr("currency1");
        
        // build callback data with deposit scenario => liquidityDelta > 0
        CallbackData memory cd = CallbackData({
            sender: address(this),
            key: PoolKey({
                currency0: Currency.wrap(currency0),
                currency1: Currency.wrap(currency1),
                fee: 0x800000,  // dynamic fee for example
                tickSpacing: 60,
                hooks: IHooks(address(0))
            }),
            params: ModifyLiquidityParams({
                tickLower: -887220,
                tickUpper: 887220,
                liquidityDelta: int256(1000), // deposit
                salt: keccak256("FullRangeHook")
            }),
            isHookOp: true
        });

        // Listen for the deposit event
        vm.expectEmit(true, true, false, true);
        emit DepositCallbackProcessed(address(this), 1000);

        // encode
        bytes memory encoded = abi.encode(cd);
        
        // call handleCallback
        bytes memory result = hooks.handleCallback(encoded);
        
        // decode the result
        (BalanceDelta delta, string memory label) = abi.decode(result, (BalanceDelta, string));
        
        // Verify the label identifies this as a deposit
        assertEq(label, "depositCallback", "Should identify deposit flow");
    }

    function testWithdrawalCallbackSuccess() public {
        // Create test addresses for currencies
        address currency0 = makeAddr("currency0");
        address currency1 = makeAddr("currency1");
        
        // build callback data with withdrawal scenario => liquidityDelta < 0
        CallbackData memory cd = CallbackData({
            sender: address(this),
            key: PoolKey({
                currency0: Currency.wrap(currency0),
                currency1: Currency.wrap(currency1),
                fee: 0x800000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            }),
            params: ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: int256(-500), // withdrawal
                salt: keccak256("FullRangeHook")
            }),
            isHookOp: true
        });

        // Listen for the withdrawal event
        vm.expectEmit(true, true, false, true);
        emit WithdrawCallbackProcessed(address(this), -500);

        bytes memory encoded = abi.encode(cd);
        bytes memory result = hooks.handleCallback(encoded);
        
        (BalanceDelta delta, string memory label) = abi.decode(result, (BalanceDelta, string));
        assertEq(label, "withdrawCallback", "Should identify withdrawal flow");
    }

    function testInvalidSaltRevert() public {
        // Create test addresses for currencies
        address currency0 = makeAddr("currency0");
        address currency1 = makeAddr("currency1");
        
        // same as deposit scenario but the salt is wrong
        CallbackData memory cd = CallbackData({
            sender: address(this),
            key: PoolKey({
                currency0: Currency.wrap(currency0),
                currency1: Currency.wrap(currency1),
                fee: 0x800000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            }),
            params: ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(100),
                salt: keccak256("FakeHookSalt") // Different salt
            }),
            isHookOp: true
        });

        bytes memory encoded = abi.encode(cd);
        vm.expectRevert("InvalidCallbackSalt");
        hooks.handleCallback(encoded);
    }

    function testZeroDeltaRevert() public {
        // Create test addresses for currencies
        address currency0 = makeAddr("currency0");
        address currency1 = makeAddr("currency1");
        
        CallbackData memory cd = CallbackData({
            sender: address(this),
            key: PoolKey({
                currency0: Currency.wrap(currency0),
                currency1: Currency.wrap(currency1),
                fee: 0x800000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            }),
            params: ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 0, // Zero delta
                salt: keccak256("FullRangeHook")
            }),
            isHookOp: true
        });

        bytes memory encoded = abi.encode(cd);
        vm.expectRevert("ZeroLiquidityDelta");
        hooks.handleCallback(encoded);
    }
    
    function testFullRangeSaltConstantValue() public {
        // Verify the salt constant has the correct value
        bytes32 expectedSalt = keccak256("FullRangeHook");
        bytes32 actualSalt = hooks.FULL_RANGE_SALT();
        
        assertEq(actualSalt, expectedSalt, "FULL_RANGE_SALT should match keccak256('FullRangeHook')");
    }
} 
*/
