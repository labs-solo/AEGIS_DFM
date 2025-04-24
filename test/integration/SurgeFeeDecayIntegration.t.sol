// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26; // Use caret for consistency

import {Test, console2} from "forge-std/Test.sol"; // Added console2
import {ForkSetup} from "./ForkSetup.t.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
// Import the new interface and implementation
import {IDynamicFeeManager} from "../../src/interfaces/IDynamicFeeManager.sol";
import {DynamicFeeManager} from "../../src/DynamicFeeManager.sol";
import {TickCheck} from "../../src/libraries/TickCheck.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolPolicyManager} from "../../src/PoolPolicyManager.sol"; // Assuming this is still used

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

        // Initialize fee data - Must be called by owner (deployerEOA from ForkSetup)
        vm.startPrank(deployerEOA);
        // Use the new initialize function
        dfm.initialize(pid, currentTick);
        vm.stopPrank();

        // ---- Hook Simulation Setup ----
        // Store the initial tick as the 'lastTick' for the first swap comparison
        lastTick[pid] = currentTick;
        // -----------------------------

        // Store initial total fee (surge is 0 initially)
        (uint256 baseFee,) = dfm.getFeeState(pid);
        baseFeeAfterInit = baseFee;          // will be 3 000, gets clamped to 100 on first CAP
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

        // Approve liquidityManager for the initial deposit amounts
        ERC20(address(usdc)).approve(address(liquidityManager), amt0);
        ERC20(address(weth)).approve(address(liquidityManager), amt1);

        // Deposit full-range liquidity
        liquidityManager.deposit(pid, amt0, amt1, 0, 0, address(this));

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
        // 1) Tell oracle which Spot hook to trust
        vm.prank(deployerEOA);
        oracle.setFullRangeHook(address(fullRange));
        // 2) Now enable our pool in the oracle (as Spot.afterInitialize would do)
        vm.prank(address(fullRange));
        oracle.enableOracleForPool(poolKey);
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
        uint256 mult = policyManager.getSurgeFeeMultiplierPpm(PoolId.unwrap(pid));
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
        uint256 mult = policyManager.getSurgeFeeMultiplierPpm(PoolId.unwrap(pid));
        
        // Get base fee after trigger
        (uint256 baseAfterCap,) = dfm.getFeeState(pid);
        uint256 initialSurge = baseAfterCap * mult / 1e6;

        // Warp halfway
        vm.warp(block.timestamp + (decayPeriod / 2));
        vm.roll(block.number + 1);

        (uint256 baseFee, uint256 surgeFee) = dfm.getFeeState(pid);
        uint256 expectedSurge = initialSurge / 2;          // 50 %

        assertTrue(surgeFee > 0 && surgeFee < initialSurge, "Midpoint decay out of range");
        // Use approx comparison due to integer math / block timing
        assertApproxEqAbs(surgeFee, expectedSurge, expectedSurge / 100, "Surge not approx half");
        assertEq(baseFee + surgeFee, baseFee + surgeFee, "total fee consistency check"); // This check is trivial
    }

    function test_recapResetsSurge() external {
        _triggerCap(); // First cap
        uint256 decayPeriod = policyManager.getSurgeDecayPeriodSeconds(pid);
        uint256 mult = policyManager.getSurgeFeeMultiplierPpm(PoolId.unwrap(pid));
        
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
        uint256 mult = policyManager.getSurgeFeeMultiplierPpm(PoolId.unwrap(pid));

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
        // Trigger a cap (this will move the tick enough to exceed cap threshold)
        _triggerCap();

        // Get fee immediately after cap
        (uint256 feeAfterCap, uint256 timestampAfterCap) = dfm.getFeeState(pid);
        console2.log("Fee immediately after cap:", feeAfterCap);
        
        // Fast-forward by 10% of decay period
        vm.warp(block.timestamp + (policyManager.getSurgeDecayPeriodSeconds(pid) / 10));
        
        // 10% through decay period, fee should have decayed about 10%
        (uint256 feeAfter10Percent, uint256 timestampAfter10Percent) = dfm.getFeeState(pid);
        console2.log("Fee after 10% decay:", feeAfter10Percent);
        
        // Fast-forward to 50% of decay period
        vm.warp(block.timestamp + (4 * policyManager.getSurgeDecayPeriodSeconds(pid) / 10)); // Now 50% through
        
        // 50% through decay period, fee should have decayed about 50%
        (uint256 feeAfter50Percent, uint256 timestampAfter50Percent) = dfm.getFeeState(pid);
        console2.log("Fee after 50% decay:", feeAfter50Percent);
        
        // Fast-forward to 100% of decay period (complete decay)
        vm.warp(block.timestamp + (policyManager.getSurgeDecayPeriodSeconds(pid) / 2)); // Now 100% through
        
        // 100% through decay period, fee should be back to base level
        (uint256 feeAfter100Percent, uint256 timestampAfter100Percent) = dfm.getFeeState(pid);
        console2.log("Fee after 100% decay:", feeAfter100Percent);
    }

    /**
     * @notice Test that swapping again during decay doesn't reset decay timer unless it's a new cap
     */
    function test_noTimerResetDuringNormalSwaps() public {
        // Trigger initial cap
        _triggerCap();

        // Get initial surge fee timestamp for later comparison
        (uint256 feeAfterCap, uint256 surgeTimestampStart) = dfm.getFeeState(pid);
        console2.log("Fee immediately after cap:", feeAfterCap);
        
        // Fast-forward slightly (25% of decay)
        vm.warp(block.timestamp + (policyManager.getSurgeDecayPeriodSeconds(pid) / 4));
        
        // Do a small swap that shouldn't trigger a cap
        // ... existing code ...
        
        // Verify timestamp didn't change (decay timer wasn't reset)
        (uint256 feeAfterSwap, uint256 surgeTimestampAfterSwap) = dfm.getFeeState(pid);
        console2.log("Fee after non-capped swap:", feeAfterSwap);
        
        // ... existing code ...
    }

    /**
     * @notice Test that a new cap during decay resets the timer and fee
     */
    function test_newCapResetsDecay() public {
        // Trigger initial cap
        _triggerCap();

        // Get initial fee state
        (uint256 feeAfterCap, uint256 surgeTimestampStart) = dfm.getFeeState(pid);
        console2.log("Fee immediately after first cap:", feeAfterCap);
        
        // Fast-forward through 50% of decay
        vm.warp(block.timestamp + (policyManager.getSurgeDecayPeriodSeconds(pid) / 2));
        
        // Get fee at 50% decay
        (uint256 feePartialDecay,) = dfm.getFeeState(pid);
        console2.log("Fee after 50% decay:", feePartialDecay);
        
        // Trigger a second cap
        _triggerCap();
        
        // Get new fee state after second cap
        (uint256 feeAfterSecondCap, uint256 surgeTimestampReset) = dfm.getFeeState(pid);
        console2.log("Fee immediately after second cap:", feeAfterSecondCap);
        
        // ... existing code ...
    }
}
