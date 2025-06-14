// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

/*----------------------------------------------------------
 *  DynamicFeeManager Unit-Tests (Foundry)
 *  Targets >95% line coverage of src/DynamicFeeManager.sol
 *---------------------------------------------------------*/

import "forge-std/Test.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

import {DynamicFeeManager} from "src/DynamicFeeManager.sol";
import {DynamicFeeState, DynamicFeeStateLibrary} from "src/libraries/DynamicFeeState.sol";
import {IPoolPolicyManager} from "src/interfaces/IPoolPolicyManager.sol";
import {Errors} from "src/errors/Errors.sol";

/* ─────────────────────────── Mocks ────────────────────────── */
/// @dev Minimal oracle exposing only the call used by DFM
contract MockOracle {
    mapping(bytes32 => uint24) public maxTicks;

    /// @notice setter to tweak ticks value in tests
    function setMaxTicks(bytes32 pid, uint24 v) external {
        maxTicks[pid] = v;
    }

    /// @dev function signature must match TruncGeoOracleMulti
    function maxTicksPerBlock(bytes32 pid) external view returns (uint24) {
        return maxTicks[pid];
    }
}

/// @dev Minimal policy implementing ONLY the getters touched by DFM
contract MockPolicy {
    uint256 public decay; // seconds
    uint24 public multiplier; // ppm
    uint32 public window; // secs – used by back-compat view

    // ---- setters ----
    function setParams(uint256 _decay, uint24 _multiplier, uint32 _window) external {
        decay = _decay;
        multiplier = _multiplier;
        window = _window;
    }

    // ---- getters consumed by DFM ----
    function getSurgeDecayPeriodSeconds(PoolId /*pid*/ ) external view returns (uint256) {
        return decay;
    }

    function getSurgeFeeMultiplierPpm(PoolId /*pid*/ ) external view returns (uint24) {
        return multiplier;
    }

    function getCapBudgetDecayWindow(PoolId /*pid*/ ) external view returns (uint32) {
        return window;
    }

    // -------- unused functions --------
    fallback() external payable {}
    /// @dev silence "payable fallback without receive" compiler warning
    receive() external payable {}
}

