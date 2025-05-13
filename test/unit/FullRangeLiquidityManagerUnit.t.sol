// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPoolPolicy} from "src/interfaces/IPoolPolicy.sol";
import {FullRangeLiquidityManager} from "src/FullRangeLiquidityManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Errors} from "src/errors/Errors.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ExtendedPositionManager} from "src/ExtendedPositionManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolTokenIdUtils} from "src/utils/PoolTokenIdUtils.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

// ─────────────────────────────────────────────────────────────
//  Minimal Permit2 stub implementing just approve()
// ─────────────────────────────────────────────────────────────
contract Permit2Stub is IAllowanceTransfer {
    // ──────────────────────────────────────────────────────────
    //  Minimal, compile-time compliant Permit2 stub
    //  Implements **all** IAllowanceTransfer selectors with
    //  no-op / default behaviour so the contract can be deployed
    //  inside tests. Safe: logic is never invoked in unit tests.
    // ──────────────────────────────────────────────────────────

    // IEIP712
    function DOMAIN_SEPARATOR() external pure override returns (bytes32) {
        return bytes32(0);
    }

    // View: always zero allowance
    function allowance(address, address, address)
        external
        pure
        override
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        return (0, 0, 0);
    }

    // Approve – no-op
    function approve(address, address, uint160, uint48) external override {}

    // Permit (single)
    function permit(address, PermitSingle memory, bytes calldata) external override {}

    // Permit (batch)
    function permit(address, PermitBatch memory, bytes calldata) external override {}

    // transferFrom (single)
    function transferFrom(address, address, uint160, address) external override {}

    // transferFrom (batch)
    function transferFrom(AllowanceTransferDetails[] calldata) external override {}

    // lockdown – no-op
    function lockdown(TokenSpenderPair[] calldata) external override {}

    // invalidateNonces – no-op
    function invalidateNonces(address, address, uint48) external override {}
}

// ─────────────────────────────────────────────────────────────
//  Minimal mock ERC-20 – 18 decimals, free mint for tests
// ─────────────────────────────────────────────────────────────
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory sym_) ERC20(name_, sym_, 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ─────────────────────────────────────────────────────────────
//  Minimal PositionManager stub – only the few selectors FRLM
//  touches are implemented; everything else is a no-op.
// ─────────────────────────────────────────────────────────────
contract PositionManagerStub {
    Permit2Stub internal _permit2;
    uint256 internal _nextId = 1;

    constructor() {
        _permit2 = new Permit2Stub();
    }

    function permit2() external view returns (IAllowanceTransfer) {
        return _permit2;
    }

    // called via FRLM._getOrCreatePosition
    function modifyLiquidities(bytes calldata, uint256) external payable {
        // mimic creating a new NFT – just bump counter
        _nextId += 1;
    }

    // used after _getOrCreatePosition when created == false (not hit in our unit tests)
    function increaseLiquidity(uint256, uint128, uint128, uint128, bytes calldata) external payable {}

    // used by withdraw()
    function decreaseLiquidity(uint256, uint128, uint128, uint128, bytes calldata) external {}

    function nextTokenId() external view returns (uint256) {
        return _nextId;
    }

    // emergencyPullNFT
    function safeTransferFrom(address, address, uint256) external {}

    /// @notice FRLM calls this after mint; no-op stub to avoid revert
    function approve(address, uint256) external {}
}

// ─────────────────────────────────────────────────────────────
//  Mock PoolManager – exposes just the storage hooks StateLibrary
//  relies on (slot0 + position liquidity)
// ─────────────────────────────────────────────────────────────
contract PoolManagerStub {
    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint8 psf;
        uint8 pwf;
    }

    mapping(bytes32 => Slot0) public slots; // storageSlot → slot0
    mapping(bytes32 => mapping(bytes32 => uint128)) public positionLiq; // poolId → posKey → liq

    // ------------------------------------------------------------------
    //   Raw storage loader – mimics PoolManager.extsload for slot0 only
    // ------------------------------------------------------------------
    // StateLibrary.getSlot0(manager, poolId) ultimately performs an
    // `manager.extsload(hashedSlot)`. In production this reads storage
    // directly. In our stub we simply look up the pre-hashed slot key that
    // we saved in `setSlot0` and repack the struct into the expected
    // bytes32 layout.
    function extsload(bytes32 slot) external view returns (bytes32) {
        Slot0 memory s = slots[slot];
        // If the slot has never been set, return zero to mimic default SLOAD
        if (s.sqrtPriceX96 == 0 && s.tick == 0 && s.psf == 0 && s.pwf == 0) {
            return bytes32(0);
        }

        // Pack Slot0 exactly as v4-core (see StateLibrary.getSlot0):
        // | [  0..159] sqrtPriceX96 |
        // | [160..183] tick         |
        // | [184..207] protocolFee  |
        // | [208..231] lpFee        |
        return bytes32(
            uint256(s.sqrtPriceX96) // lower 160 bits
                | (uint256(uint24(uint256(int256(s.tick)))) << 160) // next 24 bits
                | (uint256(s.psf) << 184) // protocol fee
                | (uint256(s.pwf) << 208) // lp fee
        );
    }

    // --- helpers for tests ---
    function setSlot0(PoolId pid, uint160 price) external {
        // Replicate StateLibrary._getPoolStateSlot(poolId) logic
        bytes32 POOLS_SLOT = bytes32(uint256(6));
        bytes32 slotKey = keccak256(abi.encode(PoolId.unwrap(pid), POOLS_SLOT));
        slots[slotKey] = Slot0(price, 0, 0, 0);
    }

    function setPositionLiquidity(PoolId pid, bytes32 posKey, uint128 liq) external {
        positionLiq[PoolId.unwrap(pid)][posKey] = liq;
    }

    // --- StateLibrary entry points ---
    function getSlot0(PoolId pid) external view returns (uint160, uint24, uint8, uint8) {
        bytes32 POOLS_SLOT = bytes32(uint256(6));
        bytes32 slotKey = keccak256(abi.encode(PoolId.unwrap(pid), POOLS_SLOT));
        Slot0 memory s = slots[slotKey];
        // Safe conversion: int24 → uint24
        require(s.tick >= 0, "PoolManagerStub: negative tick");
        uint24 tick = uint24(uint256(int256(s.tick)));
        return (s.sqrtPriceX96, tick, s.psf, s.pwf);
    }

    function getPositionLiquidity(PoolId pid, bytes32 posKey) external view returns (uint128) {
        return positionLiq[PoolId.unwrap(pid)][posKey];
    }

    // dummy take() to satisfy CurrencySettlerExtension in the test suite build
    function take(Currency, address, uint256) external {}
}

