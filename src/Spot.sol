// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

/* ───────────────────────────────────────────────────────────
    *                     Core & Periphery
    * ─────────────────────────────────────────────────────────── */
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {CurrencyDelta} from "v4-core/src/libraries/CurrencyDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Locker} from "v4-periphery/src/libraries/Locker.sol";

/* ───────────────────────────────────────────────────────────
    *                          Project
    * ─────────────────────────────────────────────────────────── */
import {ISpot} from "./interfaces/ISpot.sol";

import {IFullRangeLiquidityManager} from "./interfaces/IFullRangeLiquidityManager.sol";
import {FullRangeLiquidityManager} from "./FullRangeLiquidityManager.sol";

import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {ITruncGeoOracleMulti} from "./interfaces/ITruncGeoOracleMulti.sol";
import {IDynamicFeeManager} from "./interfaces/IDynamicFeeManager.sol";
import {DynamicFeeManager} from "./DynamicFeeManager.sol";
import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";
import {TruncGeoOracleMulti} from "./TruncGeoOracleMulti.sol";
import {TickMoveGuard} from "./libraries/TickMoveGuard.sol";
import {Errors} from "./errors/Errors.sol";

/* ───────────────────────────────────────────────────────────
    *                    Solmate / OpenZeppelin
    * ─────────────────────────────────────────────────────────── */
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

// TODO: add reinvestment pause variable + setter function
// TODO: remove Owned & make admin Policy.owner
// TODO: Spot deposit and withdraw proxies to FRLM

/* ───────────────────────────────────────────────────────────
    *                       Contract: Spot
    * ─────────────────────────────────────────────────────────── */
