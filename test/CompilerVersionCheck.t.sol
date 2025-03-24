// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/**
 * @title CompilerVersionCheck
 * @notice A test suite that verifies how compiler versions affect hook address generation
 * @dev This test ensures that hooks are correctly deployed with permission bits embedded in their addresses
 */
contract CompilerVersionCheck is Test {
    // Test constants - mock addresses for the various managers
    address deployer = address(this);
    address mockPoolManager = address(0x1111);
    address mockPolicyManager = address(0x2222);
    address mockLiquidityManager = address(0x3333);
    address mockDynamicFeeManager = address(0x4444);
    
    // Define the hook flags required for our FullRange hook
    // These flags match the permissions that will be embedded in the contract address
    uint160 requiredFlags = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | 
        Hooks.AFTER_INITIALIZE_FLAG | 
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | 
        Hooks.AFTER_ADD_LIQUIDITY_FLAG | 
        Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | 
        Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | 
        Hooks.BEFORE_SWAP_FLAG | 
        Hooks.AFTER_SWAP_FLAG
    );
    
    function setUp() public {
        // Empty setup - no specific setup needed for this test
    }
    
    /**
     * @notice Tests that hook addresses are consistently generated with embedded permission bits
     * @dev This test validates that the compiler version doesn't change how hook addresses are generated,
     *      which is critical for Uniswap V4 hook validation
     */
    function test_addressGenerationConsistency() public {
        // ======================= ARRANGE =======================
        console2.log("==================== COMPILER VERSION CHECK ====================");
        console2.log("Checking how compiler version affects hook address generation");
        console2.log("Required hook flags:", requiredFlags);
        console2.log("ALL_HOOK_MASK:", Hooks.ALL_HOOK_MASK);
        
        // Get bytecode hash to check if it changes between compiler versions
        bytes memory creationCode = type(MockHook).creationCode;
        bytes32 creationCodeHash = keccak256(creationCode);
        console2.log("Creation code size:", creationCode.length);
        console2.logBytes32(creationCodeHash);
        
        // Prepare constructor arguments for the hook
        bytes memory constructorArgs = abi.encode(
            mockPoolManager,
            mockPolicyManager,
            mockLiquidityManager,
            mockDynamicFeeManager
        );
        
        // ======================= ACT =======================
        // Mine for a hook address that has the proper permission bits encoded in its address
        // This is a critical step for Uniswap V4 hooks which must have their permissions in the address
        (address hookAddress, bytes32 salt) = HookMiner.find(
            deployer,
            requiredFlags,
            creationCode,
            constructorArgs
        );
        
        // Output the results of the mining process
        console2.log("Mined hook address:", hookAddress);
        console2.log("Permission bits in address:", uint160(hookAddress) & Hooks.ALL_HOOK_MASK);
        console2.log("Salt used:", uint256(salt));
        
        // Calculate the address that would be deployed with the CREATE2 opcode using the same salt
        address computedAddress = HookMiner.computeAddress(
            deployer,
            uint256(salt),
            abi.encodePacked(creationCode, constructorArgs)
        );
        
        // ======================= ASSERT =======================
        // Verify that the computed address matches the mined address
        console2.log("Computed address:", computedAddress);
        assertEq(computedAddress, hookAddress, "Computed address should match mined address");
        
        // The purpose of this test is to verify that different compiler versions
        // don't affect hook address generation. To properly test this:
        // 1. Run with Solidity 0.8.26: forge test --match-path test/CompilerVersionCheck.t.sol --use solc:0.8.26
        // 2. Run with Solidity 0.8.29: forge test --match-path test/CompilerVersionCheck.t.sol --use solc:0.8.29
        // 3. Compare the creation code hash and resulting addresses
    }
}

/**
 * @title MockHook
 * @notice A simplified hook implementation for testing address generation
 * @dev This mock implements the minimum required for hook address mining
 */
contract MockHook {
    address public immutable poolManager;
    address public immutable policyManager;
    address public immutable liquidityManager;
    address public immutable dynamicFeeManager;
    
    constructor(
        address _poolManager,
        address _policyManager,
        address _liquidityManager,
        address _dynamicFeeManager
    ) {
        poolManager = _poolManager;
        policyManager = _policyManager;
        liquidityManager = _liquidityManager;
        dynamicFeeManager = _dynamicFeeManager;
    }
    
    /**
     * @notice Returns the hook permissions that will be encoded in the contract address
     * @dev These permissions must match the flags used during address mining
     */
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
} 