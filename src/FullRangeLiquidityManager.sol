// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// --- Uniswap V4 / Periphery Imports ---
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

// --- Solmate / OpenZeppelin Imports ---
import {Owned} from "solmate/src/auth/Owned.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// --- Project Imports ---
import {IFullRangeLiquidityManager} from "./interfaces/IFullRangeLiquidityManager.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {Errors} from "./errors/Errors.sol";
import {FullRangePositions, IFullRangePositions} from "./token/FullRangePositions.sol";
import {PoolTokenIdUtils} from "./utils/PoolTokenIdUtils.sol";
import {CurrencySettlerExtension} from "./utils/CurrencySettlerExtension.sol";
import {ExtendedPositionManager} from "./ExtendedPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

using SafeCast for uint256;
using SafeCast for int256;
using PoolIdLibrary for PoolKey;
using CurrencyLibrary for Currency;

/**
 * @title FullRangeLiquidityManager
 * @notice Manages full-range liquidity positions across multiple pools
 * @dev Phase 1: POL-only, restricted deposits/withdrawals. Core logic kept for Phase 2.
 */
contract FullRangeLiquidityManager is Owned, ReentrancyGuard, IFullRangeLiquidityManager, IUnlockCallback {
    // Struct for deposit calculation results (kept as internal helper uses it)
    struct DepositCalculationResult {
        uint256 actual0;
        uint256 actual1;
        uint128 sharesToAdd;
        uint128 lockedAmount;
        uint128 v4LiquidityForCallback;
    }

    /// @dev The Uniswap V4 PoolManager reference
    IPoolManager public immutable manager;
    /// @dev Pool Policy Manager reference (optional, for governance lookup)
    IPoolPolicy public immutable policyManager;
    /// @dev Extended Position Manager reference
    ExtendedPositionManager public immutable posManager;

    /// @dev deployed once in constructor; immutable reference
    IFullRangePositions public immutable positions;

    /// @dev Total ERC-6909 shares issued for *our* full-range position
    mapping(PoolId => uint128) public positionTotalShares;

    /// @dev Pool keys for lookups
    mapping(PoolId => PoolKey) private _poolKeys;

    /// @dev Address authorized to store pool keys (typically the associated hook contract)
    /// Set by the owner via setAuthorizedHookAddress.
    address public authorizedHookAddress_;

    /// @dev NFT id per pool
    mapping(PoolId => uint256) public positionTokenId;

    /// @notice Expose getter expected by interface
    function authorizedHookAddress() external view override returns (address) {
        return authorizedHookAddress_;
    }

    // ────────────────────────── CONSTANTS ──────────────────────────
    uint128 private constant MIN_LOCKED_SHARES = 1_000; // Kept for first deposit calc
    uint128 private constant MIN_LOCKED_LIQUIDITY = 1_000; // V4 liq seed

    // Permanently-locked ERC-6909 shares (min-liquidity analogue)
    mapping(PoolId => uint128) public lockedShares; // Kept

    // Events for pool management
    event PoolKeyStored(PoolId indexed poolId, PoolKey key); // Kept
    event AuthorizedHookAddressSet(address indexed hookAddress); // Kept
    event MinimumSharesLocked(PoolId indexed poolId, uint128 amount); // Kept
    event LiquidityAdded( // Kept
        PoolId indexed poolId,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1,
        uint128 oldTotalShares,
        uint128 mintedShares,
        uint256 timestamp
    );
    event LiquidityRemoved( // Kept
        PoolId indexed poolId,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1,
        uint128 oldTotalShares,
        uint128 burnedShares,
        uint256 timestamp
    );
    event PoolStateUpdated(PoolId indexed poolId, uint128 newTotalShares, uint8 opType);
    event Reinvested(PoolId indexed poolId, uint128 liquidityMinted, uint256 amount0, uint256 amount1);

    // Storage slot constants for V4 state access
    bytes32 private constant POOLS_SLOT = bytes32(uint256(6));

    /// @notice Operation selector sent to the hook/PoolManager via `unlock`
    enum CallbackType {
        DEPOSIT,
        WITHDRAW,
        REINVEST_PROTOCOL_FEES
    }

    /// @notice Encoded in `unlock` calldata so Spot ↔︎ LM stay in sync
    struct CallbackData {
        PoolId poolId;
        CallbackType callbackType;
        uint128 shares; // v4-liquidity to add/remove
        uint128 oldTotalShares; // bookkeeping
        uint256 amount0;
        uint256 amount1;
        address recipient; // where token balances finally go
    }

    /* ────────── Modifiers ────────── */

    // Added definitions

    /**
     * @dev Governance gate.
     *
     *  - Deployer/owner (traditional governance) **or**
     *  - `authorizedHookAddress` (Spot hook) may call the guarded function.
     *
     *  This un-blocks protocol-initiated flows such as fee-reinvestment
     *  where the hook needs to move liquidity on-chain without routing
     *  through the EOA governor.
     */
    modifier onlyGovernance() {
        address gov = address(policyManager) != address(0) ? policyManager.getSoloGovernance() : owner;
        if (msg.sender != gov && msg.sender != authorizedHookAddress_) {
            revert Errors.AccessOnlyGovernance(msg.sender);
        }
        _;
    }

    modifier onlyHook() {
        if (msg.sender != authorizedHookAddress_) revert Errors.AccessNotAuthorized(msg.sender);
        _;
    }

    /**
     * @notice Constructor
     * @param _manager The Uniswap V4 pool manager
     * @param _posManager The Extended Position Manager contract
     * @param _policyManager The Pool Policy Manager contract
     * @param _owner The owner of the contract
     */
    constructor(IPoolManager _manager, ExtendedPositionManager _posManager, IPoolPolicy _policyManager, address _owner)
        Owned(_owner)
    {
        manager = _manager;
        posManager = _posManager;
        policyManager = _policyManager;
        positions = new FullRangePositions("FullRange Position", "FRP", address(this));
    }

    /**
     * @notice Sets the authorized hook address (Spot contract)
     * @dev Can only be set once by the owner.
     * @param _hookAddress The address of the Spot hook contract.
     */
    function setAuthorizedHookAddress(address _hookAddress) external onlyOwner {
        // Ensure it can only be set once
        require(authorizedHookAddress_ == address(0), "Hook address already set");
        require(_hookAddress != address(0), "Invalid address");
        authorizedHookAddress_ = _hookAddress;
        emit AuthorizedHookAddressSet(_hookAddress);
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
    function storePoolKey(PoolId poolId, PoolKey calldata key) external override onlyHook {
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
     * @notice Get the position token contract
     * @return The position token contract
     */
    function getPositionsContract() external view returns (FullRangePositions) {
        return FullRangePositions(address(positions));
    }

    // === LIQUIDITY MANAGEMENT FUNCTIONS ===

    /**
     * @notice Deposit tokens into a pool with native ETH support
     * @dev Phase 1: Governance only. Core logic unchanged.
     * @inheritdoc IFullRangeLiquidityManager
     */
    function deposit(
        PoolId poolId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    )
        external
        payable
        override
        nonReentrant
        onlyGovernance
        returns (uint256 usableShares, uint256 amount0, uint256 amount1)
    {
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
        if (amount0Desired == 0 && amount1Desired == 0) revert Errors.ZeroAmount(); // Must desire some amount

        PoolKey memory key = _poolKeys[poolId];
        (, uint160 sqrtPriceX96,) = getPositionData(poolId);
        uint128 totalSharesInternal = positionTotalShares[poolId];

        if (sqrtPriceX96 == 0 && totalSharesInternal == 0) {
            (sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, poolId);
            if (sqrtPriceX96 == 0) revert Errors.ValidationInvalidInput("Pool price is zero");
        }

        // ——— 3) single‐read slot0 and reuse it for getPoolReserves
        (uint256 reserve0, uint256 reserve1) = getPoolReservesWithPrice(poolId, sqrtPriceX96);

        // Declare *after* the reserves are fetched to keep them off the stack
        bool hasToken0Native = key.currency0.isAddressZero();
        bool hasToken1Native = key.currency1.isAddressZero();

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
        uint128 newTotalSharesInternal = oldTotalSharesInternal + sharesToAdd + uint128(calcResult.lockedAmount);
        positionTotalShares[poolId] = newTotalSharesInternal;

        // ─── lock the first MIN_LOCKED_SHARES by minting to address(0) ───
        if (calcResult.lockedAmount > 0 && lockedShares[poolId] == 0) {
            uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
            lockedShares[poolId] = uint128(calcResult.lockedAmount);
            FullRangePositions(address(positions)).mint(address(0), tokenId, calcResult.lockedAmount); // irrevocable
            emit MinimumSharesLocked(poolId, uint128(calcResult.lockedAmount));
        }

        usableShares = uint256(sharesToAdd);
        if (usableShares > 0) {
            uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
            FullRangePositions(address(positions)).mint(recipient, tokenId, usableShares);
        }

        // Transfer non-native tokens from msg.sender
        if (amount0 > 0 && !hasToken0Native) {
            SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(key.currency0)), msg.sender, address(this), amount0);
        }
        if (amount1 > 0 && !hasToken1Native) {
            SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(key.currency1)), msg.sender, address(this), amount1);
        }

        // ------------------------------------------------------------------
        // Interact with PositionManager
        // ------------------------------------------------------------------

        uint256 nftId = _getOrCreatePosition(key, poolId);

        // Approvals for Permit2 are handled in test harness / deployment scripts.

        posManager.increaseLiquidity{value: ethNeeded}( // forward only needed ETH
            nftId,
            v4LiquidityForPM,
            type(uint128).max,
            type(uint128).max,
            ""
        );

        // Refund excess ETH
        if (msg.value > ethNeeded) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - ethNeeded);
        }

        emit LiquidityAdded(
            poolId, recipient, amount0, amount1, oldTotalSharesInternal, uint128(usableShares), block.timestamp
        );
        // no longer rely on CallbackType enum, use opType 1 for deposit in new scheme
        emit PoolStateUpdated(poolId, newTotalSharesInternal, 1);

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
            _handleFirstDepositInternal(sqrtPriceX96, tickSpacing, amount0Desired, amount1Desired, result);
        } else {
            // Calculate optimal V2 shares to mint based on desired amounts and current reserves ratio
            uint256 shares0 =
                reserve0 == 0 ? type(uint256).max : FullMath.mulDiv(amount0Desired, totalSharesInternal, reserve0);
            uint256 shares1 =
                reserve1 == 0 ? type(uint256).max : FullMath.mulDiv(amount1Desired, totalSharesInternal, reserve1);
            uint128 shares = (shares0 < shares1 ? shares0 : shares1).toUint128();
            if (shares == 0) revert Errors.ZeroAmount();

            // Calculate actual amounts needed for these V2 shares
            uint256 actual0 = FullMath.mulDiv(shares, reserve0, totalSharesInternal);
            uint256 actual1 = FullMath.mulDiv(shares, reserve1, totalSharesInternal);

            // Calculate the V4 liquidity corresponding to these actual amounts
            result.v4LiquidityForCallback = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(tickSpacing)),
                TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(tickSpacing)),
                actual0,
                actual1
            );

            result.actual0 = actual0;
            result.actual1 = actual1;
            result.sharesToAdd = shares; // V2-style shares
            result.lockedAmount = 0; // No locking for subsequent deposits
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

        if (amount0Desired == 0 || amount1Desired == 0) {
            revert Errors.ZeroAmount(); // Simplified check
        }
        if (sqrtPriceX96 == 0) revert Errors.ValidationInvalidInput("Initial price is zero");

        // Calculate V4 liquidity using BOTH desired amounts
        uint128 v4Liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0Desired, amount1Desired
        );
        if (v4Liquidity == 0) revert Errors.ZeroAmount();

        // Calculate actual amounts needed for this V4 liquidity (rounding up)
        uint256 actual0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtRatioBX96, v4Liquidity, true);
        uint256 actual1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, v4Liquidity, true);

        // Cap actual amounts at desired amounts (safety check)
        actual0 = Math.min(actual0, amount0Desired);
        actual1 = Math.min(actual1, amount1Desired);

        // V2 Share Calculation based on actual amounts
        uint128 minLiq128 = MIN_LOCKED_SHARES; // Use MIN_LOCKED_SHARES constant
        uint256 totalV2Shares = Math.sqrt(actual0 * actual1);

        if (totalV2Shares < minLiq128) {
            revert Errors.InitialDepositTooSmall(minLiq128, totalV2Shares.toUint128());
        }

        uint128 usableV2Shares = (totalV2Shares - minLiq128).toUint128();
        // Note: Original check usableV2Shares == 0 seems redundant if totalV2Shares >= minLiq128 and minLiq128 > 0

        result.actual0 = actual0;
        result.actual1 = actual1;
        result.sharesToAdd = usableV2Shares;
        result.lockedAmount = minLiq128;
        result.v4LiquidityForCallback = v4Liquidity; // Store calculated V4 liquidity
    }

    /**
     * @notice Withdraw liquidity from a pool
     * @dev Phase 1: Governance only. Core logic unchanged.
     * @inheritdoc IFullRangeLiquidityManager
     */
    function withdraw(PoolId poolId, uint256 sharesToBurn, uint256 amount0Min, uint256 amount1Min, address recipient)
        external
        override
        nonReentrant
        onlyGovernance
        returns (uint256 amount0, uint256 amount1)
    {
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
        if (sharesToBurn == 0) revert Errors.ZeroAmount();

        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        uint256 govShareBalance = FullRangePositions(address(positions)).balanceOf(msg.sender, tokenId);
        if (sharesToBurn > govShareBalance) {
            revert Errors.InsufficientShares(sharesToBurn, govShareBalance);
        }

        uint128 totalShares = positionTotalShares[poolId];
        if (totalShares == 0) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));

        uint128 minLocked = lockedShares[poolId];
        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId);

        // Get V4 liquidity for calculations
        (uint128 currentV4Liquidity,,) = getPositionData(poolId);

        // declare the variable that will receive the 3rd tuple element
        uint128 v4LiquidityToWithdraw;
        (amount0, amount1, v4LiquidityToWithdraw) =
            _calculateWithdrawAmounts(currentV4Liquidity, sharesToBurn, reserve0, reserve1, minLocked, totalShares);

        if (amount0 < amount0Min || amount1 < amount1Min) {
            revert Errors.SlippageExceeded(
                (amount0 < amount0Min) ? amount0Min : amount1Min, (amount0 < amount0Min) ? amount0 : amount1
            );
        }

        PoolKey memory key = _poolKeys[poolId];

        uint128 oldTotalShares = totalShares;
        uint128 newTotalShares = oldTotalShares - sharesToBurn.toUint128();
        positionTotalShares[poolId] = newTotalShares;

        // Burn shares from governance (msg.sender)
        FullRangePositions(address(positions)).burn(msg.sender, tokenId, sharesToBurn);

        // Call PositionManager to remove liquidity from the NFT
        uint256 nftId = positionTokenId[poolId];
        posManager.decreaseLiquidity(nftId, v4LiquidityToWithdraw, uint128(amount0Min), uint128(amount1Min), "");

        // Transfer withdrawn tokens to the final recipient
        if (amount0 > 0) {
            CurrencyLibrary.transfer(key.currency0, recipient, amount0);
        }
        if (amount1 > 0) {
            CurrencyLibrary.transfer(key.currency1, recipient, amount1);
        }

        emit LiquidityRemoved(
            poolId, recipient, amount0, amount1, oldTotalShares, sharesToBurn.toUint128(), block.timestamp
        );
        emit PoolStateUpdated(poolId, newTotalShares, 2);

        return (amount0, amount1);
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

        // Get global Slot0 data to retrieve sqrtPriceX96
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, poolId);

        // Now read the position's liquidity from storage
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
        return _poolKeys[poolId].tickSpacing != 0;
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
        shares = FullRangePositions(address(positions)).balanceOf(account, tokenId);
        initialized = shares > 0;
    }

    /**
     * @notice Callback function called by PoolManager during unlock operations
     * @param data Encoded callback data containing operation details
     * @return bytes The encoded BalanceDelta from the operation
     */
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
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
        } else if (cbData.callbackType == CallbackType.WITHDRAW) {
            liquidityDelta = -int256(uint256(cbData.shares));
            recipient = cbData.recipient; // Tokens sent to original caller
        } else {
            revert Errors.InvalidCallbackType(uint8(cbData.callbackType));
        }

        // Modify liquidity in the pool using liquidityDelta derived from cbData.shares
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            liquidityDelta: liquidityDelta,
            salt: bytes32(0)
        });

        // 1. Add / remove liquidity
        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, "");

        // Perform settlement
        CurrencySettlerExtension.handlePoolDelta(manager, delta, key.currency0, key.currency1, recipient);

        // Tell the PoolManager that everything is settled
        BalanceDelta zeroDelta;
        return abi.encode(zeroDelta);
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
    function reinvest(PoolId poolId, uint256 use0, uint256 use1, uint128 liq)
        external
        payable
        override
        nonReentrant
        returns (uint128)
    {
        // sanity checks
        PoolKey memory key = _poolKeys[poolId];
        if (key.tickSpacing == 0) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
        if (liq == 0) revert Errors.ZeroAmount();

        // build callback data including amounts and liquidity
        CallbackData memory cb = CallbackData({
            poolId: poolId,
            callbackType: CallbackType.REINVEST_PROTOCOL_FEES,
            shares: liq, // Use provided liquidity
            oldTotalShares: positionTotalShares[poolId],
            amount0: use0, // Pass provided amount0 (for event/tracking)
            amount1: use1, // Pass provided amount1 (for event/tracking)
            recipient: address(this) // Settlement happens within LM
        });

        // ─── handle native ETH credit first (PoolManager.settle is payable) ───
        uint256 ethToSend;
        if (key.currency0.isAddressZero()) ethToSend += use0;
        if (key.currency1.isAddressZero()) ethToSend += use1;
        require(msg.value == ethToSend, "Incorrect ETH value for reinvest");
        if (ethToSend > 0) manager.settle{value: ethToSend}();

        // do the unlock → modifyLiquidity (+ take/settle inside callback) – **no** value forwarded
        manager.unlock(abi.encode(cb));

        // (no ERC-20 approvals were set, nothing to clear)

        // update accounting *and* mint POL shares so users are not diluted
        // Calculate V2 shares equivalent to the V4 liquidity 'liq' added
        (uint128 currentV4LiquidityBefore,,) = getPositionData(poolId);
        uint128 v2SharesEquivalent;
        if (currentV4LiquidityBefore == 0) {
            // Handle first reinvest case if needed, simpler 1:1 might suffice for POL?
            // Or use the _handleFirstDepositInternal math? For POL, 1:1 might be okay.
            // Let's assume a simple approximation or ratio based on current state if possible
            // uint128 currentTotalShares = positionTotalShares[poolId]; // V2 Style shares
            // Need a robust way to map V4 liq delta to V2 share delta
            // Placeholder: Assume POL shares map 1:1 to V4 liquidity for simplicity in Phase 1
            v2SharesEquivalent = liq;
        } else {
            uint128 currentTotalShares = positionTotalShares[poolId]; // V2 Style shares
            v2SharesEquivalent = FullMath.mulDiv(liq, currentTotalShares, currentV4LiquidityBefore).toUint128();
        }

        positionTotalShares[poolId] += v2SharesEquivalent; // Add V2-style shares
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        // Mint POL shares to this contract address
        FullRangePositions(address(positions)).mint(address(this), tokenId, v2SharesEquivalent);

        // Emit event with the amounts provided by Spot and V4 liquidity added
        emit Reinvested(poolId, liq, use0, use1);

        return v2SharesEquivalent; // Return V2-style shares minted
    }

    /**
     * @notice Gets pool reserves using a pre-fetched sqrt price to avoid redundant reads.
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
            reserve0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liq, false);
            reserve1 = 0;
        } else if (sqrtPriceX96 >= sqrtB) {
            reserve0 = 0; // Added missing assignment
            reserve1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liq, false);
        } else {
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

    /* ───────────────────────────────────────────────────────────
     *                     Helper-math (withdraw)
     * ─────────────────────────────────────────────────────────── */

    /**
     * @dev    Pro-rata math used by withdraw() & emergencyWithdraw():
     *         converts ERC-6909 shares → amounts0/1 and the matching V4-liquidity.
     *
     * @param  totalV4Liquidity     liquidity currently in the position
     * @param  sharesToBurn         ERC-6909 shares to burn
     * @param  reserve0/reserve1    pool token reserves (full-range view)
     * @param  minLockedShares      permanently locked seed shares
     * @param  totalSharesGlobal    total ERC-6909 supply for this pool
     */
    function _calculateWithdrawAmounts(
        uint128 totalV4Liquidity,
        uint256 sharesToBurn,
        uint256 reserve0,
        uint256 reserve1,
        uint256 minLockedShares,
        uint256 totalSharesGlobal
    ) internal pure returns (uint256 amount0, uint256 amount1, uint128 v4LiquidityToWithdraw) {
        if (totalV4Liquidity == 0) revert Errors.PoolNotInitialized(bytes32(0));
        if (sharesToBurn == 0) return (0, 0, 0);

        uint128 locked = uint128(minLockedShares);
        if (locked > totalSharesGlobal) revert Errors.ValidationInvalidInput("locked>total");

        uint128 usableShares = uint128(totalSharesGlobal - locked);
        if (usableShares == 0) revert Errors.InsufficientShares(sharesToBurn, 0);

        v4LiquidityToWithdraw = FullMath.mulDivRoundingUp(totalV4Liquidity, sharesToBurn, usableShares).toUint128();

        amount0 = FullMath.mulDiv(reserve0, v4LiquidityToWithdraw, totalV4Liquidity);
        amount1 = FullMath.mulDiv(reserve1, v4LiquidityToWithdraw, totalV4Liquidity);
    }

    // ────────────────────────────────────────────────────────────────────
    // missing interface method – placeholder to keep compiler happy
    // will be implemented in follow-up PR once strategy is finalised
    function removeLiquidity(PoolId, /*poolId*/ uint128 /*amount*/ )
        external
        override
        nonReentrant
        returns (int256, int256)
    {
        revert("FRLM: removeLiquidity NIY");
    }

    /*────────────────────────── Configuration ──────────────────────────*/

    function setMinPoolBalanceRequired(uint128 _minBalanceRequired) external onlyOwner {
        // Implementation of the function
    }

    /// @notice ERC-6909 total shares issued for a pool-wide tokenId
    function getShares(PoolId poolId) external view override returns (uint256 shares) {
        shares = positions.totalSupply(PoolId.unwrap(poolId));
    }

    /// @notice Uniswap V4 liquidity currently held by the pool-wide position

    /**
     * @dev Lazily mints a full-range NFT for the given pool if it does not yet exist.
     * @param key PoolKey of the pool
     * @param pid PoolId identifier
     * @return id ERC-721 tokenId representing the position
     */
    function _getOrCreatePosition(PoolKey memory key, PoolId pid) internal returns (uint256 id) {
        id = positionTokenId[pid];
        if (id != 0) return id;

        // Mint a zero-liquidity position – actual liquidity will be added later.
        bytes memory actions = abi.encodePacked(
            uint8(0x03), // Actions.MINT_POSITION == 3 (see Actions.sol). Use literal to avoid new import.
            abi.encode(
                key,
                TickMath.minUsableTick(key.tickSpacing),
                TickMath.maxUsableTick(key.tickSpacing),
                uint256(0),
                uint128(0),
                uint128(0),
                address(this),
                bytes("")
            )
        );

        posManager.modifyLiquidities(actions, block.timestamp + 300);
        id = posManager.nextTokenId() - 1;
        positionTokenId[pid] = id;
    }
}
