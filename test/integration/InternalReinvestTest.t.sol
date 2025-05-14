// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LocalSetup} from "./LocalSetup.t.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

// import {StateLibrary}   from "v4-core/src/libraries/StateLibrary.sol"; // Keep commented out
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {CurrencySettler} from "uniswap-hooks/utils/CurrencySettler.sol";

// Changed to absolute src imports
import {Spot} from "src/Spot.sol";
import {IFullRangeLiquidityManager} from "src/interfaces/IFullRangeLiquidityManager.sol";
import {IPoolPolicy} from "src/interfaces/IPoolPolicy.sol";
import {ISpot, DepositParams as ISpotDepositParams} from "src/interfaces/ISpot.sol";
// NOTE: SharedDeployLib is *not* used directly here, but keeping the structure consistent.
// If it *were* imported, the path would be updated below.
// import {SharedDeployLib} from "src/utils/SharedDeployLib.sol"; // Example of correct path

// import {IWETH9}         from "v4-periphery/interfaces/external/IWETH9.sol"; // Keep commented out
import {ERC20} from "solmate/src/tokens/ERC20.sol";
// import {CurrencySettler} from "uniswap-hooks/utils/CurrencySettler.sol"; // Removed import
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol"; // Added import
// import {PoolModifyLiquidityTest} from "./integration/routers/PoolModifyLiquidityTest.sol"; // Keep commented out
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol"; // Added import
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol"; // <-- ADDED IMPORT
import {CurrencySettlerExtension} from "src/utils/CurrencySettlerExtension.sol"; // NEW import

import "forge-std/console.sol";

// Remove local struct definition, use imported one
// struct LocalDepositParams {
//     PoolId poolId;
//     uint256 amount0Desired;
//     uint256 amount1Desired;
//     uint256 amount0Min;
//     uint256 amount1Min;
//     uint256 deadline;
// }

// The re-investment tests can run on the fully-wired environment that
// `LocalSetup` already gives us – no need to hand-roll another deployer.

