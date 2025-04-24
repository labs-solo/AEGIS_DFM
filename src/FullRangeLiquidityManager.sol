// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {MathUtils} from "./libraries/MathUtils.sol";
import {Errors} from "./errors/Errors.sol";
import {FullRangePositions} from "./token/FullRangePositions.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {PoolTokenIdUtils} from "./utils/PoolTokenIdUtils.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "./interfaces/IFullRangeLiquidityManager.sol";
import {FullRangeUtils} from "./utils/FullRangeUtils.sol";
import {SettlementUtils} from "./utils/SettlementUtils.sol";
import {CurrencySettlerExtension} from "./utils/CurrencySettlerExtension.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityMath} from "v4-core/libraries/LiquidityMath.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TransferUtils} from "./utils/TransferUtils.sol";
import {PrecisionConstants} from "./libraries/PrecisionConstants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

using SafeCast for uint256;
using SafeCast for int256;

/**
 * @title FullRangeLiquidityManager
 * @notice Manages full-range liquidity positions across multiple pools
 * @dev This contract handles deposit, withdrawal, and rebalancing
 */
contract FullRangeLiquidityManager is Owned, ReentrancyGuard, IFullRangeLiquidityManager {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Struct for deposit calculation results
    struct DepositCalculationResult {
        uint256 actual0;
        uint256 actual1;
        uint128 sharesToAdd; // V2-based shares for ERC6909
        uint128 lockedAmount; // V2-based locked amount (MIN_LIQUIDITY)
        uint128 v4LiquidityForCallback; // V4 liquidity for PoolManager interaction
    }

    /**
     * @notice Parameters for withdrawing liquidity from a pool
     * @param poolId The pool ID to withdraw from
     * @param shares The amount of LP shares to burn
     * @param amount0Min The minimum amount of token0 to receive
     * @param amount1Min The minimum amount of token1 to receive
     * @param deadline The deadline by which the transaction must be executed
     */
    struct WithdrawParams {
        PoolId poolId;
        uint256 shares;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @dev The Uniswap V4 PoolManager reference
    IPoolManager public immutable manager;

    /// @dev ERC6909Claims token for position tokenization
    FullRangePositions public immutable positions;

    /// @dev Total ERC-6909 shares issued for *our* full-range position
    mapping(PoolId => uint128) public positionTotalShares;

    /// @dev Pool keys for lookups
    mapping(PoolId => PoolKey) private _poolKeys;

    /// @dev Maximum reserve cap to prevent unbounded growth
    uint256 public constant MAX_RESERVE = type(uint128).max;

    /// @dev Address authorized to store pool keys (typically the associated hook contract)
    /// Set by the owner.
    address public authorizedHookAddress;

    // Emergency controls
    bool public emergencyWithdrawalsEnabled = false;
    mapping(PoolId => bool) public poolEmergencyState;
    address public emergencyAdmin;

    // ────────────────────────── CONSTANTS ──────────────────────────
    // Legacy V2/V3 analogue – still used to compute the very first mint
    uint128 private constant MIN_LIQUIDITY          = 1_000;
    // Permanently locked seed supply (identical to UNIv2's MIN_LIQUIDITY)
    uint128 private constant MIN_LOCKED_SHARES      = 1_000;
    // V4 liquidity that must always remain in the position (for pool dust-lock checks)
    uint128 private constant MIN_LOCKED_LIQUIDITY   = 1_000;

    // Permanently-locked ERC-6909 shares (min-liquidity analogue)
    mapping(PoolId => uint128) public lockedShares;

    // Constants
    uint256 private constant MIN_VIABLE_RESERVE = 100;
    uint256 private constant PERCENTAGE_PRECISION = 1_000_000; // 10^6 precision for percentage calculations

    // Events for pool management
    event PoolKeyStored(PoolId indexed poolId, PoolKey key);
    event AuthorizedHookAddressSet(address indexed hookAddress);
    event MinimumSharesLocked(PoolId indexed poolId, uint128 amount);
    event LiquidityAdded(
        PoolId indexed poolId,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1,
        uint128 oldTotalShares,
        uint128 mintedShares,
        uint256 timestamp
    );
    event LiquidityRemoved(
        PoolId indexed poolId,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1,
        uint128 oldTotalShares,
        uint128 burnedShares,
        uint256 timestamp
    );
    event PoolStateUpdated(PoolId indexed poolId, uint128 newTotalShares, uint8 opType);
    event EmergencyWithdrawalCompleted(
        PoolId indexed poolId, address indexed user, uint256 amount0, uint256 amount1, uint256 shares
    );
    event EmergencyStateActivated(PoolId indexed poolId, address indexed admin, string reason);
    event EmergencyStateDeactivated(PoolId indexed poolId, address indexed admin);
    event GlobalEmergencyStateChanged(bool enabled, address indexed admin);
    event TokensBorrowed(
        PoolId indexed poolId, address indexed recipient, uint256 amount0, uint256 amount1, uint256 shares
    );
    event ProtocolFeesReinvested(PoolId indexed poolId, address indexed lm, uint256 amount0, uint256 amount1);
    event Reinvested(PoolId indexed poolId, uint128 liquidityMinted, uint256 amount0, uint256 amount1);

    // Storage slot constants for V4 state access
    bytes32 private constant POOLS_SLOT = bytes32(uint256(6));
    uint256 private constant POSITIONS_OFFSET = 6;

    /// @notice Operation selector sent to the hook/PoolManager via `unlock`
    enum CallbackType {
        DEPOSIT,
        WITHDRAW,
        BORROW,
        REINVEST_PROTOCOL_FEES
    }

    /// @notice Encoded in `unlock` calldata so Spot ↔︎ LM stay in sync
    struct CallbackData {
        PoolId poolId;
        CallbackType callbackType;
        uint128 shares; // v4‑liquidity to add/remove
        uint128 oldTotalShares; // bookkeeping
        uint256 amount0;
        uint256 amount1;
        address recipient; // where token balances finally go
    }

    /**
     * @notice Constructor
     * @param _manager The Uniswap V4 pool manager
     * @param _owner The owner of the contract
     */
    constructor(IPoolManager _manager, address _owner) Owned(_owner) {
        manager = _manager;

        // Deploy ERC-6909 wrapper once; supply is managed here
        positions = new FullRangePositions("FullRange Position", "FRP", address(this));
    }

    /**
     * @notice Sets the authorized hook address (Spot contract)
     * @dev Can only be set once by the owner.
     * @param _hookAddress The address of the Spot hook contract.
     */
    function setAuthorizedHookAddress(address _hookAddress) external onlyOwner {
        // Ensure it can only be set once
        require(authorizedHookAddress == address(0), "Hook address already set");
        require(_hookAddress != address(0), "Invalid address");
        authorizedHookAddress = _hookAddress;
        emit AuthorizedHookAddressSet(_hookAddress);
    }

    /**
     * @notice Access control modifier for emergency admin
     */
    modifier onlyEmergencyAdmin() {
        if (msg.sender != emergencyAdmin && msg.sender != owner) {
            revert Errors.AccessOnlyEmergencyAdmin(msg.sender);
        }
        _;
    }

    /**
     * @notice Access control modifier to ensure only FullRange contract can call this function
     */
    modifier onlyFullRange() {
        if (authorizedHookAddress == address(0)) revert Errors.NotInitialized("AuthorizedHookAddress");
        if (msg.sender != authorizedHookAddress) {
            revert Errors.AccessNotAuthorized(msg.sender);
        }
        _;
    }

    /**
     * @notice Allows the contract to receive ETH
     */
    receive() external payable {}

    // === POOL MANAGEMENT FUNCTIONS ===

    /**
     * @notice Stores the PoolKey associated with a PoolId.
     * @dev Called by the authorized hook during its afterInitialize phase.
     * @param poolId The Pool ID.
     * @param key The PoolKey corresponding to the Pool ID.
     */
    function storePoolKey(PoolId poolId, PoolKey calldata key) external override onlyFullRange {
        // Prevent overwriting existing keys? Optional check.
        // if (_poolKeys[poolId].tickSpacing != 0) revert PoolKeyAlreadyStored(poolId);
        _poolKeys[poolId] = key;
        emit PoolKeyStored(poolId, key);
    }

    /**
     * @notice Get the PoolKey for a given PoolId (implements interface)
     * @param poolId The Pool ID to look up
     * @return Pool key associated with this Pool ID
     */
    function poolKeys(PoolId poolId) external view override returns (PoolKey memory) {
        PoolKey memory key = _poolKeys[poolId];
        if (key.tickSpacing == 0) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
        return key;
    }

    /**
     * @notice Get the tickSpacing for a given PoolId
     * @param poolId The Pool ID to look up
     * @return The tickSpacing associated with this Pool ID
     */
    function getPoolTickSpacing(PoolId poolId) external view returns (int24) {
        return _poolKeys[poolId].tickSpacing;
    }

    /**
     * @notice Get the position token contract
     * @return The position token contract
     */
    function getPositionsContract() external view returns (FullRangePositions) {
        return positions;
    }

    // === LIQUIDITY MANAGEMENT FUNCTIONS ===

    /**
     * @notice Deposit tokens into a pool with native ETH support
     * @dev Uses PoolId to manage state for the correct pool.
     * @inheritdoc IFullRangeLiquidityManager
     */
    function deposit(
        PoolId poolId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external payable override nonReentrant returns (uint256 usableShares, uint256 amount0, uint256 amount1) {
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
        if (amount0Desired == 0 && amount1Desired == 0) revert Errors.ZeroAmount(); // Must desire some amount

        PoolKey memory key = _poolKeys[poolId];
        (, uint160 sqrtPriceX96,) = getPositionData(poolId);
        uint128 totalSharesInternal = positionTotalShares[poolId];

        if (sqrtPriceX96 == 0 && totalSharesInternal == 0) {
            bytes32 stateSlot = _getPoolStateSlot(poolId);
            try manager.extsload(stateSlot) returns (bytes32 slot0Data) {
                sqrtPriceX96 = uint160(uint256(slot0Data));
            } catch {
                revert Errors.FailedToReadPoolData(poolId);
            }
            if (sqrtPriceX96 == 0) revert Errors.ValidationInvalidInput("Pool price is zero");
        }

        bool hasToken0Native = key.currency0.isAddressZero();
        bool hasToken1Native = key.currency1.isAddressZero();

        // ——— 3) single‐read slot0 and reuse it for getPoolReserves
        (uint256 reserve0, uint256 reserve1) = getPoolReservesWithPrice(poolId, sqrtPriceX96);

        // Calculate deposit shares
        DepositCalculationResult memory calcResult = DepositCalculationResult({
            actual0: 0,
            actual1: 0,
            sharesToAdd: 0,
            lockedAmount: 0,
            v4LiquidityForCallback: 0
        });
        _calculateDepositSharesInternal(
            totalSharesInternal,
            sqrtPriceX96,
            key.tickSpacing,
            amount0Desired,
            amount1Desired,
            reserve0,
            reserve1,
            calcResult
        );
        amount0 = calcResult.actual0;
        amount1 = calcResult.actual1;
        uint128 sharesToAdd = calcResult.sharesToAdd;
        uint128 v4LiquidityForPM = calcResult.v4LiquidityForCallback;

        // Checks after calculation
        if (amount0 < amount0Min || amount1 < amount1Min) {
            revert Errors.SlippageExceeded(
                (amount0 < amount0Min) ? amount0Min : amount1Min, (amount0 < amount0Min) ? amount0 : amount1
            );
        }

        // ETH Handling
        uint256 ethNeeded = (hasToken0Native ? amount0 : 0) + (hasToken1Native ? amount1 : 0);
        if (msg.value < ethNeeded) {
            revert Errors.InsufficientETH(ethNeeded, msg.value);
        }

        uint128 oldTotalSharesInternal = totalSharesInternal;
        uint128 newTotalSharesInternal = oldTotalSharesInternal + v4LiquidityForPM + uint128(calcResult.lockedAmount);
        positionTotalShares[poolId] = newTotalSharesInternal;

        // ─── lock the first MIN_LOCKED_SHARES by minting to address(0) ───
        if (calcResult.lockedAmount > 0 && lockedShares[poolId] == 0) {
            uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
            lockedShares[poolId] = uint128(calcResult.lockedAmount);
            positions.mint(address(0), tokenId, calcResult.lockedAmount); // irrevocable
            emit MinimumSharesLocked(poolId, uint128(calcResult.lockedAmount));
        }

        usableShares = uint256(sharesToAdd);
        if (usableShares > 0) {
            uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
            positions.mint(recipient, tokenId, usableShares);
        }

        // Transfer non-native tokens from msg.sender
        if (amount0 > 0 && !hasToken0Native) {
            SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(key.currency0)), msg.sender, address(this), amount0);
        }
        if (amount1 > 0 && !hasToken1Native) {
            SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(key.currency1)), msg.sender, address(this), amount1);
        }

        // Prepare callback data - use v4LiquidityForPM for actual pool liquidity modification
        CallbackData memory callbackData = CallbackData({
            poolId: poolId,
            callbackType: CallbackType.DEPOSIT,
            shares: v4LiquidityForPM,  // Use V4 liquidity amount for modifyLiquidity
            oldTotalShares: oldTotalSharesInternal,
            amount0: amount0,
            amount1: amount1,
            recipient: address(this)
        });

        // Unlock calls modifyLiquidity via hook and transfers tokens to PoolManager
        manager.unlock(abi.encode(callbackData));

        // Refund excess ETH
        if (msg.value > ethNeeded) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - ethNeeded);
        }

        emit LiquidityAdded(
            poolId,
            recipient,
            amount0,
            amount1,
            oldTotalSharesInternal,
            uint128(usableShares),
            block.timestamp
        );
        emit PoolStateUpdated(poolId, newTotalSharesInternal, uint8(CallbackType.DEPOSIT));

        return (usableShares, amount0, amount1);
    }

    /**
     * @notice Calculates deposit shares based on desired amounts and pool state, filling the provided result struct.
     * @param totalSharesInternal Current total shares tracked internally.
     * @param sqrtPriceX96 Current sqrt price of the pool.
     * @param tickSpacing Tick spacing.
     * @param amount0Desired Desired amount of token0.
     * @param amount1Desired Desired amount of token1.
     * @param reserve0 Current token0 reserves (read from pool state).
     * @param reserve1 Current token1 reserves (read from pool state).
     * @param result The struct to be filled with calculation results.
     */
    function _calculateDepositSharesInternal(
        uint128 totalSharesInternal,
        uint160 sqrtPriceX96,
        int24 tickSpacing,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 reserve0,
        uint256 reserve1,
        DepositCalculationResult memory result
    ) internal pure {
        if (totalSharesInternal == 0) {
            // First deposit logic moved to helper
            _handleFirstDepositInternal(sqrtPriceX96, tickSpacing, amount0Desired, amount1Desired, result);
        } else {
            // Subsequent deposits - calculate liquidity (shares) based on one amount and reserves ratio
            // if (reserve0 == 0 || reserve1 == 0) revert Errors.ValidationInvalidInput("Reserves are zero"); // Commented out - Reserves can be zero initially

            uint256 shares0 = MathUtils.calculateProportional(amount0Desired, totalSharesInternal, reserve0, true);
            uint256 shares1 = MathUtils.calculateProportional(amount1Desired, totalSharesInternal, reserve1, true);
            uint256 optimalShares = shares0 < shares1 ? shares0 : shares1;
            uint128 shares = optimalShares.toUint128(); // Assign to 'shares'
            if (shares == 0) revert Errors.ZeroAmount();

            // Calculate actual amounts based on the determined shares and reserves ratio
            uint256 actual0 = MathUtils.calculateProportional(reserve0, uint256(shares), totalSharesInternal, true);
            uint256 actual1 = MathUtils.calculateProportional(reserve1, uint256(shares), totalSharesInternal, true);

            uint128 lockedSharesAmount = 0; // No locking for subsequent deposits

            // Cap amounts at MAX_RESERVE if needed
            if (actual0 > MAX_RESERVE) actual0 = MAX_RESERVE;
            if (actual1 > MAX_RESERVE) actual1 = MAX_RESERVE;

            // Assign to struct fields
            result.actual0 = actual0;
            result.actual1 = actual1;
            result.sharesToAdd = shares; // Use the calculated 'shares' variable
            result.lockedAmount = lockedSharesAmount;
            result.v4LiquidityForCallback = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(tickSpacing)),
                TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(tickSpacing)),
                actual0,
                actual1
            );
        }
    }

    /**
     * @dev Helper function to handle the logic for the first deposit into the pool.
     * @param sqrtPriceX96 Current sqrt price of the pool.
     * @param tickSpacing Tick spacing of the pool.
     * @param amount0Desired Desired amount of token0.
     * @param amount1Desired Desired amount of token1.
     * @param result The struct to be filled with calculation results.
     */
    function _handleFirstDepositInternal(
        uint160 sqrtPriceX96,
        int24 tickSpacing,
        uint256 amount0Desired,
        uint256 amount1Desired,
        DepositCalculationResult memory result
    ) internal pure {
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        if (amount0Desired == 0) {
            revert("DEBUG: amount0Desired is zero");
        }
        if (amount1Desired == 0) {
            revert("DEBUG: amount1Desired is zero");
        }
        if (sqrtPriceX96 == 0) revert Errors.ValidationInvalidInput("Initial price is zero");

        // Calculate liquidity using BOTH desired amounts
        uint128 v4LiquidityForCallback = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0Desired, amount1Desired
        );
        if (v4LiquidityForCallback == 0) revert Errors.ZeroAmount();

        // Calculate actual amounts needed for this liquidity
        uint256 actual0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtRatioBX96, v4LiquidityForCallback, true);
        uint256 actual1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, v4LiquidityForCallback, true);

        // Cap actual amounts at desired amounts (safety check)
        actual0 = actual0 > amount0Desired ? amount0Desired : actual0;
        actual1 = actual1 > amount1Desired ? amount1Desired : actual1;

        // V2 Share Calculation
        uint128 minLiq128 = MIN_LIQUIDITY;
        uint256 totalV2Shares = MathUtils.sqrt(actual0 * actual1);

        if (totalV2Shares < minLiq128) {
            revert Errors.InitialDepositTooSmall(minLiq128, totalV2Shares.toUint128());
        }

        uint256 usableV2Shares = totalV2Shares - minLiq128;
        if (usableV2Shares == 0) {
            revert Errors.InitialDepositTooSmall(minLiq128, totalV2Shares.toUint128());
        }

        // Populate Result Struct
        result.actual0 = actual0;
        result.actual1 = actual1;
        result.sharesToAdd = usableV2Shares.toUint128();
        result.lockedAmount = minLiq128;
        result.v4LiquidityForCallback = v4LiquidityForCallback;
    }

    /**
     * @notice Withdraw liquidity from a pool
     * @dev Uses PoolId to manage state for the correct pool.
     * @inheritdoc IFullRangeLiquidityManager
     */
    function withdraw(PoolId poolId, uint256 sharesToBurn, uint256 amount0Min, uint256 amount1Min, address recipient)
        external
        override
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
        if (sharesToBurn == 0) revert Errors.ZeroAmount();

        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        uint256 userShareBalance = positions.balanceOf(msg.sender, tokenId);
        if (sharesToBurn > userShareBalance) {
            revert Errors.InsufficientShares(sharesToBurn, userShareBalance);
        }

        uint128 totalShares = positionTotalShares[poolId];
        if (totalShares == 0) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));

        uint128 minLocked = lockedShares[poolId];
        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId);

        // declare the variable that will receive the 3rd tuple element
        uint128 v4LiquidityToWithdraw;
        (amount0, amount1, v4LiquidityToWithdraw) = _calculateWithdrawAmounts(
            totalShares,
            sharesToBurn,
            reserve0,
            reserve1,
            minLocked,
            totalShares
        );

        if (amount0 < amount0Min || amount1 < amount1Min) {
            revert Errors.SlippageExceeded(
                (amount0 < amount0Min) ? amount0Min : amount1Min,
                (amount0 < amount0Min) ? amount0 : amount1
            );
        }

        PoolKey memory key = _poolKeys[poolId];

        uint128 oldTotalShares = totalShares;
        uint128 newTotalShares = oldTotalShares - sharesToBurn.toUint128();
        positionTotalShares[poolId] = newTotalShares;

        positions.burn(msg.sender, tokenId, sharesToBurn);

        CallbackData memory callbackData = CallbackData({
            poolId: poolId,
            callbackType: CallbackType.WITHDRAW,
            shares: v4LiquidityToWithdraw,
            oldTotalShares: oldTotalShares,
            amount0: amount0,
            amount1: amount1,
            recipient: address(this)
        });

        // Unlock calls modifyLiquidity via hook and transfers tokens from PoolManager
        manager.unlock(abi.encode(callbackData));

        // Transfer withdrawn tokens to the recipient
        if (amount0 > 0) {
            CurrencyLibrary.transfer(key.currency0, recipient, amount0);
        }
        if (amount1 > 0) {
            CurrencyLibrary.transfer(key.currency1, recipient, amount1);
        }

        emit LiquidityRemoved(
            poolId,
            recipient,
            amount0,
            amount1,
            oldTotalShares,
            sharesToBurn.toUint128(),
            block.timestamp
        );
        emit PoolStateUpdated(poolId, newTotalShares, uint8(CallbackType.WITHDRAW));

        return (amount0, amount1);
    }

    /**
     * @notice Pull tokens from the pool manager to this contract
     * @param token The token address (address(0) for ETH)
     * @param amount The amount to pull
     */
    function _pullTokens(address token, uint256 amount) internal {
        if (amount == 0) return;
        Currency currency = Currency.wrap(token);
        manager.take(currency, address(this), amount);
    }

    /**
     * @notice Emergency withdrawal function that bypasses slippage checks
     * @param params The withdrawal parameters
     * @param user The user address
     * @return delta The balance delta from the operation
     * @return amount0Out Token0 amount withdrawn
     * @return amount1Out Token1 amount withdrawn
     */
    function emergencyWithdraw(WithdrawParams calldata params, address user)
        external
        nonReentrant
        returns (BalanceDelta delta, uint256 amount0Out, uint256 amount1Out)
    {
        PoolId poolId = params.poolId;
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));

        if (!emergencyWithdrawalsEnabled && !poolEmergencyState[poolId]) {
            revert Errors.ValidationInvalidInput("Emergency withdraw not enabled");
        }

        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        uint256 userShareBalance = positions.balanceOf(user, tokenId);

        uint256 sharesToBurn = params.shares;
        if (sharesToBurn == 0) revert Errors.ZeroAmount();
        if (sharesToBurn > userShareBalance) {
            revert Errors.InsufficientShares(sharesToBurn, userShareBalance);
        }

        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId);
        uint128 totalSharesInternal = positionTotalShares[poolId];
        uint128 minLocked = lockedShares[poolId];

        // Calculate withdrawal amounts and V4 liquidity to remove
        uint128 v4LiquidityToRemove;
        (amount0Out, amount1Out, v4LiquidityToRemove) = _calculateWithdrawAmounts(
            totalSharesInternal,
            sharesToBurn,
            reserve0,
            reserve1,
            minLocked,
            totalSharesInternal
        );

        PoolKey memory key = _poolKeys[poolId];
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        uint128 oldTotalShares = totalSharesInternal;
        uint128 newTotalShares = oldTotalShares - sharesToBurn.toUint128();
        positionTotalShares[poolId] = newTotalShares;

        positions.burn(user, tokenId, sharesToBurn);

        // CallbackData setup uses poolId correctly
        CallbackData memory callbackData = CallbackData({
            poolId: poolId,
            callbackType: CallbackType.WITHDRAW,
            shares: sharesToBurn.toUint128(),
            oldTotalShares: oldTotalShares,
            amount0: amount0Out,
            amount1: amount1Out,
            recipient: user // Target recipient for withdrawal
        });

        // Unlock handles modifyLiquidity and initial token movement
        bytes memory result = manager.unlock(abi.encode(callbackData));
        delta = abi.decode(result, (BalanceDelta));

        // Handle delta - Pull tokens owed to this contract
        CurrencySettlerExtension.handlePoolDelta(manager, delta, key.currency0, key.currency1, address(this));

        // Transfer final tokens to user
        if (amount0Out > 0) {
            _safeTransferToken(token0, user, amount0Out);
        }
        if (amount1Out > 0) {
            _safeTransferToken(token1, user, amount1Out);
        }

        emit EmergencyWithdrawalCompleted(poolId, user, amount0Out, amount1Out, sharesToBurn);
        emit LiquidityRemoved(
            poolId, user, amount0Out, amount1Out, oldTotalShares, sharesToBurn.toUint128(), block.timestamp
        );
        emit PoolStateUpdated(poolId, newTotalShares, uint8(CallbackType.WITHDRAW));

        return (delta, amount0Out, amount1Out);
    }

    // === EMERGENCY CONTROLS ===

    /**
     * @notice Enable emergency withdrawals for a specific pool
     * @param poolId The pool ID
     * @param reason The reason for enabling emergency mode
     */
    function enablePoolEmergencyState(PoolId poolId, string calldata reason) external onlyEmergencyAdmin {
        poolEmergencyState[poolId] = true;
        emit EmergencyStateActivated(poolId, msg.sender, reason);
    }

    /**
     * @notice Disable emergency withdrawals for a specific pool
     * @param poolId The pool ID
     */
    function disablePoolEmergencyState(PoolId poolId) external onlyEmergencyAdmin {
        poolEmergencyState[poolId] = false;
        emit EmergencyStateDeactivated(poolId, msg.sender);
    }

    /**
     * @notice Enable or disable global emergency withdrawals
     * @param enabled Whether emergency withdrawals should be enabled
     */
    function setGlobalEmergencyState(bool enabled) external onlyEmergencyAdmin {
        emergencyWithdrawalsEnabled = enabled;
        emit GlobalEmergencyStateChanged(enabled, msg.sender);
    }

    // === INTERNAL HELPER FUNCTIONS ===

    /**
     * @dev Converts a uint256 to its string representation.
     * @param value The uint256 value to convert.
     * @return The string representation of the value.
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /**
     * @notice Calculate withdrawal amounts based on shares and pool state.
     * @param totalV4Liquidity Current total V4 liquidity tracked internally.
     * @param sharesToBurn       Usable (ERC-6909) shares being burned.
     * @param reserve0 Current token0 reserves (read from pool state).
     * @param reserve1 Current token1 reserves (read from pool state).
     * @param minLockedShares   The permanently-locked ERC-6909 shares.
     * @return amount0 Token0 amount to withdraw.
     * @return amount1 Token1 amount to withdraw.
     * @return v4LiquidityToWithdraw The amount of V4 liquidity corresponding to the burned shares.
     */
    function _calculateWithdrawAmounts(
        uint128 totalV4Liquidity,
        uint256 sharesToBurn,
        uint256 reserve0,
        uint256 reserve1,
        uint256 minLockedShares,
        uint256 totalShares_global
    ) internal pure returns (uint256 amount0, uint256 amount1, uint128 v4LiquidityToWithdraw) {
        if (totalV4Liquidity == 0) revert Errors.PoolNotInitialized(bytes32(0));
        if (sharesToBurn == 0) return (0, 0, 0);

        uint128 lockedS = uint128(minLockedShares);
        if (lockedS > totalShares_global) revert Errors.ValidationInvalidInput("Locked shares exceed total");

        uint128 totalUsableShares = uint128(totalShares_global - lockedS);
        if (totalUsableShares == 0) revert Errors.InsufficientShares(sharesToBurn, 0);

        v4LiquidityToWithdraw = MathUtils
            .calculateProportional(totalV4Liquidity, sharesToBurn, totalUsableShares, false)
            .toUint128();

        amount0 = MathUtils.calculateProportional(reserve0, v4LiquidityToWithdraw, totalV4Liquidity, false);
        amount1 = MathUtils.calculateProportional(reserve1, v4LiquidityToWithdraw, totalV4Liquidity, false);
    }

    /**
     * @notice Get position data directly from PoolManager state for full range.
     * @param poolId The pool ID.
     * @return liquidity Current liquidity in the full range position.
     * @return sqrtPriceX96 Current sqrt price.
     * @return success Boolean indicating if data read was successful.
     */
    function getPositionData(PoolId poolId)
        public
        view
        returns (uint128 liquidity, uint160 sqrtPriceX96, bool success)
    {
        PoolKey memory key = _poolKeys[poolId];
        if (key.tickSpacing == 0) return (0, 0, false); // Pool not registered here

        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        // Calculate position key
        bytes32 positionKey = Position.calculatePositionKey(address(this), tickLower, tickUpper, bytes32(0));

        // IMPORTANT: We need to get the correct storage slot for this position
        // First get the pool state slot
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));
        // Get the position mapping slot
        bytes32 positionMappingSlot = bytes32(uint256(stateSlot) + POSITIONS_OFFSET);
        // Calculate the final position slot
        // bytes32 positionSlot = keccak256(abi.encodePacked(positionKey, positionMappingSlot)); // Removed assignment

        // Get global Slot0 data to retrieve sqrtPriceX96
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, poolId);

        // Now read the position's liquidity from storage
        // Use StateLibrary to get position info instead of direct storage access
        liquidity = StateLibrary.getPositionLiquidity(manager, poolId, positionKey);
        success = liquidity > 0 && sqrtPriceX96 > 0;

        return (liquidity, sqrtPriceX96, success);
    }

    /**
     * @notice Gets the current reserves for a pool directly from PoolManager state.
     * @param poolId The pool ID.
     * @return reserve0 The amount of token0 in the pool.
     * @return reserve1 The amount of token1 in the pool.
     */
    function getPoolReserves(PoolId poolId) public view override returns (uint256 reserve0, uint256 reserve1) {
        (uint128 liquidity, uint160 sqrtPriceX96, bool success) = getPositionData(poolId);

        if (!success || liquidity == 0) {
            return (0, 0); // No position data or zero liquidity
        }

        PoolKey memory key = _poolKeys[poolId]; // Assume key exists if position data was successful
        if (key.tickSpacing == 0) {
            // This case should ideally not happen if success is true, but added as safeguard
            return (0, 0);
        }

        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // Calculate token amounts based on liquidity and current price within the full range
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            // Price is below the full range
            reserve0 = SqrtPriceMath.getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, false);
            reserve1 = 0;
        } else if (sqrtPriceX96 >= sqrtRatioBX96) {
            // Price is above the full range
            reserve0 = 0;
            reserve1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, false);
        } else {
            // Price is within the full range
            reserve0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtRatioBX96, liquidity, false);
            reserve1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, liquidity, false);
        }
    }

    /**
     * @notice Check if a pool has been initialized (i.e., key stored).
     * @param poolId The pool ID.
     */
    function isPoolInitialized(PoolId poolId) public view returns (bool) {
        // bytes32 _poolIdBytes = PoolId.unwrap(poolId); // avoid "unused" warning - Removed assignment
        // Check if tickSpacing is non-zero, indicating the key has been stored
        return _poolKeys[poolId].tickSpacing != 0; // Use original poolId for mapping access
    }

    /**
     * @notice Handle the balance delta from a modifyLiquidity operation
     * @param delta The balance delta from the operation
     * @param token0 The address of token0
     * @param token1 The address of token1
     */
    function _handleDelta(BalanceDelta delta, address token0, address token1) internal {
        // Convert addresses to Currency types for consistent abstraction
        Currency currency0 = Currency.wrap(token0);
        Currency currency1 = Currency.wrap(token1);

        // Handle token0 transfer
        int128 amount0 = delta.amount0();
        if (amount0 < 0) {
            uint256 amount = uint256(int256(-amount0));

            if (currency0.isAddressZero()) {
                // Handle native ETH
                manager.settle{value: amount}();
            } else {
                // Handle ERC20
                IERC20Minimal(token0).approve(address(manager), amount);
                manager.settle();
            }
        } else if (amount0 > 0) {
            // Need to receive tokens from the pool
            manager.take(currency0, address(this), uint256(int256(amount0)));
        }

        // Handle token1 transfer
        int128 amount1 = delta.amount1();
        if (amount1 < 0) {
            uint256 amount = uint256(int256(-amount1));

            if (currency1.isAddressZero()) {
                // Handle native ETH
                manager.settle{value: amount}();
            } else {
                // Handle ERC20
                IERC20Minimal(token1).approve(address(manager), amount);
                manager.settle();
            }
        } else if (amount1 > 0) {
            // Need to receive tokens from the pool
            manager.take(currency1, address(this), uint256(int256(amount1)));
        }
    }

    /**
     * @notice Transfer token to recipient, handling ETH and ERC20 correctly
     * @param token The token address (address(0) for ETH)
     * @param to The recipient address
     * @param amount The amount to transfer
     */
    function _safeTransferToken(address token, address to, uint256 amount) internal {
        if (amount == 0) return;

        Currency currency = Currency.wrap(token);
        if (currency.isAddressZero()) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            // Handle ERC20 using SafeTransferLib for additional safety checks
            SafeTransferLib.safeTransfer(ERC20(token), to, amount);
        }
    }

    /**
     * @notice Get the storage slot for a pool's state
     * @param poolId The pool ID
     * @return The storage slot for the pool's state
     */
    function _getPoolStateSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, POOLS_SLOT));
    }

    /**
     * @notice Gets share balance for an account in a specific pool.
     * @dev The `initialized` flag is true if shares > 0.
     * @inheritdoc IFullRangeLiquidityManager
     */
    function getAccountPosition(PoolId poolId, address account)
        external
        view
        override
        returns (bool initialized, uint256 shares)
    {
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        shares = positions.balanceOf(account, tokenId);
        initialized = shares > 0;
    }

    /**
     * @notice Special internal function for Margin contract to borrow liquidity without burning LP tokens
     * @param poolId The pool ID to borrow from
     * @param sharesToBorrow Amount of shares to borrow (determines token amounts)
     * @param recipient Address to receive the tokens (typically the Margin contract)
     * @return amount0 Amount of token0 received
     * @return amount1 Amount of token1 received
     */
    function borrowImpl(PoolId poolId, uint256 sharesToBorrow, address recipient)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (sharesToBorrow == 0) revert Errors.ZeroAmount();

        uint128 totalSharesInternal = positionTotalShares[poolId];
        if (totalSharesInternal == 0) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));

        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId);

        // Calculate amounts based on shares
        amount0 = MathUtils.calculateProportional(reserve0, sharesToBorrow, totalSharesInternal, false);
        amount1 = MathUtils.calculateProportional(reserve1, sharesToBorrow, totalSharesInternal, false);

        // Prepare callback data
        CallbackData memory callbackData = CallbackData({
            poolId: poolId,
            callbackType: CallbackType.BORROW,
            shares: sharesToBorrow.toUint128(),
            oldTotalShares: totalSharesInternal,
            amount0: amount0,
            amount1: amount1,
            recipient: recipient
        });

        // Unlock calls modifyLiquidity via hook and transfers tokens
        manager.unlock(abi.encode(callbackData));

        emit TokensBorrowed(poolId, recipient, amount0, amount1, sharesToBorrow);

        return (amount0, amount1);
    }

    /**
     * @notice Reinvests fees for protocol-owned liquidity
     * @param poolId The pool ID
     * @param polAmount0 Amount of token0 for protocol-owned liquidity
     * @param polAmount1 Amount of token1 for protocol-owned liquidity
     * @return shares The number of POL shares minted
     */
    function reinvestFees(PoolId poolId, uint256 polAmount0, uint256 polAmount1)
        external
        payable
        nonReentrant
        returns (uint256 shares)
    {
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
        if (polAmount0 == 0 && polAmount1 == 0) revert Errors.ZeroAmount();

        PoolKey memory key = _poolKeys[poolId];
        uint128 totalSharesInternal = positionTotalShares[poolId];

        // ————— 1a) require correct ETH if one side is native
        bool t0Native = key.currency0.isAddressZero();
        bool t1Native = key.currency1.isAddressZero();
        uint256 neededEth = (t0Native ? polAmount0 : 0) + (t1Native ? polAmount1 : 0);
        require(msg.value == neededEth, "FullRangeLM: wrong ETH");

        // Get current pool state
        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId);

        // Calculate shares based on the ratio of provided amounts to current reserves
        uint256 s0 = reserve0 > 0 ? MathUtils.calculateProportional(polAmount0, totalSharesInternal, reserve0, true) : 0;
        uint256 s1 = reserve1 > 0 ? MathUtils.calculateProportional(polAmount1, totalSharesInternal, reserve1, true) : 0;

        // Use the smaller share amount to maintain ratio
        shares = s0 < s1 ? s0 : s1;
        if (shares == 0) revert Errors.ZeroAmount();

        // Prepare callback data
        CallbackData memory callbackData = CallbackData({
            poolId: poolId,
            callbackType: CallbackType.REINVEST_PROTOCOL_FEES,
            shares: shares.toUint128(),
            oldTotalShares: totalSharesInternal,
            amount0: polAmount0,
            amount1: polAmount1,
            recipient: address(this)
        });

        // ————— 2) perform the re‑entrancy + liquidity add (pass ETH along if needed)
        manager.unlock(abi.encode(callbackData));

        // ————— 2b) cleanup ERC‑20 approvals
        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        if (!t0Native && polAmount0 > 0) SafeTransferLib.safeApprove(ERC20(t0), address(manager), 0);
        if (!t1Native && polAmount1 > 0) SafeTransferLib.safeApprove(ERC20(t1), address(manager), 0);

        emit ProtocolFeesReinvested(poolId, address(this), polAmount0, polAmount1);

        // Convert liquidity minted → ERC-6909 shares using current ratio
        uint128 positionLiquidity_before = positionTotalShares[poolId];  // Store initial liquidity
        uint128 newShares = uint128(
            FullMath.mulDiv(shares, positionTotalShares[poolId], positionLiquidity_before)
        );
        positionTotalShares[poolId] += newShares;
        positions.mint(address(this), PoolTokenIdUtils.toTokenId(poolId), newShares);

        return shares;
    }

    /**
     * @notice Get the value of shares in terms of underlying tokens
     * @param poolId The pool ID
     * @param shares The number of shares
     */
    function getShareValue(PoolId poolId, uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        uint128 totalShares = positionTotalShares[poolId];
        if (totalShares == 0) return (0, 0);

        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId);
        amount0 = MathUtils.calculateProportional(reserve0, shares, totalShares, false);
        amount1 = MathUtils.calculateProportional(reserve1, shares, totalShares, false);
    }

    /**
     * @notice Get user's shares for a specific pool
     * @param poolId The pool ID
     * @param user The user address
     */
    function getUserShares(PoolId poolId, address user) external view returns (uint256) {
        return positions.balanceOf(user, uint256(PoolId.unwrap(poolId)));
    }

    /**
     * @notice Update position cache
     * @param poolId The pool ID
     */
    function updatePositionCache(PoolId poolId) external pure returns (bool success) {
        poolId; // silence
        // Implementation specific to your needs
        return false;
    }

    /**
     * @notice Update total shares for a pool
     * @param poolId The pool ID
     * @param newTotalShares The new total shares value
     */
    function updateTotalShares(PoolId poolId, uint128 newTotalShares) external pure {
        poolId;
        newTotalShares; // silence
        // Implementation specific to your needs
        revert("Not implemented");
    }

    /**
     * @notice Callback function called by PoolManager during unlock operations
     * @param data Encoded callback data containing operation details
     * @return bytes The encoded BalanceDelta from the operation
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // Only allow calls from the pool manager
        if (msg.sender != address(manager)) {
            revert Errors.AccessNotAuthorized(msg.sender);
        }

        // Decode the callback data
        CallbackData memory cbData = abi.decode(data, (CallbackData));

        // Verify the pool ID exists
        PoolKey memory key = _poolKeys[cbData.poolId];
        if (key.tickSpacing == 0) revert Errors.PoolNotInitialized(PoolId.unwrap(cbData.poolId));

        int256 liquidityDelta;
        address recipient;
        if (cbData.callbackType == CallbackType.DEPOSIT || cbData.callbackType == CallbackType.REINVEST_PROTOCOL_FEES) {
            liquidityDelta = int256(uint256(cbData.shares));
            recipient = address(this); // Tokens stay/settle within LM
        } else if (cbData.callbackType == CallbackType.WITHDRAW || cbData.callbackType == CallbackType.BORROW) {
            liquidityDelta = -int256(uint256(cbData.shares));
            recipient = cbData.recipient; // Tokens sent to original caller
        } else {
            revert Errors.InvalidCallbackType(uint8(cbData.callbackType));
        }

        // Modify liquidity in the pool using liquidityDelta derived from cbData.shares
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            liquidityDelta: liquidityDelta,
            salt: bytes32(0)
        });

        (BalanceDelta actualDelta,) = manager.modifyLiquidity(key, params, "");

        // Handle settlement using CurrencySettlerExtension
        CurrencySettlerExtension.handlePoolDelta(manager, actualDelta, key.currency0, key.currency1, recipient);

        // Return the actual delta from modifyLiquidity
        return abi.encode(actualDelta);
    }

    /**
     * @notice Internal reinvestment tracking function that can only be called by Spot (fullRange)
     * @dev This is called by the Spot contract during a successful reinvestment to update shares
     * @param poolId The pool ID that was reinvested
     * @param liquidity The amount of liquidity added during reinvestment
     * @param recipient The address to receive any LP tokens (unused in current implementation)
     */
    function internalReinvest(PoolId poolId, uint128 liquidity, address recipient) external onlyFullRange {
        // no-op: accounting already updated inside reinvest()
    }

    /// helper required by the test-suite
    function getPoolReservesAndShares(PoolId poolId)
        external
        view
        override
        returns (uint256 reserve0, uint256 reserve1, uint128 totalShares)
    {
        (reserve0, reserve1) = getPoolReserves(poolId);
        totalShares = positionTotalShares[poolId];
    }

    /**
     * @dev Protocol‑fee reinvest – assumes Spot has calculated required amounts.
     *      Amounts/liquidity are provided; this function approves PM and initiates unlock.
     *      The actual token `take` and `modifyLiquidity` happen in unlockCallback.
     */
    // --- Reverted to take use0, use1, liq ---
    function reinvest(PoolId poolId, uint256 use0, uint256 use1, uint128 liq)
        external
        payable
        override
        onlyFullRange
        nonReentrant
        returns (uint128)
    {
        // sanity checks
        PoolKey memory key = _poolKeys[poolId];
        if (key.tickSpacing == 0) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
        if (liq == 0) revert Errors.ZeroAmount();

        // --- Reverted: Approve provided amounts ---
        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        if (use0 > 0 && t0 != address(0)) SafeTransferLib.safeApprove(ERC20(t0), address(manager), use0);
        if (use1 > 0 && t1 != address(0)) SafeTransferLib.safeApprove(ERC20(t1), address(manager), use1);

        // build callback data including amounts and liquidity
        CallbackData memory cb = CallbackData({
            poolId: poolId,
            callbackType: CallbackType.REINVEST_PROTOCOL_FEES,
            shares: liq, // Use provided liquidity
            oldTotalShares: positionTotalShares[poolId],
            amount0: use0, // Use provided amount0
            amount1: use1, // Use provided amount1
            recipient: address(this)
        });
        // --- END Reverted ---

        // do the unlock → (modifyLiquidity -> settlement) dance
        manager.unlock(abi.encode(cb));

        // Clear allowances after unlock
        if (use0 > 0 && t0 != address(0)) SafeTransferLib.safeApprove(ERC20(t0), address(manager), 0);
        if (use1 > 0 && t1 != address(0)) SafeTransferLib.safeApprove(ERC20(t1), address(manager), 0);

        // update accounting *and* mint POL shares so users are not diluted
        positionTotalShares[poolId] += liq;
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        positions.mint(address(this), tokenId, liq);

        // Emit event with the amounts provided by Spot
        emit Reinvested(poolId, liq, use0, use1);

        return liq;
    }

    /**
     * @notice Gets pool reserves using a pre-fetched sqrt price to avoid redundant reads.
     * @param poolId The ID of the pool.
     * @param sqrtPriceX96 The pre-fetched sqrtPriceX96 of the pool.
     * @return reserve0 The reserve of token0.
     * @return reserve1 The reserve of token1.
     */
    function getPoolReservesWithPrice(PoolId poolId, uint160 sqrtPriceX96)
        public
        view
        returns (uint256 reserve0, uint256 reserve1)
    {
        PoolKey memory k = _poolKeys[poolId];
        if (k.tickSpacing == 0) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));

        // 1) compute posKey & bail early if no liquidity
        bytes32 posKey = Position.calculatePositionKey(
            address(this), TickMath.minUsableTick(k.tickSpacing), TickMath.maxUsableTick(k.tickSpacing), bytes32(0)
        );
        uint128 liq = StateLibrary.getPositionLiquidity(manager, poolId, posKey);
        if (liq == 0) return (0, 0);

        // 2) now compute boundaries once
        int24 lower = TickMath.minUsableTick(k.tickSpacing);
        int24 upper = TickMath.maxUsableTick(k.tickSpacing);
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);

        // 3) select correct formula
        if (sqrtPriceX96 <= sqrtA) {
            // price below range → all in token0
            reserve0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liq, false);
            reserve1 = 0;
        } else if (sqrtPriceX96 >= sqrtB) {
            // price above range → all in token1
            reserve1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liq, false);
        } else {
            // price within range → split across both
            reserve0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtB, liq, false);
            reserve1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, liq, false);
        }
    }

    /**
     * @notice Verify pool liquidity and state after operations
     * @param poolId The pool ID to check
     * @return liquidity Current liquidity in the pool
     * @return totalShares Total shares tracked internally
     */
    function verifyPoolState(PoolId poolId) external view returns (uint128 liquidity, uint128 totalShares) {
        // Get actual pool liquidity
        bytes32 posKey = Position.calculatePositionKey(
            address(this),
            TickMath.minUsableTick(_poolKeys[poolId].tickSpacing),
            TickMath.maxUsableTick(_poolKeys[poolId].tickSpacing),
            bytes32(0)
        );
        liquidity = StateLibrary.getPositionLiquidity(manager, poolId, posKey);
        
        // Get tracked shares
        totalShares = positionTotalShares[poolId];
        
        // Ensure we have more than just locked liquidity
        require(liquidity > MIN_LOCKED_LIQUIDITY, "Insufficient pool liquidity");
        require(totalShares > MIN_LOCKED_SHARES, "Insufficient total shares");
        
        return (liquidity, totalShares);
    }
}