contract Spot is BaseHook, ISpot, Owned {
    using PoolIdLibrary for PoolKey;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using CurrencyDelta for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using CustomRevert for bytes4;

    /* ───────────── Custom errors for gas optimization ───────────── */
    error ReentrancyLocked();
    error ZeroAddress();

    /* ───────────────────────── State ───────────────────────── */
    IPoolPolicy public immutable policyManager;
    TruncGeoOracleMulti public immutable truncGeoOracle;
    IDynamicFeeManager public immutable dynamicFeeManager;
    IFullRangeLiquidityManager public immutable liquidityManager;

    // TODO: is this needed? What to do in a state of emergency?
    mapping(PoolId => bool) public stateOfEmergency;

    // Gas-stipend for dynamic-fee-manager callback
    uint256 private constant GAS_STIPEND = 100_000;

    /* ──────────────────────── Constructor ───────────────────── */
    constructor(
        IPoolManager _manager,
        IFullRangeLiquidityManager _liquidityManager,
        IPoolPolicy _policyManager,
        TruncGeoOracleMulti _oracle,
        IDynamicFeeManager _dynamicFeeManager,
        address _initialOwner
    ) BaseHook(_manager) Owned(_initialOwner) {
        if (address(_manager) == address(0)) revert ZeroAddress();
        if (address(_liquidityManager) == address(0)) revert ZeroAddress();
        if (address(_policyManager) == address(0)) revert ZeroAddress();
        if (address(_oracle) == address(0)) revert ZeroAddress();
        if (address(_dynamicFeeManager) == address(0)) revert ZeroAddress();

        policyManager = _policyManager;
        truncGeoOracle = _oracle;
        dynamicFeeManager = _dynamicFeeManager;

        // TODO: validate _liquidityManager hook is address(this)

        // Deploy the paired FeeManager
        liquidityManager = _liquidityManager;
    }

    /* ───────────────────── Hook Permissions ─────────────────── */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /* ─────────────────── Hook: beforeSwap ───────────────────── */

    // TODO: add only position manager checks to hook callbacks

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (address(dynamicFeeManager) == address(0)) {
            revert Errors.NotInitialized("DynamicFeeManager");
        }

        // Get dynamic fee from fee manager
        (uint256 baseRaw, uint256 surgeRaw) = dynamicFeeManager.getFeeState(key.toId());
        uint24 base = uint24(baseRaw);
        uint24 surge = uint24(surgeRaw);
        uint24 fee = base + surge; // ppm (1e-6)

        // Calculate protocol fee based on policy
        PoolId poolId = key.toId();
        (uint256 protocolFeePPM,,) = policyManager.getFeeAllocations(key.toId()); // ppm
        if (protocolFeePPM == 0) {
            // No protocol fee configured, just return the swap fee
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
        }

        // Get absolute amount and determine fee currency
        uint256 absAmount;
        Currency feeCurrency;

        if (params.amountSpecified >= 0) {
            // exactIn case
            absAmount = uint256(params.amountSpecified);
            feeCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        } else {
            // exactOut case
            absAmount = uint256(-params.amountSpecified);
            feeCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        }

        // Calculate hook fee amount
        uint256 swapFeeAmount = FullMath.mulDiv(absAmount, fee, 1e6);
        uint256 hookFeeAmount = FullMath.mulDiv(swapFeeAmount, protocolFeePPM, 1e6);

        // Mint fee to FeeManager
        if (hookFeeAmount > 0) {
            poolManager.mint(address(liquidityManager), feeCurrency.toId(), hookFeeAmount);

            // Calculate amounts for fee notification
            uint256 fee0 = 0;
            uint256 fee1 = 0;

            if (feeCurrency == key.currency0) {
                fee0 = hookFeeAmount;
            } else {
                fee1 = hookFeeAmount;
            }

            // Emit event with uint128 values for backward compatibility
            emit HookFee(poolId, sender, uint128(fee0), uint128(fee1));

            // TODO: have notifyFee return whether reinvest occurred or not
            // If it occurred then emit HookFeeReinvested else emit HookFee; same behaviour in afterSwap
            // Notify FullRangeLiquidityManager with the updated interface
            liquidityManager.notifyFee(key, fee0, fee1);
        }

        // Store pre-swap tick for oracle update in afterSwap
        (, int24 curTick,,) = StateLibrary.getSlot0(poolManager, key.toId());
        assembly {
            tstore(poolId, curTick) // EIP-1153 – transient storage
        }

        // TODO: investigate manager.updateDynamicLPFee vs return value

        // TODO: fix return delta to account for hook fee
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    /* ─────────────────── Hook: afterSwap ────────────────────── */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {

        // TODO: investigate if we can charge on the input token in afterSwap
        // TODO: ideal implementation should always charge on the input token:
        // To enable this the hook fee should be charged in beforeSwap on exactIn
        // And charged in afterSwap on exactOut

        // TODO: always do reinvest in afterSwap and notifyFee if exactOut(otherwise do notifyFee if exactIn)

        // Get pre-swap tick from transient storage
        bytes32 pid = PoolId.unwrap(key.toId());
        int24 preTick;
        assembly {
            preTick := tload(pid)
        }

        // Push observation to oracle & check cap
        bool capped = truncGeoOracle.pushObservationAndCheckCap(key.toId(), preTick);

        // Notify Dynamic Fee Manager about the oracle update
        dynamicFeeManager.notifyOracleUpdate{gas: GAS_STIPEND}(key.toId(), capped);

        return (BaseHook.afterSwap.selector, 0);
    }

    /* ───────────────── afterInitialize hook ───────────────── */
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        if (sqrtPriceX96 == 0) revert Errors.InvalidPrice(sqrtPriceX96);

        // Initialize oracle if possible
        if (address(truncGeoOracle) != address(0) && address(key.hooks) == address(this)) {
            // TODO: why so many try catches? Don't we expect these calls to necessarily succeed
            try truncGeoOracle.enableOracleForPool(key) {
                emit OracleInitialized(poolId, tick, TickMoveGuard.HARD_ABS_CAP);
            } catch (bytes memory reason) {
                emit OracleInitializationFailed(poolId, reason);
            }
        }

        // Initialize policy manager
        if (address(policyManager) != address(0)) {
            try policyManager.handlePoolInitialization(poolId, key, sqrtPriceX96, tick, address(this)) {}
            catch (bytes memory reason) {
                emit PolicyInitializationFailed(poolId, string(reason));
            }
        }

        // Initialize dynamic fee manager
        if (address(dynamicFeeManager) != address(0)) {
            dynamicFeeManager.initialize(poolId, tick);
        }

        return BaseHook.afterInitialize.selector;
    }

    // TODO: remove
    function setPoolEmergencyState(PoolId poolId, bool isEmergency) external override onlyOwner {
        bool isCurrentlyInStateOfEmergency = stateOfEmergency[poolId];
        if (isCurrentlyInStateOfEmergency != isEmergency) {
            stateOfEmergency[poolId] = isEmergency;
            emit PoolEmergencyStateChanged(poolId, isEmergency);
        }
    }
}
