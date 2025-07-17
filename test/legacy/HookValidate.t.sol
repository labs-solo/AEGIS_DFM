// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Spot} from "src/Spot.sol";
import {PM} from "test/legacy/unit/SpotUnitTest.t.sol"; // the tiny stub PM used earlier
import {SpotFlags} from "test/legacy/utils/SpotFlags.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {FullRangeLiquidityManager} from "src/FullRangeLiquidityManager.sol";
import {PoolPolicyManager} from "src/PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "src/TruncGeoOracleMulti.sol";
import {DynamicFeeManager} from "src/DynamicFeeManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IAllowanceTransfer} from "test/legacy/mocks/TestPermit2.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {NoDelegateCall} from "v4-core/src/NoDelegateCall.sol";
import {TestPermit2} from "test/legacy/mocks/TestPermit2.sol";
import {PositionDescriptor} from "v4-periphery/src/PositionDescriptor.sol";
import {TestWETH9} from "./mocks/TestWETH9.sol";

contract MockPermit2 is IAllowanceTransfer {
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return bytes32(0);
    }

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {}

    function permit(address owner, PermitSingle memory permitSingle, bytes calldata signature) external {}

    function permit(address owner, PermitBatch memory permitBatch, bytes calldata signature) external {}

    function transferFrom(address from, address to, uint160 amount, address token) external {}

    function transferFrom(AllowanceTransferDetails[] calldata transferDetails) external {}

    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        return (type(uint160).max, type(uint48).max, 0);
    }

    function lockdown(TokenSpenderPair[] calldata approvals) external {}

    function invalidateNonces(address token, address spender, uint48 newNonce) external {}
}

contract HookValidate is Test {
    address constant REAL_PM = 0x1F98400000000000000000000000000000000004;

    function testValidateWithRealPoolManager() public {
        // 1. Deploy a *stub* PoolManager so the constructor doesn't revert.
        PM stub = new PM();

        // 2. Deploy the real contracts we need
        // First deploy PoolPolicyManager with required args
        PoolPolicyManager policyManager = new PoolPolicyManager(
            address(this), // governance
            1_000_000 // dailyBudget (100%)
        );

        // Deploy real dependencies for PositionManager
        IAllowanceTransfer permit2 = IAllowanceTransfer(new TestPermit2());
        TestWETH9 weth9 = new TestWETH9();

        // Deploy PositionDescriptor with proper parameters
        bytes32 nativeCurrencyLabelBytes = bytes32("ETH"); // ETH for mainnet
        PositionDescriptor descriptor =
            new PositionDescriptor(IPoolManager(address(stub)), address(weth9), nativeCurrencyLabelBytes);

        // Deploy PositionManager for FRLM
        PositionManager positionManager = new PositionManager(
            IPoolManager(address(stub)),
            permit2,
            100_000, // unsubscribeGasLimit
            IPositionDescriptor(address(descriptor)),
            IWETH9(address(weth9))
        );

        // 3. Mine the hook address first so we can pass it to contracts that need it
        bytes memory args = abi.encode(
            IPoolManager(address(stub)),
            address(0), // liquidityManager - will update after deployment
            address(policyManager),
            address(0), // oracle - will update after deployment
            address(0), // feeManager - will update after deployment
            address(this) // initialOwner
        );
        (, bytes32 salt) = HookMiner.find(address(this), SpotFlags.required(), type(Spot).creationCode, args);
        address hookAddr =
            Create2.computeAddress(salt, keccak256(abi.encodePacked(type(Spot).creationCode, args)), address(this));

        // 4. Deploy contracts that need the hook address upfront

        // Deploy TruncGeoOracle
        TruncGeoOracleMulti oracle = new TruncGeoOracleMulti(
            IPoolManager(address(stub)),
            policyManager,
            hookAddr, // authorized hook address
            address(this) // owner
        );

        // Deploy DynamicFeeManager
        DynamicFeeManager feeManager = new DynamicFeeManager(
            address(this), // owner
            policyManager,
            address(oracle),
            hookAddr // authorized hook address
        );

        FullRangeLiquidityManager liquidityManager = new FullRangeLiquidityManager(
            IPoolManager(address(stub)),
            positionManager,
            oracle,
            hookAddr // authorized hook address
        );

        // 5. Now deploy the actual hook with the real addresses
        args = abi.encode(
            IPoolManager(address(stub)),
            address(liquidityManager),
            address(policyManager),
            address(oracle),
            address(feeManager),
            address(this) // initialOwner
        );
        address payable actualHookAddr =
            payable(Create2.deploy(0, salt, abi.encodePacked(type(Spot).creationCode, args)));

        // Verify we got the address we expected
        assertEq(actualHookAddr, hookAddr, "Hook deployed at unexpected address");

        // 6. Now check if the hook address is valid using Hooks library directly
        bool ok = Hooks.isValidHookAddress(IHooks(hookAddr), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        emit log_named_address("Hook", hookAddr);
        emit log_named_string("Hook address valid?", ok ? "true" : "false");
        assertTrue(ok, "Hook address validation failed");

        // Print the actual flags for debugging
        uint160 hookFlags = uint160(uint256(uint160(address(hookAddr)))) & uint160(Hooks.ALL_HOOK_MASK);
        emit log_named_uint("Required flags", uint256(SpotFlags.required()));
        emit log_named_uint("Actual hook flags", uint256(hookFlags));

        // Print the dynamic fee flag for comparison
        emit log_named_uint("DYNAMIC_FEE_FLAG", uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG));

        // Print permissions from both sources
        Hooks.Permissions memory perms = Spot(hookAddr).getHookPermissions();
        uint160 permFlags = uint160(0);
        if (perms.beforeInitialize) permFlags |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (perms.afterInitialize) permFlags |= Hooks.AFTER_INITIALIZE_FLAG;
        if (perms.beforeSwap) permFlags |= Hooks.BEFORE_SWAP_FLAG;
        if (perms.afterSwap) permFlags |= Hooks.AFTER_SWAP_FLAG;
        if (perms.beforeAddLiquidity) permFlags |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (perms.afterAddLiquidity) permFlags |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (perms.beforeRemoveLiquidity) permFlags |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (perms.afterRemoveLiquidity) permFlags |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (perms.beforeDonate) permFlags |= Hooks.BEFORE_DONATE_FLAG;
        if (perms.afterDonate) permFlags |= Hooks.AFTER_DONATE_FLAG;
        if (perms.beforeSwapReturnDelta) permFlags |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (perms.afterSwapReturnDelta) permFlags |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (perms.afterAddLiquidityReturnDelta) permFlags |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (perms.afterRemoveLiquidityReturnDelta) permFlags |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;

        emit log_named_uint("getHookPermissions flags", uint256(permFlags));
        emit log_named_uint("SpotFlags.required()", uint256(SpotFlags.required()));
    }
}