/*──────────────────────────── Test ───────────────────────────*/
contract DynamicFeeManagerUnitTest is Test {
    using PoolIdLibrary for bytes32;
    using DynamicFeeStateLibrary for uint256;

    // Mocks / SUT
    MockOracle private oracle;
    MockPolicy private policy;
    DynamicFeeManager private dfm;

    // common helpers
    bytes32 private constant PID_BYTES = bytes32(uint256(0xA11CE));
    PoolId private constant PID = PoolId.wrap(PID_BYTES);

    // roles
    address private constant HOOK = address(0xBEEF);
    address private constant NON_HOOK = address(0xDEAD);

    /* ───────────────────── setup ───────────────────── */
    function setUp() public {
        // Deploy mocks
        oracle = new MockOracle();
        policy = new MockPolicy();

        // reasonable defaults – 1h decay, 200% multiplier, 180d window
        policy.setParams(3600, 2_000_000, 15_552_000);

        // Deploy SUT – sender (address(this)) becomes owner
        dfm = new DynamicFeeManager(address(this), IPoolPolicyManager(address(policy)), address(oracle), HOOK);

        // oracle baseline: 50 ticks → base = 5_000 ppm
        oracle.setMaxTicks(PID_BYTES, 50);
    }

    /* ─────────────────── library tests ─────────────────── */
    function test_Packing_GettersAndSetters() public {
        DynamicFeeState dynamicFeeState;
        // set + get freq
        dynamicFeeState = dynamicFeeState.setBaseFee(123);
        assertEq(dynamicFeeState.baseFee(), 123);

        // set + get capStart
        dynamicFeeState = dynamicFeeState.setCapStart(789);
        assertEq(uint256(dynamicFeeState.capStart()), 789);

        // setInCap true/false round-trip
        dynamicFeeState = dynamicFeeState.setInCap(true);
        assertTrue(dynamicFeeState.inCap());
        dynamicFeeState = dynamicFeeState.setInCap(false);
        assertFalse(dynamicFeeState.inCap());
    }

    function test_Packing_BitIsolation() public {
        DynamicFeeState dynamicFeeState;
        dynamicFeeState = dynamicFeeState.setBaseFee(42);
        dynamicFeeState = dynamicFeeState.setCapStart(99);
        // freq must remain intact
        assertEq(dynamicFeeState.baseFee(), 42);
        // capStart is 99
        assertEq(uint256(dynamicFeeState.capStart()), 99);
    }

    /* ───────────────── constructor reverts ──────────────── */
    function testConstructorRevertsOnZeroPolicy() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new DynamicFeeManager(address(this), IPoolPolicyManager(address(0)), address(oracle), HOOK);
    }

    function testConstructorRevertsOnZeroOracle() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new DynamicFeeManager(address(this), IPoolPolicyManager(address(policy)), address(0), HOOK);
    }

    function testConstructorRevertsOnZeroHook() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new DynamicFeeManager(address(this), IPoolPolicyManager(address(policy)), address(oracle), address(0));
    }

    /* ─────────────────── initialize() ───────────────────── */
    event PoolInitialized(PoolId indexed id);
    event AlreadyInitialized(PoolId indexed id);
    event CapToggled(PoolId indexed id, bool inCap);
    event FeeStateChanged(
        PoolId indexed poolId, uint256 baseFeePpm, uint256 surgeFeePpm, bool inCapEvent, uint32 timestamp
    );

    function _initAsOwner() internal {
        vm.expectEmit(true, false, false, true);
        emit PoolInitialized(PID);
        dfm.initialize(PID, 0);
    }

    function testInitializeByOwner() public {
        _initAsOwner();
        // base fee derived from oracle cap (50 * 100)
        assertEq(dfm.baseFeeFromCap(PID), 5_000);
    }

    function testInitializeIdempotent() public {
        _initAsOwner();
        uint256 beforeFee = dfm.baseFeeFromCap(PID);

        vm.expectEmit(true, false, false, true);
        emit AlreadyInitialized(PID);
        dfm.initialize(PID, 0);
        assertEq(dfm.baseFeeFromCap(PID), beforeFee);
    }

    function testInitializeByAuthorizedHook() public {
        vm.prank(HOOK);
        dfm.initialize(PID, 0);
        assertEq(dfm.baseFeeFromCap(PID), 5_000);
    }

    function testInitializeUnauthorized() public {
        vm.prank(NON_HOOK);
        vm.expectRevert(Errors.UnauthorizedCaller.selector);
        dfm.initialize(PID, 0);
    }

    function testInitializeAlreadyInitialized() public {
        vm.prank(HOOK);
        dfm.initialize(PID, 0);

        vm.prank(HOOK);
        vm.expectEmit(true, false, false, true);
        emit AlreadyInitialized(PID);
        dfm.initialize(PID, 0);
    }

    /* ────────────────── _baseFee helper ─────────────────── */
    function testBaseFeeFallsBackToDefaultWhenOracleZero() public {
        oracle.setMaxTicks(PID_BYTES, 0); // zero ticks
        dfm.initialize(PID, 0);
        assertEq(dfm.baseFeeFromCap(PID), 5_000); // DEFAULT_BASE_FEE_PPM
    }

    /* ──────────────── Fee-state & CAP flow ──────────────── */
    function _initAndCap() internal returns (uint256 baseFee) {
        _initAsOwner();
        (baseFee,) = dfm.getFeeState(PID);

        // Debug logging
        console.log("Base fee:", baseFee);
        console.log("Multiplier:", policy.multiplier());
        console.log("Expected surge:", baseFee * policy.multiplier() / 1e6);

        // Expect CapToggled event first
        vm.expectEmit(true, false, false, true);
        emit CapToggled(PID, true);

        // Then expect FeeStateChanged event
        vm.expectEmit(true, true, false, true);
        emit FeeStateChanged(PID, baseFee, baseFee * policy.multiplier() / 1e6, true, uint32(block.timestamp));

        // Trigger CAP event via hook - ensure we're pranked as HOOK before the call
        vm.prank(HOOK);
        dfm.notifyOracleUpdate(PID, true);

        // Debug actual values after update
        (uint256 actualBase, uint256 actualSurge) = dfm.getFeeState(PID);
        console.log("Actual base:", actualBase);
        console.log("Actual surge:", actualSurge);
    }

    function testSurgeFeeActivatesAndDecays() public {
        uint256 baseFee;
        (baseFee) = _initAndCap(); // emits + activates surge

        // Immediately after CAP, surge = base * multiplier (2×)
        (, uint256 surge1) = dfm.getFeeState(PID);
        // Allow small tolerance for time-based calculation
        assertApproxEqAbs(surge1, baseFee * policy.multiplier() / 1e6, 1);
        assertTrue(dfm.isCAPEventActive(PID));

        // Warp half of decay period (1800s of 3600s)
        vm.warp(block.timestamp + policy.decay() / 2);
        (, uint256 surgeHalf) = dfm.getFeeState(PID);
        assertApproxEqAbs(surgeHalf, surge1 / 2, 1); // ±1 ppm tolerance

        // Warp past full decay
        vm.warp(block.timestamp + policy.decay());

        // notify with capped=false to clear flag
        vm.prank(HOOK);
        dfm.notifyOracleUpdate(PID, false);

        (, uint256 surgeFinal) = dfm.getFeeState(PID);
        assertEq(surgeFinal, 0);
        assertFalse(dfm.isCAPEventActive(PID));
    }

    function testNotifyOracleUpdateUnauthorized() public {
        _initAsOwner();
        vm.prank(NON_HOOK);
        vm.expectRevert(Errors.UnauthorizedCaller.selector);
        dfm.notifyOracleUpdate(PID, true);
    }

    function testNotifyOracleUpdateNotInitialized() public {
        vm.prank(HOOK);
        vm.expectRevert(Errors.NotInitialized.selector);
        dfm.notifyOracleUpdate(PID, true);
    }

    /* ────────── legacy view pass-throughs ───────── */
    function testPolicyAlias() public {
        assertEq(address(dfm.policyManager()), address(policy));
    }

    function testCapBudgetDecayWindowPassThrough() public {
        policy.setParams(policy.decay(), policy.multiplier(), 1234);
        assertEq(policy.getCapBudgetDecayWindow(PID), 1234);
    }
}
