// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/*───────────────────────────────────────────────────────────────────────────
│                                 Imports                                   │
└───────────────────────────────────────────────────────────────────────────*/
import "forge-std/Test.sol";

import {PoolId, PoolIdLibrary}   from "v4-core/src/types/PoolId.sol";
import {PoolKey}                 from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta}            from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams}   from "v4-core/src/types/PoolOperation.sol";
import {SwapParams}              from "v4-core/src/types/PoolOperation.sol";
import {IPoolManager}            from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks}                   from "v4-core/src/libraries/Hooks.sol";
import {IHooks}                  from "v4-core/src/interfaces/IHooks.sol";
import {HookMiner}               from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {Spot}                    from "../../src/Spot.sol";
import {ISpot, DepositParams}    from "../../src/interfaces/ISpot.sol";
import {Errors}                  from "../../src/errors/Errors.sol";
import {IPoolPolicy}             from "../../src/interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "../../src/interfaces/IFullRangeLiquidityManager.sol";
import {TruncGeoOracleMulti}     from "../../src/TruncGeoOracleMulti.sol";
import {IDynamicFeeManager}      from "../../src/interfaces/IDynamicFeeManager.sol";

import {LM}                      from "../helpers/LM.sol";

/*───────────────────────────────────────────────────────────────────────────
│                              Tiny-Mocks                                   │
└───────────────────────────────────────────────────────────────────────────*/
contract PM {
    /* minimal bookkeeping */
    event Take(address indexed ccy, address indexed to, uint256 amt);

    function take(Currency c, address to, uint256 a) external payable {
        emit Take(Currency.unwrap(c), to, a);
    }

    /* -------- hook-validation helpers expected by BaseHook -------- */
    /// @dev BaseHook checks that `poolManager.isHook()` AND
    ///      `poolManager.validateHookAddress()` both return true.
    function isHook(address) external pure returns (bool) {
        return true;
    }

    /// @dev In production this returns a single bool; keep it that way
    function validateHookAddress(address) external pure returns (bool) {
        return true;
    }

    /* Generic fallback — return "true" (32-byte 1) for all other calls   */
    fallback() external payable {
        assembly { mstore(0, 1) return(0, 0x20) }
    }

    receive() external payable {}
}

contract OracleStub {
    function pushObservationAndCheckCap(PoolId, int24) external pure returns (bool) { return false; }
    function enableOracleForPool(PoolKey calldata) external {}
    function isOracleEnabled(PoolId) external pure returns (bool) { return false; }
    function getLatestObservation(PoolId) external pure returns (int24, uint32) { return (0,0); }
}

/* -------------------------------------------------------------------------- */
/*  tiny-policy with an injectable "governor"                                   */
/*  so the test-contract can act as governance while everyone else is a guest   */
/* -------------------------------------------------------------------------- */
contract PolicyStub {
    address public immutable governor;
    address public feeCollector = address(0xFEE5);

    constructor(address _gov) { governor = _gov; }

    /* -------- IPoolPolicy bits the hook touches ------------------------ */
    function getSoloGovernance() external view returns (address) { return governor; }
    function getFeeCollector() external view returns (address) { return feeCollector; }
    function getFeeAllocations(PoolId) external pure returns (uint256,uint256,uint256) {
        return (0,0,0);
    }
    function handlePoolInitialization(
        PoolId, PoolKey calldata, uint160, int24, address
    ) external {}
}

contract DFStub {
    function getFeeState(PoolId) external pure returns (uint256, uint256) { return (0,0); }
    function notifyOracleUpdate(PoolId, bool) external {}
    function initialize(PoolId, int24) external {}
}

/* helper for re-entrancy test */
contract Reentrant {
    Spot immutable s;

    constructor(Spot spot_) {
        s = spot_;
    }

    function triggerReentrancy(DepositParams calldata p) external payable {
        s.deposit{value: msg.value}(p);
    }

    receive() external payable {
        // Try to reenter during the first deposit
        DepositParams memory p = DepositParams({
            poolId: PoolId.wrap(bytes32(uint256(1))),
            amount0Desired: 0,
            amount1Desired: 0,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1
        });
        /* forward whatever ETH we just received so the inner call
           behaves exactly like the outer one */
        s.deposit{value: msg.value}(p);
    }
}

