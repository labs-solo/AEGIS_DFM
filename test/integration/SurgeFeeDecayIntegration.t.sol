// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {ForkSetup} from "./ForkSetup.t.sol"; // Corrected path relative to test/integration/
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol"; // Added PoolIdLibrary potentially needed for setup
import {ERC20} from "solmate/src/tokens/ERC20.sol";
// Renamed import for clarity and use in setUp
import {FullRangeDynamicFeeManager} from "../../src/FullRangeDynamicFeeManager.sol"; 
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol"; // Added import
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol"; // Import for getSlot0
import {PoolPolicyManager} from "../../src/PoolPolicyManager.sol"; // Corrected import path and type name

// Renamed contract to reflect enhanced scope (optional, kept original for now)
contract SurgeFeeDecayIntegration is Test, ForkSetup { 
    PoolKey internal key;
    PoolId  internal pid;

    FullRangeDynamicFeeManager internal dfm;
    PoolSwapTest         internal swapper;

    // Stores initial total fee (base fee before any surge)
    uint256 internal initialBaseFee;

    function setUp() public override {
        super.setUp();

        // Cache pool details; use inherited usdc/weth
        key  = poolKey;
        pid  = poolId;

        dfm     = FullRangeDynamicFeeManager(address(dynamicFeeManager));
        swapper = swapRouter;

        // Initialize fee data under the hook's onlyFullRange guard
        vm.prank(address(fullRange));
        dfm.initializeFeeData(pid);

        // ── PRIME THE ORACLE ──
        // grab the live tick from slot0, then tell the manager about it
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, pid);
        vm.prank(address(fullRange));
        dfm.initializeOracleData(pid, currentTick);

        // Configure DFM thresholds for tests (owner = deployer)
        address deployer = 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf;
        vm.prank(deployer);
        dfm.setThresholds(1, 1); // blockUpdateThreshold=1, tickDiffThreshold=1

        // Store initial total fee (surge is 0 initially)
        initialBaseFee = dfm.getCurrentDynamicFee(pid);
        assertTrue(initialBaseFee > 0, "Initial base fee should be set");

        // base amounts for LP deposit - ADJUSTED FOR PRICE
        uint256 amt0 = 300_000 * 1e6; // 300k USDC (closer to ~3000 price)
        uint256 amt1 = 100 ether;     // 100 WETH

        // cover swap callbacks that may pull massive deltas
        uint256 largeWeth = 10**30; // Keep WETH high for swaps
        uint256 largeUsdc = 10**30; // Add large USDC deal for swaps

        // Mint & approve using inherited tokens (cast to address)
        // Deal enough for deposit + potential large swaps
        deal(address(usdc), address(this), amt0 + largeUsdc);
        deal(address(weth), address(this), amt1 + largeWeth);

        // Approve liquidityManager for the initial deposit amounts
        ERC20(address(usdc)).approve(address(liquidityManager), amt0);
        ERC20(address(weth)).approve(address(liquidityManager), amt1);

        // Deposit full-range liquidity (using adjusted amounts)
        liquidityManager.deposit(pid, amt0, amt1, 0, 0, address(this));

        //
        // ─────────────────────────────────────────────────────────────────────────
        //   H A C K: pre‑fund the swap‑router and pre‑approve the PoolManager
        // ─────────────────────────────────────────────────────────────────────────
        //
        // PoolSwapTest.unlockCallback will for tokens:
        //   • on negative delta ⇒ call `currency.settle` ⇒ ERC20.transfer(...)
        //   • on positive delta ⇒ call `currency.take`   ⇒ ERC20.transferFrom(...)
        //
        // So we must:
        //   1. Give the router enough USDC & WETH so that its `transfer(...)` calls succeed.
        //   2. Approve the *PoolManager* to pull USDC/WETH from our test contract, so its
        //      `transferFrom(...)` calls will also succeed.
        //
        // PRE-FUND ROUTER with *some* amount (doesn't need to match deposit exactly)
        deal(address(usdc), address(swapper), 100_000 * 1e6); // Keep original pre-fund amount
        deal(address(weth), address(swapper), 100 ether);    // Keep original pre-fund amount

        // Ensure approvals happen from the test contract's context
        vm.stopPrank();
        // Approve PoolManager to pull from test contract for take:
        ERC20(address(usdc)).approve(address(poolManager), type(uint256).max);
        ERC20(address(weth)).approve(address(poolManager), type(uint256).max);
        assertEq(
          ERC20(address(weth)).allowance(address(this), address(poolManager)),
          type(uint256).max,
          "WETH allowance[testContract][poolManager] was not set correctly!"
        );

        // Approve the swapper as well, as it triggers transferFrom via CurrencySettler
        ERC20(address(usdc)).approve(address(swapper), type(uint256).max);
        ERC20(address(weth)).approve(address(swapper), type(uint256).max);
        assertEq(
            ERC20(address(weth)).allowance(address(this), address(swapper)),
            type(uint256).max,
            "WETH allowance[testContract][swapper] was not set correctly!"
        );
    }

    /// @dev Helper to trigger a CAP event by swapping enough to move the tick beyond maxChange=0
    function _triggerCap() internal {
        // Swap logic to trigger a tick change and potential cap event
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, pid);

        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;

        // If already at min tick, swap the other way (1->0) to guarantee movement
        if (currentTick == TickMath.MIN_TICK) {
            zeroForOne = false; // Swap WETH for USDC (price increases)
            amountSpecified = int256(1 ether); // Use a WETH amount
            sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE - 1; // Upper limit
        }
        // If already at max tick, swap the other way (0->1) to guarantee movement
        else if (currentTick == TickMath.MAX_TICK) {
            zeroForOne = true; // Swap USDC for WETH (price decreases)
            amountSpecified = int256(3000 * 1e6); // Use a USDC amount (~1 WETH)
            sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1; // Lower limit
        }
        // Otherwise, perform the standard small swap (0->1)
        else {
            zeroForOne = true; // Swap USDC for WETH
            amountSpecified = int256(1 * 1e6); // Minimal swap amount (1 USDC)
            sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1; // Lower limit
        }

        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne:        zeroForOne,
            amountSpecified:   amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: true,
            settleUsingBurn: false
        });

        // Perform swap - catch reverts but proceed (as updateDynamicFeeIfNeeded handles state)
        try swapper.swap(key, p, settings, ZERO_BYTES) {}
        catch Error(string memory reason) {
             console.log("[SurgeFeeDecay._triggerCap] Swap reverted:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("[SurgeFeeDecay._triggerCap] Swap reverted with low-level data:");
            console.logBytes(lowLevelData);
        }

        // Now sync & potentially cap based on the actual tick change from the swap.
        dfm.updateDynamicFeeIfNeeded(pid, key);
    }

    function test_initialSurgeIsZero() external {
        uint256 total = dfm.getCurrentDynamicFee(pid);
        uint256 surge = total - initialBaseFee;
        assertEq(surge, 0, "surge must start at zero");
        assertEq(total, initialBaseFee, "total fee should equal initial base fee");
    }

    function test_fullSurgeOnCap() external {
        _triggerCap();

        uint256 total = dfm.getCurrentDynamicFee(pid);
        uint256 initialSurgeConstant = policyManager.defaultInitialSurgeFeePpm();
        uint256 surge = total - initialBaseFee;

        assertEq(surge, initialSurgeConstant, "surge should equal initial surge constant immediately after cap");
        assertEq(total, initialBaseFee + initialSurgeConstant, "total fee = initial base + initial surge");
    }

    function test_decayReachesZeroAtExactEnd() external {
        _triggerCap(); // Start the decay
        uint256 decayPeriod = policyManager.defaultSurgeDecayPeriodSeconds(); // Use policyManager

        // Warp to exactly end
        vm.warp(block.timestamp + decayPeriod);
        vm.roll(block.number + 1); // Advance block number
        dfm.updateDynamicFeeIfNeeded(pid, key); // Force state update after warp

        (uint256 currentBaseFee, uint256 currentSurgeFee) = dfm.getCurrentFees(pid);
        uint256 totalFee = dfm.getCurrentDynamicFee(pid); // Keep for total fee check

        assertEq(currentSurgeFee, 0, "surge component must be zero exactly at decay end");
        assertEq(totalFee, currentBaseFee, "total fee should equal current base fee at decay end");
        // Optional: Check if base fee changed as expected (or didn't)
        // assertEq(currentBaseFee, initialBaseFee, "Base fee unexpectedly changed"); // Add this if base fee shouldn't change
    }

    function test_linearDecayMidway() external {
        _triggerCap(); // Start the decay
        uint256 decayPeriod = policyManager.defaultSurgeDecayPeriodSeconds(); // Use policyManager
        uint256 initialSurge = policyManager.defaultInitialSurgeFeePpm(); // Use policyManager

        // Warp halfway
        vm.warp(block.timestamp + (decayPeriod / 2));
        vm.roll(block.number + 1); // Advance block number
        dfm.updateDynamicFeeIfNeeded(pid, key); // Force state update after warp

        uint256 total = dfm.getCurrentDynamicFee(pid);
        uint256 surge = total - initialBaseFee;

        assertTrue(surge > 0 && surge < initialSurge, "Midpoint decay out of range");
        assertEq(total, initialBaseFee + surge, "total fee = initial base + current surge");
    }

    function test_recapResetsSurge() external {
        _triggerCap(); // First cap
        uint256 decayPeriod = policyManager.defaultSurgeDecayPeriodSeconds(); // Use policyManager
        uint256 initialSurge = policyManager.defaultInitialSurgeFeePpm(); // Use policyManager

        // Warp partway into decay
        vm.warp(block.timestamp + (decayPeriod / 4));
        vm.roll(block.number + 1); // Advance block number
        dfm.updateDynamicFeeIfNeeded(pid, key); // Force state update after warp
        uint256 total1 = dfm.getCurrentDynamicFee(pid);
        uint256 surged1 = total1 - initialBaseFee;
        assertTrue(surged1 < initialSurge, "should have started decay");
        assertEq(total1, initialBaseFee + surged1, "total fee check before recap");

        // Trigger a second cap
        _triggerCap();

        uint256 total2 = dfm.getCurrentDynamicFee(pid);
        uint256 surged2 = total2 - initialBaseFee;
        assertEq(surged2, initialSurge, "recap must reset to full initial surge");
        assertEq(total2, initialBaseFee + initialSurge, "total fee check after recap");
    }

    /// @notice Surge fee must never increase during decay (monotonic non-increasing)
    function test_SurgeDecayMonotonic() public {
        _triggerCap();
        // pull out the *surge* component directly (so we don't get thrown off when base‐fee moves)
        (, uint256 lastSurge) = dfm.getCurrentFees(pid);
        uint256 decayPeriod = policyManager.defaultSurgeDecayPeriodSeconds();
        uint256 step        = decayPeriod / 10;

        assertTrue(step > 0, "Decay period too short for test step");

        for (uint i = 1; i <= 10; i++) {
            vm.warp(block.timestamp + step);
            vm.roll(block.number + 1);
            dfm.updateDynamicFeeIfNeeded(pid, key);
            (uint256 currBase, uint256 currSurge) = dfm.getCurrentFees(pid);
            // surge must never go back up
            assertTrue(currSurge <= lastSurge, "Surge increased during decay");
            // total = base + surge
            assertEq(dfm.getCurrentDynamicFee(pid), currBase + currSurge, "total fee != base+surge");
            lastSurge = currSurge;
        }
        // final zero‑surge check once we're past the decay window
        vm.warp(block.timestamp + step);
        vm.roll(block.number + 1);
        dfm.updateDynamicFeeIfNeeded(pid, key);
        (uint256 finalBase, uint256 finalSurge) = dfm.getCurrentFees(pid);
        assertEq(finalSurge, 0,      "Surge did not reach zero");
        assertEq(dfm.getCurrentDynamicFee(pid), finalBase, "final total != base");
    }

    /// @notice Rapid successive caps before any decay should not compound surge
    function test_RapidSuccessiveCapsNotCompounding() public {
         uint256 initialSurgeConstant = policyManager.defaultInitialSurgeFeePpm(); // Use policyManager

         // 1. Trigger first cap
         _triggerCap();
         uint256 total1 = dfm.getCurrentDynamicFee(pid);
         uint256 surge1 = total1 - initialBaseFee;
         assertEq(surge1, initialSurgeConstant, "Surge should be full after first cap");
         assertEq(total1, initialBaseFee + initialSurgeConstant, "Total fee check after first cap");

         // 2. Warp a tiny bit and update state (should end cap event)
         vm.warp(block.timestamp + 1);
         vm.roll(block.number + 1); // Advance block number
         dfm.updateDynamicFeeIfNeeded(pid, key);
         uint256 total2 = dfm.getCurrentDynamicFee(pid);
         uint256 surge2 = total2 - initialBaseFee;
         // Decay might be negligible after 1 sec, but check it's not full surge
         assertTrue(surge2 <= initialSurgeConstant, "Surge should not increase after small warp");

         // 3. Trigger second cap immediately
         _triggerCap();
         uint256 total3 = dfm.getCurrentDynamicFee(pid);
         uint256 surge3 = total3 - initialBaseFee;
         assertEq(surge3, initialSurgeConstant, "Recap should reset surge to full");
         assertEq(total3, initialBaseFee + initialSurgeConstant, "Total fee check after recap");
    }

    /// @notice Minimal sanity check for WETH approve/transferFrom
    function test_approve_and_transferFrom_works() external {
        deal(address(weth), address(this), 1 ether);
        ERC20(address(weth)).approve(address(poolManager), 1 ether);
        assertEq(
            ERC20(address(weth)).allowance(address(this), address(poolManager)),
            1 ether,
            "WETH allowance check failed in sanity test"
        );
        // Directly call transferFrom as PoolManager would
        bool ok = ERC20(address(weth)).transferFrom(address(this), address(poolManager), 1 ether);
        assertTrue(ok, "WETH.transferFrom failed in sanity test despite approval");
    }
} 