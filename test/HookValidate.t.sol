pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Spot} from "src/Spot.sol";
import {PM} from "test/unit/SpotUnitTest.t.sol"; // the tiny stub PM used earlier
import {SpotFlags} from "test/utils/SpotFlags.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

contract HookValidate is Test {
    address constant REAL_PM = 0x1F98400000000000000000000000000000000004;

    function testValidateWithRealPoolManager() public {
        // 1. Deploy a *stub* PoolManager so the constructor doesn't revert.
        PM stub = new PM();

        // Create some valid addresses for constructor args
        address policyManager = makeAddr("policyManager");
        address liquidityManager = makeAddr("liquidityManager");
        address oracle = makeAddr("oracle");
        address feeManager = makeAddr("feeManager");

        // 2. Mine + deploy the Spot hook exactly like SimpleDeployLib but
        //    give it `stub` as its PoolManager.
        bytes memory args = abi.encode(
            IPoolManager(address(stub)),
            policyManager,
            liquidityManager,
            oracle,
            feeManager,
            address(this) // initialOwner
        );
        (, bytes32 salt) = HookMiner.find(address(this), SpotFlags.required(), type(Spot).creationCode, args);
        address payable hookAddr = payable(Create2.deploy(0, salt, abi.encodePacked(type(Spot).creationCode, args)));

        // 3. Now check if the hook address is valid using Hooks library directly
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