/*───────────────────────────────────────────────────────────────────────────
│                                 Tests                                     │
└───────────────────────────────────────────────────────────────────────────*/
contract SpotUnitTest is Test {
    using PoolIdLibrary for bytes32;
    using CurrencyLibrary for address;

    /* ---------------------------------------------------------------- */
    /*  housekeeping helpers                                            */
    /* ---------------------------------------------------------------- */
    /// Accept any ETH the LM mock (or other contracts) might send us.
    receive() external payable {}

    /* test constants */
    bytes32  constant PID_BYTES = bytes32(uint256(1));
    PoolId   constant PID       = PoolId.wrap(PID_BYTES);
    address  constant CURRENCY  = address(0xA11CE);
    uint24   constant TICK_SP   = 60;

    /* system under test */
    Spot  spot;
    PM    pm;
    LM    lm;
    OracleStub oracle;
    PolicyStub policy;
    DFStub dfm;

    function setUp() public {
        pm     = new PM();
        lm     = new LM();
        /* The LM mock tries to reimburse the caller with 1 wei inside
           `deposit()`.  Without an ETH balance that call under-flows and
           the whole deposit reverts.  Give it some spare change up-front. */
        vm.deal(address(lm), 1 ether);

        oracle = new OracleStub();
        policy = new PolicyStub(address(this));
        dfm    = new DFStub();

        /* --------------------------------------------------------------
         * 1. figure out the required flag-bitmap from Spot's permissions
         * 2. use HookMiner to find a CREATE2-salt that yields an address
         *    with those flags embedded (✓ BaseHook constructor check)
         * ----------------------------------------------------------- */
        /** we only need 4 flags – keep the bitmap minimal */
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG
          | Hooks.BEFORE_SWAP_FLAG
          | Hooks.AFTER_SWAP_FLAG
          | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (address expectedAddr, bytes32 salt) = HookMiner.find(
            address(this),                       // deployer
            flags,
            type(Spot).creationCode,
            abi.encode(
                IPoolManager(address(pm)),
                IPoolPolicy(address(policy)),
                IFullRangeLiquidityManager(address(lm)),
                TruncGeoOracleMulti(address(oracle)),
                IDynamicFeeManager(address(dfm)),
                address(this)
            )
        );

        /* deploy Spot at the pre-computed address */
        spot = new Spot{salt: salt}(
            IPoolManager(address(pm)),
            IPoolPolicy(address(policy)),
            IFullRangeLiquidityManager(address(lm)),
            TruncGeoOracleMulti(address(oracle)),
            IDynamicFeeManager(address(dfm)),
            address(this)
        );

        require(address(spot) == expectedAddr, "hook addr mismatch");

        /* ---------- prime  poolData & poolKeys so that `deposit()`
         * ---------- passes all its guards (→ tests re-entrancy)      */

        // ---- actual storage layout ----------------------------------
        //  BaseHook → slots 0-3, Owned.owner → slot-4.
        //  Spot's own state therefore starts at slot-5 **in byte-code**, but
        //  the compiler packs the constant pool before that first free slot,
        //  leaving our two mappings at **slot-1** (poolData) and **slot-2**
        //  (poolKeys).  Confirm with `forge inspect Spot storageLayout`.

        // poolData.initialized = true
        bytes32 dataSlot = keccak256(abi.encode(PID_BYTES, uint256(1))); // mapping @ slot-1
        vm.store(address(spot), dataSlot, bytes32(uint256(1)));

        // poolKeys[PID] = dummy full-range key
        bytes32 keySlot = keccak256(abi.encode(PID_BYTES, uint256(2))); // mapping @ slot-2

        // Store the PoolKey struct
        // First word: currency0 and currency1 (packed addresses)
        vm.store(
            address(spot),
            keySlot,
            bytes32(uint256(uint160(address(0))) | (uint256(uint160(address(0xBEEF))) << 160))
        );
        // Second word: fee and tickSpacing
        vm.store(
            address(spot),
            bytes32(uint256(keySlot) + 1),
            bytes32(uint256(uint24(0)) | (uint256(uint24(1)) << 24))
        );
        // Third word: hooks address
        vm.store(
            address(spot),
            bytes32(uint256(keySlot) + 2),
            bytes32(uint256(uint160(address(spot))))
        );

        // Verify initialization worked
        require(spot.isPoolInitialized(PID), "Pool not initialized after setup");
    }

    /*─────────────────── constructor safety ───────────────────*/
    function testConstructorRevertsOnZeroManager() public {
        // BaseHook reverts before Spot's own zero-check runs – any revert is fine.
        vm.expectRevert();
        new Spot(
            IPoolManager(address(0)),
            IPoolPolicy(address(policy)),
            IFullRangeLiquidityManager(address(lm)),
            TruncGeoOracleMulti(address(oracle)),
            IDynamicFeeManager(address(dfm)),
            address(this)
        );
    }

    /*────────────────── hook-permissions sanity ───────────────*/
    function testHookPermissionsBitmap() public {
        Hooks.Permissions memory p = spot.getHookPermissions();
        assertTrue(p.afterInitialize && p.afterSwap && p.beforeSwap);
        assertFalse(p.beforeAddLiquidity); // one negative check
    }

    /*────────────────── re-entrancy guard ─────────────────────*/
    function testReentrancyGuard() public {
        Reentrant r = new Reentrant(spot);

        // First deposit should succeed
        DepositParams memory p = DepositParams({
            poolId: PID,
            amount0Desired: 0,
            amount1Desired: 0,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1
        });

        // First call should succeed
        spot.deposit(p);

        /* The inner (re-entrant) call must hit the nonReentrant guard
           and revert with our custom selector.                          */
        vm.expectRevert(Spot.ReentrancyLocked.selector);
        r.triggerReentrancy{value: 1 ether}(p);

        // Verify only one deposit succeeded
        assertEq(lm.deposits(), 1);
    }

    /*───────────────── reinvest global pause ──────────────────*/
    function testPauseToggle() public {
        vm.expectEmit(false,false,false,true);
        emit Spot.ReinvestmentPauseToggled(true);
        spot.setReinvestmentPaused(true);
        assertTrue(spot.reinvestmentPaused());

        vm.expectEmit(false,false,false,true);
        emit Spot.ReinvestmentPauseToggled(false);
        spot.setReinvestmentPaused(false);
        assertFalse(spot.reinvestmentPaused());
    }

    /*───────────── governance-only setter check ───────────────*/
    function testOnlyGovernance() public {
        vm.prank(address(0xdEaD));
        vm.expectRevert();  // any revert – exact selector is implementation-detail
        spot.setReinvestmentPaused(true);
    }

    /*────────────────── reinvestCfg storage ───────────────────*/
    function testSetReinvestConfigStores() public {
        spot.setPoolEmergencyState(PID, false); // caller = governance → OK now
        spot.setReinvestConfig(PID, 1,2,3);

        (uint256 min0,uint256 min1,uint64 last,uint64 cd) =
            spot.reinvestCfg(PID_BYTES);
        assertEq(min0, 1);
        assertEq(min1, 2);
        assertEq(cd  , 3);
        assertEq(last, 0);
    }

    /*────────────── claimPendingFees branches ─────────────────*/
    function testClaimPendingFeesWithdrawPath() public {
        // Set reinvestment to paused so fees can be claimed
        spot.setReinvestmentPaused(true);

        // Get the fee collector address
        address feeCollector = policy.feeCollector();

        // Expect the fee withdrawal event
        vm.expectEmit(true, false, false, true);
        emit Spot.HookFeeWithdrawn(PID_BYTES, feeCollector, 0, 0);

        // Try to claim fees
        spot.claimPendingFees(PID);
    }
}