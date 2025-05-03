// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26; // Use caret for consistency

import {Test, console2} from "forge-std/Test.sol"; // Added console2
import {ForkSetup} from "./ForkSetup.t.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
// Import the new interface and implementation
import {IDynamicFeeManager} from "../../src/interfaces/IDynamicFeeManager.sol";
import {DynamicFeeManager} from "../../src/DynamicFeeManager.sol";
import {TickCheck} from "../../src/libraries/TickCheck.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolPolicyManager} from "../../src/PoolPolicyManager.sol"; // Assuming this is still used
import {SwapParams} from "v4-core/src/types/PoolOperation.sol"; // Added import
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TruncGeoOracleMulti} from "../../src/TruncGeoOracleMulti.sol"; // <-- Added import

// Renamed contract for clarity
contract SurgeFeeDecayTest is Test, ForkSetup {
    using PoolIdLibrary for PoolKey; // Add using directive for PoolIdLibrary

    PoolKey internal key;
    PoolId internal pid;

    // Use the interface type
    IDynamicFeeManager internal dfm;
    PoolSwapTest internal swapper;

    // Stores initial total fee (base fee before any surge)
    uint256 internal initialBaseFee;

    // Store the last tick to compare during swap simulation
    mapping(PoolId => int24) public lastTick;

    // Cached base‐fee after initialise/decay calc (will be 100 PPM after 1st notify)
    uint256 internal baseFeeAfterInit;

    // Flag to show info during test setup
    bool public showTickInfo = true;

    function setUp() public override {
        super.setUp(); // Calls ForkSetup which deploys contracts including dynamicFeeManager

        // Cache pool details; use inherited usdc/weth
        key = poolKey;
        pid = poolId;

        // Cast the deployed manager to the interface type
        dfm = IDynamicFeeManager(address(dynamicFeeManager));
        swapper = swapRouter;

        // Get the initial tick
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, pid);

        // Store initial total fee (surge is 0 initially)
        (uint256 baseFee,) = dfm.getFeeState(pid);
        baseFeeAfterInit = baseFee; // = cap × 100
        assertTrue(baseFeeAfterInit > 0, "Initial base fee should be set");

        // base amounts for LP deposit - ADJUSTED FOR PRICE
        uint256 amt0 = 300_000 * 1e6; // 300k USDC
        uint256 amt1 = 100 ether; // 100 WETH

        // cover swap callbacks that may pull massive deltas
        uint256 largeWeth = 10 ** 30; // Keep WETH high for swaps
        uint256 largeUsdc = 10 ** 30; // Add large USDC deal for swaps

        // Mint & approve using inherited tokens (cast to address)
        deal(address(usdc), address(this), amt0 + largeUsdc);
        deal(address(weth), address(this), amt1 + largeWeth);

        uint256 MAX = type(uint256).max;
        // always allow both contracts to pull
        ERC20(address(usdc)).approve(address(liquidityManager), MAX);
        ERC20(address(weth)).approve(address(liquidityManager), MAX);
        ERC20(address(usdc)).approve(address(poolManager), MAX);
        ERC20(address(weth)).approve(address(poolManager), MAX);

        // Deposit full-range liquidity
        _addLiquidityAsGovernance(pid, amt0, amt1, 0, 0, address(this));

        // Pre-funding and approvals for PoolManager and swapper remain the same
        deal(address(usdc), address(swapper), 100_000 * 1e6);
        deal(address(weth), address(swapper), 100 ether);

        vm.stopPrank(); // Ensure prank is stopped from ForkSetup if any
        ERC20(address(usdc)).approve(address(poolManager), type(uint256).max);
        ERC20(address(weth)).approve(address(poolManager), type(uint256).max);
        ERC20(address(usdc)).approve(address(swapper), type(uint256).max);
        ERC20(address(weth)).approve(address(swapper), type(uint256).max);

        emit log_string("--- Full Deployment & Configuration Complete ---");

        // 5. Final Sanity Checks (Optional, covered by testForkSetupComplete)
        emit log_string("ForkSetup complete.");

        //
        // ── HOOK / ORACLE WIRING ────────────────────────────
        //
        // Ensure pool is enabled in the oracle deployed by ForkSetup
        // Cast to concrete type for isOracleEnabled check
        address oracleAddr = address(oracle);
        if (!TruncGeoOracleMulti(oracleAddr).isOracleEnabled(pid)) {
            console2.log("Oracle not enabled for this pool, skipping test");
            return;
        }

        // ---- Hook Simulation Setup ----
        // 3) Initialize the DynamicFeeManager for this pool so getFeeState() works
        (, int24 initTick,,) = StateLibrary.getSlot0(poolManager, pid);
        vm.prank(deployerEOA); // Should the PolicyManager owner initialize? Or the hook? Assuming deployer for now.
        dfm.initialize(pid, initTick);

        // Store the initial tick as the 'lastTick' for the first swap comparison
        lastTick[pid] = currentTick;
        // -----------------------------

        // Allow the test contract to manage liquidity via PoolManager directly
        _dealAndApprove(usdc, address(this), type(uint256).max, address(poolManager));
        _dealAndApprove(weth, address(this), type(uint256).max, address(poolManager));

        // bootstrap not needed – oracle will learn MTB via CAP events

        // Set a short decay period for testing
        vm.startPrank(deployerEOA);
    }

    /// @dev Helper to trigger a CAP event by directly notifying the DynamicFeeManager
    function _triggerCap() internal {
        console2.log("--- Triggering CAP event (direct notification) ---");

        // Use the Spot hook reference directly
        address hook = address(fullRange);

        // Directly notify the DynamicFeeManager with capped=true, simulating a price cap event
        // This bypasses the complex swap and oracle logic while still testing the fee mechanism
        vm.prank(hook);
        dfm.notifyOracleUpdate(pid, true);

        console2.log("CAP event triggered - Dynamic fee manager notified with capped=true");
    }

    function test_initialSurgeIsZero() external {
        // Use new getter
        (uint256 baseFee, uint256 surgeFee) = dfm.getFeeState(pid);
        assertEq(surgeFee, 0, "surge must start at zero");
        assertEq(baseFee, baseFeeAfterInit, "base fee mismatch");
    }

    function test_fullSurgeOnCap() external {
        _triggerCap();

        // Use new getter
        (uint256 baseFee, uint256 surgeFee) = dfm.getFeeState(pid);
        uint256 mult = policyManager.getSurgeFeeMultiplierPpm(pid);
        uint256 expectedSurge = baseFee * mult / 1e6;

        assertEq(surgeFee, expectedSurge, "surge != base*mult after cap");
        assertEq(baseFee + surgeFee, baseFee + expectedSurge, "total fee inconsistent");
    }

    function test_decayReachesZeroAtExactEnd() external {
        _triggerCap(); // Start the decay
        uint256 decayPeriod = policyManager.getSurgeDecayPeriodSeconds(pid); // Use per-pool value

        // Warp to exactly end
        vm.warp(block.timestamp + decayPeriod);
        vm.roll(block.number + 1);

        (uint256 currentBaseFee, uint256 currentSurgeFee) = dfm.getFeeState(pid);

        assertEq(currentSurgeFee, 0, "surge component must be zero exactly at decay end");
        // Base fee might have changed due to frequency decay over time, so check against currentBaseFee
        assertEq(
            currentBaseFee + currentSurgeFee, currentBaseFee, "total fee should equal current base fee at decay end"
        );
    }

    function test_linearDecayMidway() external {
        _triggerCap(); // Start the decay
        uint256 decayPeriod = policyManager.getSurgeDecayPeriodSeconds(pid);
        uint256 mult = policyManager.getSurgeFeeMultiplierPpm(pid);

        // Get base fee and initial surge after trigger
        (uint256 baseAfterCap, uint256 surgeFeeAfterCap) = dfm.getFeeState(pid);
        uint256 totalFeeAfterCap = baseAfterCap + surgeFeeAfterCap;

        // Warp halfway
        vm.warp(block.timestamp + (decayPeriod / 2));
        vm.roll(block.number + 1);

        // Get fee state at midpoint
        (uint256 baseMidway, uint256 surgeMidway) = dfm.getFeeState(pid);
        uint256 totalFeeMidway = baseMidway + surgeMidway;

        // Base fee should remain unchanged
        assertEq(baseMidway, baseAfterCap, "Base fee changed during decay");

        // Surge fee should be roughly half of initial surge
        assertApproxEqRel(
            surgeMidway,
            surgeFeeAfterCap / 2,
            1e16, // Allow 1% tolerance
            "Surge not ~50% decayed"
        );

        // Total fee should be base + decayed surge
        assertEq(totalFeeMidway, baseMidway + surgeMidway, "Total fee inconsistent");
        assertTrue(totalFeeMidway < totalFeeAfterCap, "Total fee did not decrease");
        assertTrue(totalFeeMidway > baseAfterCap, "Total fee below base fee");
    }

    function test_recapResetsSurge() external {
        _triggerCap(); // First cap
        uint256 decayPeriod = policyManager.getSurgeDecayPeriodSeconds(pid);
        uint256 mult = policyManager.getSurgeFeeMultiplierPpm(pid);

        // Get base fee after trigger
        (uint256 baseAfterCap,) = dfm.getFeeState(pid);
        uint256 initialSurge = baseAfterCap * mult / 1e6;

        // Warp partway into decay
        vm.warp(block.timestamp + (decayPeriod / 4));
        vm.roll(block.number + 1);

        (uint256 base1, uint256 surge1) = dfm.getFeeState(pid);
        assertTrue(surge1 < initialSurge, "should have started decay");
        assertApproxEqAbs(surge1, initialSurge * 3 / 4, initialSurge / 100, "Surge not approx 3/4");

        // Trigger a second cap
        _triggerCap();
        assertTrue(dfm.isCAPEventActive(pid), "inCap should stay true after recap");

        (uint256 base2, uint256 surge2) = dfm.getFeeState(pid);
        assertEq(surge2, initialSurge, "recap must reset to full initial surge");
        // Base fee might have changed slightly due to freq update, check against current base
        assertEq(base2 + surge2, base2 + initialSurge, "total fee check after recap");
    }

    function test_SurgeDecayMonotonic() public {
        _triggerCap();
        (, uint256 lastSurge) = dfm.getFeeState(pid);
        uint256 decayPeriod = policyManager.getSurgeDecayPeriodSeconds(pid);
        uint256 step = decayPeriod > 10 ? decayPeriod / 10 : 1; // Ensure step > 0

        assertTrue(step > 0, "Decay period too short for test step");

        for (uint256 i = 1; i <= 10; i++) {
            vm.warp(block.timestamp + step);
            vm.roll(block.number + 1);
            (uint256 currBase, uint256 currSurge) = dfm.getFeeState(pid);
            assertTrue(currSurge <= lastSurge, "Surge increased during decay");
            lastSurge = currSurge;
        }
        // final zero-surge check once we're past the decay window
        vm.warp(block.timestamp + step); // Go past the full period
        vm.roll(block.number + 1);
        (uint256 finalBase, uint256 finalSurge) = dfm.getFeeState(pid);
        assertEq(finalSurge, 0, "Surge did not reach zero");
        assertEq(finalBase + finalSurge, finalBase, "final total != base"); // Check consistency
    }

    function test_RapidSuccessiveCapsNotCompounding() public {
        uint256 mult = policyManager.getSurgeFeeMultiplierPpm(pid);

        // 1. Trigger first cap
        _triggerCap();
        (uint256 base1, uint256 surge1) = dfm.getFeeState(pid);
        uint256 initialSurge = base1 * mult / 1e6;
        assertEq(surge1, initialSurge, "Surge should be full after first cap");

        // 2. Warp a tiny bit and notify (should end cap event if tick didn't revert)
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        (uint256 base2, uint256 surge2) = dfm.getFeeState(pid);
        // Surge should have decayed slightly (by 1 second's worth)
        uint256 decayPeriod = policyManager.getSurgeDecayPeriodSeconds(pid);
        uint256 expectedSurge2 =
            (decayPeriod == 0 || decayPeriod <= 1) ? 0 : initialSurge * (decayPeriod - 1) / decayPeriod;
        assertApproxEqAbs(surge2, expectedSurge2, 1, "Surge wrong after 1s decay"); // Allow small tolerance

        // 3. Trigger second cap immediately
        _triggerCap();
        (uint256 base3, uint256 surge3) = dfm.getFeeState(pid);
        assertEq(surge3, initialSurge, "Recap should reset surge to full");
    }

    // Sanity check test remains the same
    function test_approve_and_transferFrom_works() external {
        deal(address(weth), address(this), 1 ether);
        ERC20(address(weth)).approve(address(poolManager), 1 ether);
        assertEq(
            ERC20(address(weth)).allowance(address(this), address(poolManager)),
            1 ether,
            "WETH allowance check failed in sanity test"
        );
        // Use prank to call transferFrom *as* the poolManager
        vm.startPrank(address(poolManager));
        bool ok = ERC20(address(weth)).transferFrom(address(this), address(poolManager), 1 ether);
        vm.stopPrank();
        assertTrue(ok, "WETH.transferFrom failed in sanity test despite approval");
    }

    /**
     * @notice Verify that fee decay correctly lowers fees over time after a cap
     */
    function test_feeDecay() public {
        // Trigger a cap
        _triggerCap();

        // Get fee immediately after cap
        (uint256 baseAfterCap, uint256 surgeFeeAfterCap) = dfm.getFeeState(pid);
        uint256 totalFeeAfterCap = baseAfterCap + surgeFeeAfterCap;

        // Fast-forward by 10% of decay period
        vm.warp(block.timestamp + (policyManager.getSurgeDecayPeriodSeconds(pid) / 10));

        // 10% through decay period, fee should have decayed about 10%
        (uint256 baseAfter10Percent, uint256 surgeFeeAfter10Percent) = dfm.getFeeState(pid);
        uint256 totalFeeAfter10Percent = baseAfter10Percent + surgeFeeAfter10Percent;
        assertTrue(totalFeeAfter10Percent < totalFeeAfterCap, "Fee did not decay after 10%");

        // Fast-forward to 50% of decay period
        vm.warp(block.timestamp + (4 * policyManager.getSurgeDecayPeriodSeconds(pid) / 10)); // Now 50% through

        // 50% through decay period, fee should have decayed about 50%
        (uint256 baseAfter50Percent, uint256 surgeFeeAfter50Percent) = dfm.getFeeState(pid);
        uint256 totalFeeAfter50Percent = baseAfter50Percent + surgeFeeAfter50Percent;
        assertTrue(totalFeeAfter50Percent < totalFeeAfter10Percent, "Fee did not decay further after 50%");
        
        // The surge component should be roughly half of the *initial* surge
        uint256 initialSurge = surgeFeeAfterCap;
        uint256 expectedSurgeAt50 = initialSurge / 2;       // 50 % of peak
        assertApproxEqRel(
            surgeFeeAfter50Percent,
            expectedSurgeAt50,
            1e16, // Allow 1% tolerance
            "Surge decay not 50 % of initial"
        );

        // Fast-forward to 100% of decay period (complete decay)
        vm.warp(block.timestamp + (policyManager.getSurgeDecayPeriodSeconds(pid) / 2)); // Now 100% through

        // 100% through decay period, fee should be back to base level
        (uint256 baseAfter100Percent, uint256 surgeFeeAfter100Percent) = dfm.getFeeState(pid);
        assertEq(surgeFeeAfter100Percent, 0, "Surge fee not zero after full decay");
        assertEq(baseAfter100Percent, baseAfterCap, "Base fee changed during decay");
    }

    /**
     * @notice Test that swapping again during decay doesn't reset decay timer unless it's a new cap
     */
    function test_noTimerResetDuringNormalSwaps() public {
        // Trigger initial cap
        _triggerCap();

        // Get initial surge fee and timestamp
        (uint256 baseAfterCap, uint256 surgeFeeAfterCap) = dfm.getFeeState(pid);
        uint256 totalFeeAfterCap = baseAfterCap + surgeFeeAfterCap;
        uint256 decayPeriod = policyManager.getSurgeDecayPeriodSeconds(pid);
        bool inCapBeforeDecay = dfm.isCAPEventActive(pid);
        assertTrue(inCapBeforeDecay, "Not in CAP event after trigger");

        // Fast-forward slightly (25% of decay)
        uint256 elapsedTime = decayPeriod / 4;
        vm.warp(block.timestamp + elapsedTime);

        // Verify partial decay occurred
        (uint256 basePartialDecay, uint256 surgeFeePartialDecay) = dfm.getFeeState(pid);
        uint256 totalFeePartialDecay = basePartialDecay + surgeFeePartialDecay;
        
        // Base fee should be unchanged due to rate limiting
        assertEq(basePartialDecay, baseAfterCap, "Base fee should not change during decay");
        
        // Surge should have decayed to ~75% of original
        assertApproxEqRel(
            surgeFeePartialDecay,
            surgeFeeAfterCap * 3 / 4, // 75% of original surge
            1e16, // Allow 1% tolerance
            "Unexpected surge fee after 25% decay"
        );
        
        // Instead of an actual swap, simulate an oracle update WITHOUT a CAP
        vm.prank(address(fullRange)); // Act as the hook
        dfm.notifyOracleUpdate(pid, false); // Notify with tickWasCapped = false
        
        // The inCap flag should still be true since decay is not complete
        bool inCapAfterNonCap = dfm.isCAPEventActive(pid);
        assertTrue(inCapAfterNonCap, "inCap incorrectly cleared before full decay");
        
        // Verify decay continued and was not reset
        (uint256 baseAfterNotify, uint256 surgeFeeAfterNotify) = dfm.getFeeState(pid);
        
        // Surge fee should be unchanged after the non-cap notification
        assertEq(surgeFeeAfterNotify, surgeFeePartialDecay, "Surge fee incorrectly changed by non-cap oracle update");
        
        // Base fee should still match initial value (due to rate limiting)
        assertEq(baseAfterNotify, baseAfterCap, "Base fee incorrectly changed after non-cap update");
        
        // Now fast-forward to complete decay
        vm.warp(block.timestamp + decayPeriod);
        
        // Verify surge is now zero
        (uint256 baseAfterFullDecay, uint256 surgeFeeAfterFullDecay) = dfm.getFeeState(pid);
        assertEq(surgeFeeAfterFullDecay, 0, "Surge not zero after full decay period");
        
        // Base fee should still match initial value
        assertEq(baseAfterFullDecay, baseAfterCap, "Base fee incorrectly changed after full decay");
        
        // Notify without a CAP again, which should now clear inCap since surge is zero
        vm.prank(address(fullRange));
        dfm.notifyOracleUpdate(pid, false);
        
        // Verify inCap is cleared after full decay
        bool inCapAfterFullDecay = dfm.isCAPEventActive(pid);
        assertFalse(inCapAfterFullDecay, "inCap not cleared after full decay");
    }

    /**
     * @notice Test that a new cap during decay resets the timer and fee
     */
    function test_newCapResetsDecay() public {
        // Trigger initial cap
        _triggerCap();

        // Get initial fee state
        (uint256 baseAfterCap, uint256 surgeFeeAfterCap) = dfm.getFeeState(pid);
        uint256 totalFeeAfterCap = baseAfterCap + surgeFeeAfterCap;
        uint256 decayPeriod = policyManager.getSurgeDecayPeriodSeconds(pid);

        // Fast-forward through 50% of decay
        uint256 elapsedTime = decayPeriod / 2;
        vm.warp(block.timestamp + elapsedTime);

        // Get fee at 50% decay
        (uint256 basePartialDecay, uint256 surgeFeePartialDecay) = dfm.getFeeState(pid);
        uint256 totalFeePartialDecay = basePartialDecay + surgeFeePartialDecay;
        
        // Verify partial decay occurred
        assertTrue(totalFeePartialDecay < totalFeeAfterCap, "Fee did not decay before second cap");
        assertApproxEqRel(
            surgeFeePartialDecay,
            surgeFeeAfterCap / 2,
            1e16, // Allow 1% tolerance
            "Surge not ~50% decayed before second cap"
        );

        // Trigger a second cap
        _triggerCap();

        // Get new fee state after second cap
        (uint256 baseAfterSecondCap, uint256 surgeFeeAfterSecondCap) = dfm.getFeeState(pid);
        uint256 totalFeeAfterSecondCap = baseAfterSecondCap + surgeFeeAfterSecondCap;

        // Verify surge fee was reset to maximum
        assertEq(baseAfterSecondCap, baseAfterCap, "Base fee changed after second cap");
        assertEq(surgeFeeAfterSecondCap, surgeFeeAfterCap, "Surge fee not reset to maximum after second cap");
        assertEq(totalFeeAfterSecondCap, totalFeeAfterCap, "Total fee not reset to maximum after second cap");
    }
}
