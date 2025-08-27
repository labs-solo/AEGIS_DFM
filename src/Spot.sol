// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// - - - Solmate Deps - - -

import {ERC20} from "solmate/src/tokens/ERC20.sol";

// - - - V4 Core Deps - - -

import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
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
import {Math} from "./libraries/Math.sol";
import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";

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
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
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
        (shares, amount0, amount1,,) = liquidityManager.deposit{value: msg.value}(
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
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
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

        // Record observation with the pre-swap tick (no capping applied yet)
        try truncGeoOracle.recordObservation(poolId, preSwapTick) {
            // Observation recorded successfully
        } catch Error(string memory reason) {
            emit OracleUpdateFailed(poolId, reason);
        } catch (bytes memory lowLevelData) {
            // Low-level oracle failure
            emit OracleUpdateFailed(poolId, "LLOF");
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
                return (
                    BaseHook.beforeSwap.selector,
                    toBeforeSwapDelta(deltaSpecified, 0),
                    Math.setDynamicFeeOverride(dynamicFee)
                );
            }
        }

        // If we didn't charge a fee, return zero delta
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, Math.setDynamicFeeOverride(dynamicFee));
    }

    /// @notice called in BaseHook.afterSwap
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal virtual override returns (bytes4, int128) {
        PoolId poolId = key.toId();

        // NOTE: we do oracle updates this regardless of manual fee setting

        // Get pre-swap tick from transient storage
        int24 preSwapTick;
        assembly {
            preSwapTick := tload(add(poolId, 1))
        }

        // Get current tick after the swap
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Check if tick movement exceeded the cap based on perSwap vs perBlock setting
        bool tickWasCapped;
        bool perSwapMode = policyManager.getPerSwapMode(poolId);
        uint24 maxTicks = truncGeoOracle.maxTicksPerBlock(poolId);
        
        if (perSwapMode) {
            // perSwap mode: compare tick movement within this single swap
            int24 tickMovement = currentTick - preSwapTick;
            tickWasCapped = TruncatedOracle.abs(tickMovement) > maxTicks;
        } else {
            // perBlock mode: compare total tick movement within the current block
            // Get the block initial tick from the recorded observation
            int24 blockInitialTick = preSwapTick; // Default to pre-swap tick
            
            // Access the observation directly from the public mapping
            // Get the current index from the oracle state
            (uint16 index, uint16 cardinality, uint16 cardinalityNext) = truncGeoOracle.states(poolId);
            if (cardinality > 0) {
                // Access the observation at the current index
                (, int24 prevTick,,,) = truncGeoOracle.observations(poolId, index);
                blockInitialTick = prevTick;
            }
            
            // Compare total block movement
            int24 totalBlockMovement = currentTick - blockInitialTick;
            tickWasCapped = TruncatedOracle.abs(totalBlockMovement) > maxTicks;
        }

        // Update cap frequency in the oracle

        if(!truncGeoOracle.autoTunePaused(poolId)) {
            try truncGeoOracle.updateCapFrequency(poolId, tickWasCapped) {
                // Cap frequency updated successfully
            } catch Error(string memory reason) {
                emit OracleUpdateFailed(poolId, reason);
            } catch (bytes memory lowLevelData) {
                // Low-level oracle failure
                emit OracleUpdateFailed(poolId, "LLOF");
            }
        }
        // Notify Dynamic Fee Manager about the oracle update (with error handling)
        try dynamicFeeManager.notifyOracleUpdate(poolId, tickWasCapped) {
            // Oracle update notification succeeded
        } catch Error(string memory reason) {
            emit FeeManagerNotificationFailed(poolId, reason);
        } catch (bytes memory lowLevelData) {
            // Low-level fee manager failure
            emit FeeManagerNotificationFailed(poolId, "LLFM");
        }

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

                    // Try to reinvest if not paused (with error handling)
                    _tryReinvest(key);

                    // Return the fee amount we took
                    return (BaseHook.afterSwap.selector, int128(int256(hookFeeAmount)));
                }
            }
        }

        // Try to reinvest if not paused (with error handling)
        _tryReinvest(key);

        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice called in BaseHook.afterInitialize
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal virtual override returns (bytes4) {
        PoolId poolId = key.toId();

        if (!LPFeeLibrary.isDynamicFee(key.fee)) {
            // Only allow dynamic fee pools to be created
            revert Errors.InvalidFee();
        }


        try policyManager.initialize(key) {
            // Base fee bounds initialized successfully
        } catch Error(string memory reason) {
            // Log the error but don't revert the pool initialization
            emit PolicyInitializationFailed(poolId, reason);
        } catch (bytes memory lowLevelData) {
            // Low-level failure
            emit PolicyInitializationFailed(poolId, "LLOF");
        }

        truncGeoOracle.initializeOracleForPool(key, tick);
        dynamicFeeManager.initialize(poolId, tick);

        return BaseHook.afterInitialize.selector;
    }

    /// @notice called in BaseHook.beforeAddLiquidity
    /// @dev Records oracle observation to ensure accuracy in secondsPerLiquidityCumulativeX128 accumulator
    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal virtual override returns (bytes4) {
        PoolId poolId = key.toId();

        // Get current tick for oracle update
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Record observation with the current tick to ensure accurate secondsPerLiquidityCumulativeX128
        try truncGeoOracle.recordObservation(poolId, currentTick) {
            // Observation recorded successfully
        } catch Error(string memory reason) {
            emit OracleUpdateFailed(poolId, reason);
        } catch (bytes memory lowLevelData) {
            // Low-level oracle failure
            emit OracleUpdateFailed(poolId, "LLOF");
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @notice called in BaseHook.beforeRemoveLiquidity
    /// @dev Records oracle observation to ensure accuracy in secondsPerLiquidityCumulativeX128 accumulator
    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal virtual override returns (bytes4) {
        PoolId poolId = key.toId();

        // Get current tick for oracle update
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Record observation with the current tick to ensure accurate secondsPerLiquidityCumulativeX128
        try truncGeoOracle.recordObservation(poolId, currentTick) {
            // Observation recorded successfully
        } catch Error(string memory reason) {
            emit OracleUpdateFailed(poolId, reason);
        } catch (bytes memory lowLevelData) {
            // Low-level oracle failure
            emit OracleUpdateFailed(poolId, "LLOF");
        }

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // - - - internal helpers - - -

    /// @notice Private function to handle reinvestment with error handling
    /// @param key The pool key for reinvestment
    /// @dev Uses try-catch to prevent reinvestment failures from blocking swaps
    function _tryReinvest(PoolKey calldata key) internal virtual {
        if (!reinvestmentPaused) {
            try liquidityManager.reinvest(key) returns (bool success) {
                // Reinvestment attempted, success status is handled by the reinvest function
                // No additional action needed here
            } catch Error(string memory reason) {
                // Log the error but don't revert the swap
                emit ReinvestmentFailed(key.toId(), reason);
            } catch (bytes memory lowLevelData) {
                // Handle low-level failures (e.g., out of gas, invalid data)
                // Low-level reinvestment failure
                emit ReinvestmentFailed(key.toId(), "LLRF");
            }
        }
    }
}
