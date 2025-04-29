// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ForkSetup} from "./ForkSetup.t.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// import {StateLibrary}   from "v4-core/libraries/StateLibrary.sol"; // Keep commented out
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

// Changed to absolute src imports
import {Spot} from "src/Spot.sol";
import {IFullRangeLiquidityManager} from "src/interfaces/IFullRangeLiquidityManager.sol";
import {IPoolPolicy} from "src/interfaces/IPoolPolicy.sol";
import {ISpot, DepositParams as ISpotDepositParams} from "src/interfaces/ISpot.sol";

// import {IWETH9}         from "@uniswap/v4-periphery/interfaces/external/IWETH9.sol"; // Keep commented out
// import {LiquidityRouter} from "../../src/LiquidityRouter.sol"; // Commented out - File not found
// import {SwapRouter} from "../../src/SwapRouter.sol"; // Commented out - File not found
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {CurrencySettler} from "../../src/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullRangeLiquidityManager} from "../../src/FullRangeLiquidityManager.sol";
// import {PoolModifyLiquidityTest} from "./integration/routers/PoolModifyLiquidityTest.sol"; // Keep commented out

// Remove local struct definition, use imported one
// struct LocalDepositParams {
//     PoolId poolId;
//     uint256 amount0Desired;
//     uint256 amount1Desired;
//     uint256 amount0Min;
//     uint256 amount1Min;
//     uint256 deadline;
// }