// ─────────────────────────────────────────────────────────────
//  Test Harness – derives from the real FRLM and wires mocks
//  (no overrides needed – mocks already absorb all external calls)
// ─────────────────────────────────────────────────────────────
contract FRLMHarness is FullRangeLiquidityManager {
    constructor(IPoolManager _pm, ExtendedPositionManager _posm, address _owner)
        FullRangeLiquidityManager(_pm, ExtendedPositionManager(_posm), IPoolPolicy(address(0)), _owner)
    {}

    // Expose internal helpers for direct unit testing
    function exposedCalculateDepositShares(
        uint128 totalShares,
        uint160 sqrtP,
        int24 spacing,
        uint256 amt0Des,
        uint256 amt1Des,
        uint256 res0,
        uint256 res1
    ) external pure returns (DepositCalculationResult memory r) {
        DepositCalculationResult memory tmp;
        _calculateDepositSharesInternal(totalShares, sqrtP, spacing, amt0Des, amt1Des, res0, res1, tmp);
        return tmp;
    }

    function exposedHandleFirstDeposit(uint160 sqrtP, int24 spacing, uint256 amt0Des, uint256 amt1Des)
        external
        pure
        returns (DepositCalculationResult memory r)
    {
        DepositCalculationResult memory tmp;
        _handleFirstDepositInternal(sqrtP, spacing, amt0Des, amt1Des, tmp);
        return tmp;
    }

    function exposedCalcWithdraw(uint128 liq, uint256 burn, uint256 r0, uint256 r1, uint128 locked, uint128 total)
        external
        pure
        returns (uint256 a0, uint256 a1, uint128 l)
    {
        return _calculateWithdrawAmounts(liq, burn, r0, r1, locked, total);
    }
}

