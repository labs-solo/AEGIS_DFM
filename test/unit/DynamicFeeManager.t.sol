// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*----------------------------------------------------------
 *  DynamicFeeManager Unit-Tests (Foundry)
 *  Targets >95% line coverage of src/DynamicFeeManager.sol
 *---------------------------------------------------------*/

import "forge-std/Test.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {DynamicFeeManager, _P} from "src/DynamicFeeManager.sol";
import {IPoolPolicy} from "src/interfaces/IPoolPolicy.sol";

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
    function getSurgeDecayPeriodSeconds(PoolId /*pid*/) external view returns (uint256) {
        return decay;
    }

    function getSurgeFeeMultiplierPpm(PoolId /*pid*/) external view returns (uint24) {
        return multiplier;
    }

    function getCapBudgetDecayWindow(PoolId /*pid*/) external view returns (uint32) {
        return window;
    }

    // -------- unused functions --------
    fallback() external payable {}
}

/*──────────────────────────── Test ───────────────────────────*/
contract DynamicFeeManagerUnitTest is Test {
    using PoolIdLibrary for bytes32;
    using _P for uint256;

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
        dfm = new DynamicFeeManager(IPoolPolicy(address(policy)), address(oracle), HOOK);

        // oracle baseline: 50 ticks → base = 5_000 ppm
        oracle.setMaxTicks(PID_BYTES, 50);
    }

    /* ─────────────────── library tests ─────────────────── */
    function test_Packing_GettersAndSetters() public {
        uint256 w;
        // set + get freq
        w = w.setFreq(123);
        assertEq(w.freq(), 123);

        // set + get freqL
        w = w.setFreqL(456);
        assertEq(uint256(w.freqL()), 456);

        // set + get capStart
        w = w.setCapSt(789);
        assertEq(uint256(w.capStart()), 789);

        // setInCap true/false round-trip
        w = w.setInCap(true);
        assertTrue(w.inCap());
        w = w.setInCap(false);
        assertFalse(w.inCap());
    }

    function test_Packing_BitIsolation() public {
        uint256 w;
        w = w.setFreq(42);
        w = w.setCapSt(99);
        // freq must remain intact
        assertEq(w.freq(), 42);
        // capStart is 99
        assertEq(uint256(w.capStart()), 99);
    }

    /* ───────────────── constructor reverts ──────────────── */
    function testConstructorRevertsOnZeroPolicy() public {
        vm.expectRevert(bytes("DFM: policy 0"));
        new DynamicFeeManager(IPoolPolicy(address(0)), address(oracle), HOOK);
    }

    function testConstructorRevertsOnZeroOracle() public {
        vm.expectRevert(bytes("DFM: oracle 0"));
        new DynamicFeeManager(IPoolPolicy(address(policy)), address(0), HOOK);
    }

    function testConstructorRevertsOnZeroHook() public {
        vm.expectRevert(DynamicFeeManager.ZeroHookAddress.selector);
        new DynamicFeeManager(IPoolPolicy(address(policy)), address(oracle), address(0));
    }

    /* ─────────────────── initialize() ───────────────────── */
    event PoolInitialized(PoolId indexed id);
    event AlreadyInitialized(PoolId indexed id);

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
        vm.expectRevert(bytes("DFM:auth"));
        dfm.initialize(PID, 0);
    }

    /* ────────────────── _baseFee helper ─────────────────── */
    function testBaseFeeFallsBackToDefaultWhenOracleZero() public {
        oracle.setMaxTicks(PID_BYTES, 0); // zero ticks
        dfm.initialize(PID, 0);
        assertEq(dfm.baseFeeFromCap(PID), 5_000); // DEFAULT_BASE_FEE_PPM
    }

    /* ──────────────── Fee-state & CAP flow ──────────────── */
    event FeeStateChanged(PoolId indexed poolId, uint256 baseFeePpm, uint256 surgeFeePpm, bool inCapEvent);

    function _initAndCap() internal returns (uint256 baseFee) {
        _initAsOwner();
        (baseFee,) = dfm.getFeeState(PID);

        // Trigger CAP event via hook
        vm.prank(HOOK);
        vm.expectEmit(true, true, true, true);
        // We don't match full args due to gas savings – only topics
        emit FeeStateChanged(PID, baseFee, baseFee * policy.multiplier() / 1e6, true);
        dfm.notifyOracleUpdate(PID, true);
    }

    function testSurgeFeeActivatesAndDecays() public {
        uint256 baseFee;
        (baseFee) = _initAndCap(); // emits + activates surge

        // Immediately after CAP, surge = base * multiplier (2×)
        (, uint256 surge1) = dfm.getFeeState(PID);
        assertEq(surge1, baseFee * policy.multiplier() / 1e6);
        assertTrue(dfm.isCAPEventActive(PID));

        // Warp half of decay period (1800s of 3600s)
        vm.warp(block.timestamp + policy.decay() / 2);
        (, uint256 surgeHalf) = dfm.getFeeState(PID);
        assertApproxEqAbs(surgeHalf, surge1 / 2, 1); // ±1 ppm tolerance

        // Warp past full decay
        vm.warp(block.timestamp + policy.decay());
        // notify with capped=false to clear flag
        vm.prank(HOOK);
        vm.expectEmit(true, true, true, true);
        emit FeeStateChanged(PID, baseFee, 0, false);
        dfm.notifyOracleUpdate(PID, false);

        (, uint256 surgeFinal) = dfm.getFeeState(PID);
        assertEq(surgeFinal, 0);
        assertFalse(dfm.isCAPEventActive(PID));
    }

    function testNotifyOracleUpdateUnauthorized() public {
        _initAsOwner();
        vm.prank(NON_HOOK);
        vm.expectRevert(DynamicFeeManager.UnauthorizedHook.selector);
        dfm.notifyOracleUpdate(PID, true);
    }

    function testNotifyOracleUpdateNotInitialized() public {
        vm.prank(HOOK);
        vm.expectRevert(bytes("DFM: not init"));
        dfm.notifyOracleUpdate(PID, true);
    }

    /* ────────── legacy view pass-throughs ───────── */
    function testPolicyAlias() public {
        assertEq(address(dfm.policy()), address(policy));
    }

    function testCapBudgetDecayWindowPassThrough() public {
        policy.setParams(policy.decay(), policy.multiplier(), 1234);
        assertEq(dfm.getCapBudgetDecayWindow(PID), 1234);
    }
} 