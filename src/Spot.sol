// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// TODO: remove
import "forge-std/console.sol";

// - - - Solmate Deps - - -

import {ERC20} from "solmate/src/tokens/ERC20.sol";

// - - - V4 Core Deps - - -

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CurrencyDelta} from "v4-core/src/libraries/CurrencyDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

// - - - V4 Periphery Deps - - -

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Locker} from "v4-periphery/src/libraries/Locker.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

// - - - Project Libraries - - -

import {TickMoveGuard} from "./libraries/TickMoveGuard.sol";

// - - - Project Interfaces - - -

import {ISpot} from "./interfaces/ISpot.sol";
import {IFullRangeLiquidityManager} from "./interfaces/IFullRangeLiquidityManager.sol";
import {ITruncGeoOracleMulti} from "./interfaces/ITruncGeoOracleMulti.sol";
import {IDynamicFeeManager} from "./interfaces/IDynamicFeeManager.sol";
import {Errors} from "./errors/Errors.sol";

// - - - Project Contracts - - -

import {DynamicFeeManager} from "./DynamicFeeManager.sol";
import {FullRangeLiquidityManager} from "./FullRangeLiquidityManager.sol";
import {PoolPolicyManager} from "./PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "./TruncGeoOracleMulti.sol";

contract Spot is BaseHook, ISpot {
    using PoolIdLibrary for PoolKey;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using CurrencyDelta for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using CustomRevert for bytes4;

    // - - - Constants - - -

    // Gas-stipend for dynamic-fee-manager callback
    uint256 private constant GAS_STIPEND = 100_000;

    // - - - State - - -

    PoolPolicyManager public immutable override policyManager;
    TruncGeoOracleMulti public immutable override truncGeoOracle;
    IDynamicFeeManager public immutable override dynamicFeeManager;
    IFullRangeLiquidityManager public immutable override liquidityManager;

    bool public override reinvestmentPaused;

    // - - - Constructor - - -

    constructor(
        IPoolManager _manager,
        IFullRangeLiquidityManager _liquidityManager,
        PoolPolicyManager _policyManager,
        TruncGeoOracleMulti _oracle,
        IDynamicFeeManager _dynamicFeeManager
    ) BaseHook(_manager) {
        if (address(_manager) == address(0)) revert Errors.ZeroAddress();
        if (address(_liquidityManager) == address(0)) revert Errors.ZeroAddress();
        if (address(_policyManager) == address(0)) revert Errors.ZeroAddress();
        if (address(_oracle) == address(0)) revert Errors.ZeroAddress();
        if (address(_dynamicFeeManager) == address(0)) revert Errors.ZeroAddress();

        if (_liquidityManager.authorizedHookAddress() != address(this)) {
            revert Errors.InvalidHookAuthorization(_liquidityManager.authorizedHookAddress(), address(this));
        }

        policyManager = _policyManager;
        truncGeoOracle = _oracle;
        dynamicFeeManager = _dynamicFeeManager;
        liquidityManager = _liquidityManager;
    }

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
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _isPolicyOwner() internal view returns (bool) {
        return msg.sender == policyManager.owner();
    }

    modifier onlyPolicyOwner() {
        if (!_isPolicyOwner()) revert Errors.UnauthorizedCaller(msg.sender);
        _;
    }

    /// @inheritdoc ISpot
    function setReinvestmentPaused(bool paused) external onlyPolicyOwner {
        reinvestmentPaused = paused;
        emit ReinvestmentPausedChanged(paused);
    }

    // Add this field to track if we've approved FRLM for each token
    mapping(address => bool) private _tokenApprovedToFRLM;

    /// @inheritdoc ISpot
    function depositToFRLM(
        PoolKey calldata key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external payable override onlyPolicyOwner returns (uint256 shares, uint256 amount0, uint256 amount1) {
        // Pass msg.sender as the payer to avoid token transfers through Spot
        uint256 unusedAmount0;
        uint256 unusedAmount1;

        (shares, amount0, amount1, unusedAmount0, unusedAmount1) = liquidityManager.deposit{value: msg.value}(
            key, amount0Desired, amount1Desired, amount0Min, amount1Min, recipient, msg.sender
        );

        return (shares, amount0, amount1);
    }

    /// @inheritdoc ISpot
    function withdrawFromFRLM(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external override onlyPolicyOwner returns (uint256 amount0, uint256 amount1) {
        // Forward the call with msg.sender as the sharesOwner
        return liquidityManager.withdraw(key, sharesToBurn, amount0Min, amount1Min, recipient, msg.sender);
    }

    // - - - Hook Callback Implementations - - -

    /// @notice called in BaseHook.beforeSwap
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // First check if a manual fee is set for this pool
        PoolId poolId = key.toId();
        (uint24 manualFee, bool hasManualFee) = policyManager.getManualFee(poolId);

        uint24 dynamicFee;

        if (hasManualFee) {
            // Use the manual fee if set
            dynamicFee = manualFee;
        } else {
            // Otherwise get dynamic fee from fee manager
            (uint256 baseRaw, uint256 surgeRaw) = dynamicFeeManager.getFeeState(poolId);
            uint24 base = uint24(baseRaw);
            uint24 surge = uint24(surgeRaw);
            dynamicFee = base + surge; // ppm (1e-6)
        }

        // Store pre-swap tick for oracle update in afterSwap
        (, int24 preSwapTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        assembly {
            tstore(poolId, dynamicFee)
            tstore(add(poolId, 1), preSwapTick) // use next slot for pre-swap tick
        }

        // Calculate protocol fee based on policy
        uint256 protocolFeePPM = policyManager.getPoolPOLShare(poolId);

        // Handle exactIn case in beforeSwap
        if (params.amountSpecified < 0 && protocolFeePPM > 0) {
            // exactIn case - we can charge the fee here
            uint256 absAmount = uint256(-params.amountSpecified);
            Currency feeCurrency = params.zeroForOne ? key.currency0 : key.currency1;

            // Calculate hook fee amount
            uint256 swapFeeAmount = FullMath.mulDiv(absAmount, dynamicFee, 1e6);
            uint256 hookFeeAmount = FullMath.mulDiv(swapFeeAmount, protocolFeePPM, 1e6);

            if (hookFeeAmount > 0) {
                // Mint fee to FRLM
                poolManager.mint(address(liquidityManager), feeCurrency.toId(), hookFeeAmount);

                // Calculate amounts for fee notification
                uint256 fee0 = params.zeroForOne ? hookFeeAmount : 0;
                uint256 fee1 = params.zeroForOne ? 0 : hookFeeAmount;

                if (reinvestmentPaused) {
                    emit HookFee(poolId, sender, uint128(fee0), uint128(fee1));
                } else {
                    emit HookFeeReinvested(poolId, sender, uint128(fee0), uint128(fee1));
                }
                liquidityManager.notifyFee(key, fee0, fee1);

                // Create BeforeSwapDelta to account for the tokens we took
                // We're taking tokens from the input, so return positive delta
                int128 deltaSpecified = int128(int256(hookFeeAmount));
                return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(deltaSpecified, 0), dynamicFee);
            }
        }

        // If we didn't charge a fee, return zero delta
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, dynamicFee);
    }

    /// @notice called in BaseHook.afterSwap
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();

        // NOTE: we do oracle updates this regardless of manual fee setting

        // Get pre-swap tick from transient storage
        int24 preSwapTick;
        assembly {
            preSwapTick := tload(add(poolId, 1))
        }

        // Push observation to oracle & check cap
        bool capped = truncGeoOracle.pushObservationAndCheckCap(poolId, preSwapTick);

        // Notify Dynamic Fee Manager about the oracle update
        dynamicFeeManager.notifyOracleUpdate{gas: GAS_STIPEND}(poolId, capped);

        // Handle exactOut case in afterSwap (params.amountSpecified > 0)
        if (params.amountSpecified > 0) {
            // Get protocol fee percentage
            uint256 protocolFeePPM = policyManager.getPoolPOLShare(poolId);

            if (protocolFeePPM > 0) {
                // For exactOut, the input token is the unspecified token
                bool zeroIsInput = params.zeroForOne;
                Currency feeCurrency = zeroIsInput ? key.currency0 : key.currency1;

                // Get the actual input amount (should be positive) from the delta
                int128 inputAmount = zeroIsInput ? delta.amount0() : delta.amount1();
                if (inputAmount > 0) revert Errors.InvalidSwapDelta(); // NOTE: invariant check

                // Get the dynamic fee(could be actual base+surge or manual)
                uint24 dynamicFee;
                assembly {
                    dynamicFee := tload(poolId)
                }

                // Calculate hook fee
                uint256 absInputAmount = uint256(uint128(-inputAmount));
                uint256 swapFeeAmount = FullMath.mulDiv(absInputAmount, dynamicFee, 1e6);
                uint256 hookFeeAmount = FullMath.mulDiv(swapFeeAmount, protocolFeePPM, 1e6);

                if (hookFeeAmount > 0) {
                    // Mint fee credit to FRLM
                    poolManager.mint(address(liquidityManager), feeCurrency.toId(), hookFeeAmount);

                    // Calculate fee amounts for notification
                    uint256 fee0 = zeroIsInput ? hookFeeAmount : 0;
                    uint256 fee1 = zeroIsInput ? 0 : hookFeeAmount;

                    // Emit appropriate event
                    if (reinvestmentPaused) {
                        emit HookFee(poolId, sender, uint128(fee0), uint128(fee1));
                    } else {
                        emit HookFeeReinvested(poolId, sender, uint128(fee0), uint128(fee1));
                    }
                    liquidityManager.notifyFee(key, fee0, fee1);

                    // Try to reinvest if not paused
                    if (!reinvestmentPaused) {
                        liquidityManager.reinvest(key);
                    }

                    // Return the fee amount we took
                    return (BaseHook.afterSwap.selector, int128(int256(hookFeeAmount)));
                }
            }
        }

        // Try to reinvest if not paused
        if (!reinvestmentPaused) {
            liquidityManager.reinvest(key);
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice called in BaseHook.afterInitialize
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        if (sqrtPriceX96 == 0) revert Errors.InvalidPrice(sqrtPriceX96);

        // Initialize oracle if possible
        if (address(truncGeoOracle) != address(0) && address(key.hooks) == address(this)) {
            truncGeoOracle.enableOracleForPool(key);
            emit OracleInitialized(poolId, tick, TickMoveGuard.HARD_ABS_CAP);
        }

        // Initialize dynamic fee manager
        if (address(dynamicFeeManager) != address(0)) {
            dynamicFeeManager.initialize(poolId, tick);
        }

        return BaseHook.afterInitialize.selector;
    }
}