// ─────────────────────────────────────────────────────────────
//                     UNIT TEST SUITE
// ─────────────────────────────────────────────────────────────
contract FullRangeLiquidityManagerUnitTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // mocks + system under test
    PoolManagerStub internal pm;
    PositionManagerStub internal posm;
    FRLMHarness internal frlm;

    // tokens
    MockERC20 internal t0;
    MockERC20 internal t1;

    // pool meta
    PoolKey internal key;
    PoolId internal pid;

    address internal gov; // owner / governance
    address internal user;

    function setUp() external {
        gov = address(this);
        user = vm.addr(42);

        // deploy mocks
        pm = new PoolManagerStub();
        posm = new PositionManagerStub();

        // deploy FRLM (owner = gov)
        frlm = new FRLMHarness(IPoolManager(address(pm)), ExtendedPositionManager(payable(address(posm))), gov);

        // make two ERC-20 tokens
        t0 = new MockERC20("Token0", "T0");
        t1 = new MockERC20("Token1", "T1");

        // build poolKey / id
        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 0,
            hooks: IHooks(address(0)),
            tickSpacing: 10
        });
        pid = key.toId();

        // authorise this test-contract as hook and store the key
        frlm.setAuthorizedHookAddress(address(this));
        frlm.storePoolKey(pid, key);

        // seed PoolManager.slot0 with price = 1:1 (2**96)
        pm.setSlot0(pid, 79228162514264337593543950336);
    }

    // ─── Access control tests ──────────────────────────────
    function testOnlyGovernance() external {
        // prank as a random user and expect revert
        vm.prank(user);
        vm.expectRevert();
        frlm.deposit(pid, 1e18, 1e18, 0, 0, user);
    }

    function testOnlyHook() external {
        // un-authorised caller should revert when trying to storePoolKey
        vm.prank(user);
        vm.expectRevert();
        frlm.storePoolKey(pid, key);
    }

    // ─── Internal math: first deposit path ─────────────────
    function testHandleFirstDepositCalculations() external {
        uint160 sqrtP = 79228162514264337593543950336; // 1:1
        uint256 amt = 10 ether;

        FRLMHarness.DepositCalculationResult memory r = frlm.exposedHandleFirstDeposit(sqrtP, 10, amt, amt);

        assertGt(r.v4LiquidityForCallback, 0, "liq zero");
        assertEq(r.actual0, amt, "actual0 trimmed");
        assertEq(r.actual1, amt, "actual1 trimmed");
        // sharesToAdd should equal √(a0*a1) - MIN_LOCKED_SHARES
        uint128 expectedShares = uint128(Math.sqrt(amt * amt) - 1_000);
        assertEq(r.sharesToAdd, expectedShares, "shares mismatch");
        assertEq(r.lockedAmount, 1_000, "locked shares mismatch");
    }

    // ─── Internal math: secondary deposit path ─────────────
    function testSubsequentDepositCalculation() external {
        uint160 sqrtP = 79228162514264337593543950336; // 1:1
        uint128 totalShares = 1_000_000; // pretend pool already has shares
        uint256 reserve0 = 5 ether;
        uint256 reserve1 = 5 ether;
        uint256 want0 = 1 ether;
        uint256 want1 = 1 ether;

        FRLMHarness.DepositCalculationResult memory r =
            frlm.exposedCalculateDepositShares(totalShares, sqrtP, 10, want0, want1, reserve0, reserve1);

        assertGt(r.sharesToAdd, 0, "no shares minted");
        assertEq(r.lockedAmount, 0, "should not lock on subsequent deposits");
        // resulting actual should not exceed desired
        assertLe(r.actual0, want0, "actual0 > desired");
        assertLe(r.actual1, want1, "actual1 > desired");
    }

    // ─── Withdraw math ─────────────────────────────────────
    function testWithdrawMath() external {
        uint128 totalLiq = 1_000_000;
        uint256 burn = 10_000;
        uint256 res0 = 5 ether;
        uint256 res1 = 5 ether;
        uint128 locked = 1_000;
        uint128 total = 100_000 + locked;

        (uint256 a0, uint256 a1, uint128 liq) = frlm.exposedCalcWithdraw(totalLiq, burn, res0, res1, locked, total);

        assertGt(a0, 0, "amount0 zero");
        assertGt(a1, 0, "amount1 zero");
        assertGt(liq, 0, "v4liquidity zero");
    }

    // ─── Happy-path deposit (integration-lite) ─────────────
    function testDepositEndToEnd() external {
        uint256 amt = 2 ether;

        // mint + approve tokens to governance (this contract)
        t0.mint(gov, amt);
        t1.mint(gov, amt);
        t0.approve(address(frlm), amt);
        t1.approve(address(frlm), amt);

        (uint256 shares,,) = frlm.deposit(pid, amt, amt, 0, 0, gov);

        // Verify storage updates
        uint256 tokenId = PoolTokenIdUtils.toTokenId(pid);
        (bool init, uint256 bal) = frlm.getAccountPosition(pid, gov);
        assertTrue(init, "position not initialised");
        assertEq(bal, shares, "share balance mismatch");

        // lockedShares mapping should be set
        assertEq(frlm.lockedShares(pid), 1_000, "locked shares not recorded");

        // totalShares mapping updated
        assertEq(uint256(frlm.positionTotalShares(pid)), shares + 1_000, "totalShares mismatch");
    }
}