contract InternalReinvestTest is LocalSetup, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20; // Updated to use IERC20 instead of IERC20Minimal

    address internal keeper = makeAddr("keeper");
    address internal feeSink = makeAddr("feeSink");

    Spot internal spotHook;
    IFullRangeLiquidityManager internal lm;
    IPoolManager internal pm; // Renamed from poolManager for consistency with snippet
    IPoolPolicy internal policyMgr;

    Currency internal c0;
    Currency internal c1;

    uint256 constant MIN0 = 1; // 1 USDC
    uint256 constant MIN1 = 1e9; // 1 gwei WETH
    uint64 constant COOLDOWN = 1 hours;

    address token0;
    address token1;

    function _ensureHookApprovals() internal {
        address t0 = Currency.unwrap(c0);
        address t1 = Currency.unwrap(c1);

        uint256 MAX = type(uint256).max;

        // ── LiquidityManager (FLM) must allow PM to pull during settle()
        vm.prank(address(liquidityManager));
        IERC20Minimal(t0).approve(address(poolManager), MAX);
        vm.prank(address(liquidityManager));
        IERC20Minimal(t1).approve(address(poolManager), MAX);

        // ── Hook must let FLM pull for deposits *and* PM pull for debt settlement
        vm.startPrank(address(spotHook));
        ERC20(t0).approve(address(liquidityManager), MAX);
        ERC20(t1).approve(address(liquidityManager), MAX);
        ERC20(t0).approve(address(poolManager), MAX);
        ERC20(t1).approve(address(poolManager), MAX);
        vm.stopPrank();
    }

    /* ---------- set‑up ---------------------------------------------------- */
    function setUp() public override {
        super.setUp();

        spotHook = Spot(payable(fullRange));
        lm = IFullRangeLiquidityManager(liquidityManager);
        pm = poolManager; // Assign pm
        policyMgr = policyManager;

        c0 = poolKey.currency0;
        c1 = poolKey.currency1;

        vm.deal(keeper, 10 ether);

        vm.prank(policyMgr.getSoloGovernance());
        spotHook.setReinvestConfig(poolId, MIN0, MIN1, COOLDOWN);

        token0 = Currency.unwrap(c0);
        token1 = Currency.unwrap(c1);
    }

    /* ---------- helpers --------------------------------------------------- */
    /// @dev credits `units` of `cur` to the spotHook's *claim* balance
    function _creditInternalBalance(Currency cur, uint256 units) internal {
        _ensureHookApprovals();
        address token = Currency.unwrap(cur);

        // 1. Give the HOOK the external tokens, not this test contract, but grant approval to test contract
        deal(token, address(spotHook), units);
        vm.prank(address(spotHook));
        ERC20(token).approve(address(this), units);

        // 2. As the *spotHook*, settle the tokens with the PoolManager.
        //    This leaves +units of INTERNAL credit on the spotHook.
        vm.prank(address(spotHook));
        settleCurrency(pm, cur, address(spotHook), units);
    }

    function settleCurrency(IPoolManager manager, Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;

        if (currency.isAddressZero()) {
            // Use Uniswap's standard CurrencySettler with native ETH
            CurrencySettler.settle(currency, manager, payer, amount, false);
        } else {
            // For ERC20 tokens
            CurrencySettler.settle(currency, manager, payer, amount, false);
        }
    }

    /// @dev Add some full‐range liquidity so that pokeReinvest actually has something to grow.
    function _addInitialLiquidity(uint256 amount0, uint256 amount1) internal {
        _ensureHookApprovals();
        // 1) Fund the spotHook directly with the tokens it will deposit
        address t0 = Currency.unwrap(c0);
        address t1 = Currency.unwrap(c1);
        deal(t0, address(spotHook), amount0);
        deal(t1, address(spotHook), amount1);

        // 2) Let the liquidityManager pull them from the spotHook
        // Prank as spotHook to approve liquidityManager
        vm.prank(address(spotHook));
        ERC20(t0).approve(address(liquidityManager), type(uint256).max);
        vm.prank(address(spotHook));
        ERC20(t1).approve(address(liquidityManager), type(uint256).max);
        // also approve PoolManager for subsequent settle() pulls
        vm.prank(address(spotHook));
        ERC20(t0).approve(address(poolManager), type(uint256).max);
        vm.prank(address(spotHook));
        ERC20(t1).approve(address(poolManager), type(uint256).max);

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

        // Call deposit from governance
        vm.prank(deployerEOA); // Use governance for deposit
        spotHook.deposit(params);
    }

    /* ---------- Test 1 ---------------------------------------------------- */
    function test_ReinvestSkippedWhenBelowThreshold() public {
        vm.recordLogs();
        vm.prank(keeper);
        spotHook.claimPendingFees(poolId);

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
        spotHook.setReinvestmentPaused(true);

        // 3) Attempt reinvest and check for skip reason
        vm.recordLogs();
        vm.prank(keeper);
        spotHook.claimPendingFees(poolId);

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
        spotHook.setReinvestmentPaused(false);

        vm.recordLogs();
        vm.prank(keeper);
        spotHook.claimPendingFees(poolId);

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

        // 1) Credit spotHook's claim balances for both sides
        _creditInternalBalance(c0, 10); // credit spotHook's claim balances for both sides
        _creditInternalBalance(c1, MIN1);

        // 1.6) Approve the liquidityManager to pull both tokens from the spotHook.
        //      Without this, reinvest will revert in the transferFrom/settle step.
        {
            address t0 = Currency.unwrap(c0);
            address t1 = Currency.unwrap(c1);
            // Prank as the spotHook to set approvals
            vm.prank(address(spotHook));
            ERC20(t0).approve(address(liquidityManager), type(uint256).max);
            vm.prank(address(spotHook));
            ERC20(t1).approve(address(liquidityManager), type(uint256).max);
        }

        (,, uint128 liqBefore) = spotHook.getPoolReservesAndShares(poolId);
        assertTrue(liqBefore > 0, "Liquidity should be > 0 after initial deposit");

        vm.recordLogs();
        vm.prank(keeper);
        spotHook.claimPendingFees(poolId);

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

        (,, uint128 liqAfter) = spotHook.getPoolReservesAndShares(poolId);
        assertGt(liqAfter, liqBefore, "liquidity did not grow");

        // cooldown check
        vm.warp(block.timestamp + 1 minutes);
        vm.recordLogs();
        vm.prank(keeper);
        spotHook.claimPendingFees(poolId);

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

    /* ---------- PoolManager Unlock Callback ---------- */
    /// @notice Implements IUnlockCallback so this test contract can be the caller of `PoolManager.unlock`.
    ///         It settles `units` of `cur` from *this* contract to the PoolManager and then credits the
    ///         same amount to `hookAddr` via `take`, effectively increasing the spotHook's internal claim balance.
    /// @dev    Encoding must match the data packed in `_creditInternalBalance` – `(Currency,uint256,address)`.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(pm), "only manager"); // safety – callback can only originate from PoolManager

        (Currency cur, uint256 units, address hookAddr) = abi.decode(data, (Currency, uint256, address));
        if (units == 0) return bytes(""); // nothing to do

        // 1. Transfer `units` of `cur` from this contract to the PoolManager (internal credit to this contract)
        CurrencySettlerExtension.settleCurrency(pm, cur, units);

        // 2. Move that freshly credited internal balance to the spotHook's claim account
        pm.take(cur, hookAddr, units);

        // Return empty bytes – PoolManager does not rely on the return payload for this simple op
        return bytes("");
    }
}