contract InternalReinvestTest is ForkSetup {
    using CurrencyLibrary for Currency;

    address internal keeper = makeAddr("keeper");
    address internal feeSink = makeAddr("feeSink");

    Spot internal hook;
    IFullRangeLiquidityManager internal lm;
    IPoolManager internal pm; // Renamed from poolManager for consistency with snippet
    IPoolPolicy internal policyMgr;

    Currency internal c0;
    Currency internal c1;

    uint256 constant MIN0 = 1; // 1 USDC
    uint256 constant MIN1 = 1e9; // 1 gwei WETH
    uint64 constant COOLDOWN = 1 hours;

    /* ---------- set‑up ---------------------------------------------------- */
    function setUp() public override {
        super.setUp();

        hook = Spot(payable(fullRange));
        lm = IFullRangeLiquidityManager(liquidityManager);
        pm = poolManager; // Assign pm
        policyMgr = policyManager;

        c0 = poolKey.currency0;
        c1 = poolKey.currency1;

        vm.deal(keeper, 10 ether);

        vm.prank(policyMgr.getSoloGovernance());
        hook.setReinvestConfig(poolId, MIN0, MIN1, COOLDOWN);
    }

    /* ---------- helpers --------------------------------------------------- */
    /// @dev credits `units` of `cur` to the hook's *claim* balance
    function _creditInternalBalance(Currency cur, uint256 units) internal {
        address token = Currency.unwrap(cur);

        // 1. Ensure the test has external tokens & approved
        deal(token, address(this), units);
        ERC20(token).approve(address(pm), units);

        // 2. Call unlock to run our mint+settle in unlockCallback
        bytes memory data = abi.encode(cur, units, address(hook));
        pm.unlock(data); // Use pm variable

        // 3. Top up the hook's external ERC20 so pokeReinvest can use it
        uint256 requiredExternalBalance = units * (10 ** ERC20(token).decimals());
        uint256 currentHookBalance = ERC20(token).balanceOf(address(hook));
        if (currentHookBalance < requiredExternalBalance) {
            deal(token, address(hook), requiredExternalBalance - currentHookBalance);
        }
    }

    /// @dev Add some full‐range liquidity so that pokeReinvest actually has something to grow.
    function _addInitialLiquidity(uint256 amount0, uint256 amount1) internal {
        // 1) Fund the hook directly with the tokens it will deposit
        address t0 = Currency.unwrap(c0);
        address t1 = Currency.unwrap(c1);
        deal(t0, address(hook), amount0);
        deal(t1, address(hook), amount1);

        // 2) Let the liquidityManager pull them from the hook
        // Prank as hook to approve liquidityManager
        vm.prank(address(hook));
        ERC20(t0).approve(address(liquidityManager), amount0);
        vm.prank(address(hook));
        ERC20(t1).approve(address(liquidityManager), amount1);

        // 3) Call Spot.deposit to mint some shares (full‐range)
        // Use the imported ISpot.DepositParams struct type
        ISpotDepositParams memory params = ISpotDepositParams({
            poolId: poolId,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0, // Set min to 0 to avoid slippage issues on initial deposit
            amount1Min: 0, // Set min to 0 to avoid slippage issues on initial deposit
            deadline: block.timestamp + 1 hours
        });

        // Call deposit from the test contract context (no prank)
        hook.deposit(params);
    }

    /* ---------- Test 1 ---------------------------------------------------- */
    function test_ReinvestSkippedWhenBelowThreshold() public {
        vm.recordLogs();
        vm.prank(keeper);
        hook.pokeReinvest(poolId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ReinvestSkipped(bytes32,string,uint256,uint256)");
        bool skipped;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (string memory reason,,) = abi.decode(logs[i].data, (string, uint256, uint256));
                if (keccak256(bytes(reason)) == keccak256("threshold")) skipped = true;
            }
        }
        assertTrue(skipped, "ReinvestSkipped(threshold) not seen");
    }

    /* ---------- Test 2.5: Global Pause ---------------------------------- */
    function test_ReinvestSkippedWhenGlobalPaused() public {
        // 1) Credit balances so threshold check passes
        _creditInternalBalance(c0, MIN0);
        _creditInternalBalance(c1, MIN1);

        // 2) Enable global pause
        vm.prank(policyMgr.getSoloGovernance());
        hook.setReinvestmentPaused(true);

        // 3) Attempt reinvest and check for skip reason
        vm.recordLogs();
        vm.prank(keeper);
        hook.pokeReinvest(poolId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ReinvestSkipped(bytes32,string,uint256,uint256)");
        bool skipped;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (string memory reason,,) = abi.decode(logs[i].data, (string, uint256, uint256));
                if (keccak256(bytes(reason)) == keccak256("globalPaused")) skipped = true;
            }
        }
        assertTrue(skipped, "ReinvestSkipped(globalPaused) not seen");

        // 4) Disable global pause and check success
        vm.prank(policyMgr.getSoloGovernance());
        hook.setReinvestmentPaused(false);

        vm.recordLogs();
        vm.prank(keeper);
        hook.pokeReinvest(poolId);

        logs = vm.getRecordedLogs();
        bytes32 successSig = keccak256("ReinvestmentSuccess(bytes32,uint256,uint256)");
        bool success;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == successSig) success = true;
        }
        assertTrue(success, "ReinvestmentSuccess not seen after unpause");
    }

    /* ---------- Test 3 ---------------------------------------------------- */
    function test_ReinvestSucceedsAfterBalance() public {
        // 0) Seed the pool so reinvest has existing liquidity to work on
        // Note: Using raw amounts here. Might need conversion based on decimals.
        _addInitialLiquidity(100 * (10 ** 6), 1 ether / 10); // e.g. 100 USDC (6 dec), 0.1 WETH (18 dec)

        // 1) Credit hook's claim balances for both sides
        _creditInternalBalance(c0, 10); // credit hook's claim balances for both sides
        _creditInternalBalance(c1, MIN1);

        // 1.6) Approve the liquidityManager to pull both tokens from the hook.
        //      Without this, reinvest will revert in the transferFrom/settle step.
        {
            address t0 = Currency.unwrap(c0);
            address t1 = Currency.unwrap(c1);
            // Prank as the hook to set approvals
            vm.prank(address(hook));
            ERC20(t0).approve(address(liquidityManager), type(uint256).max);
            vm.prank(address(hook));
            ERC20(t1).approve(address(liquidityManager), type(uint256).max);
        }

        (,, uint128 liqBefore) = lm.getPoolReservesAndShares(poolId);
        assertTrue(liqBefore > 0, "Liquidity should be > 0 after initial deposit");

        vm.recordLogs();
        vm.prank(keeper);
        hook.pokeReinvest(poolId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 successSig = keccak256("ReinvestmentSuccess(bytes32,uint256,uint256)");
        bool success;
        uint256 used0;
        uint256 used1;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == successSig) {
                (used0, used1) = abi.decode(logs[i].data, (uint256, uint256));
                success = true;
            }
        }
        assertTrue(success, "ReinvestmentSuccess not emitted");
        assertTrue(used0 > 0 || used1 > 0, "no tokens used");

        (,, uint128 liqAfter) = lm.getPoolReservesAndShares(poolId);
        assertGt(liqAfter, liqBefore, "liquidity did not grow");

        // cooldown check
        vm.warp(block.timestamp + 1 minutes);
        vm.recordLogs();
        vm.prank(keeper);
        hook.pokeReinvest(poolId);

        logs = vm.getRecordedLogs();
        bytes32 skipSig = keccak256("ReinvestSkipped(bytes32,string,uint256,uint256)");
        bool skippedCool;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == skipSig) {
                (string memory reason,,) = abi.decode(logs[i].data, (string, uint256, uint256));
                if (keccak256(bytes(reason)) == keccak256("cooldown")) skippedCool = true;
            }
        }
        assertTrue(skippedCool, "should skip due to cooldown");
    }

    // allow PoolManager.unlock(...) to succeed
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (Currency cur, uint256 units, address to) = abi.decode(data, (Currency, uint256, address));

        // 1) Mint claim tokens for the hook (credits pm.balanceOf(hook,id))
        // The ID for the ERC-6909 token is the currency address cast to uint256
        pm.mint(to, uint256(uint160(Currency.unwrap(cur))), units);

        // 2) Pay off the test-contract's negative delta
        //    (sync → transfer → settle)
        CurrencySettler.settle(cur, pm, address(this), units, false);

        return ""; // nothing else needed
    }
}
