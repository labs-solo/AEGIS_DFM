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
// import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol"; // deprecated
// import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol"; // deprecated

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
import {ExtendedPositionManager} from "./ExtendedPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

using SafeCast for uint256;
using SafeCast for int256;
using PoolIdLibrary for PoolKey;
using CurrencyLibrary for Currency;

/**
 * @title FullRangeLiquidityManager
 * @notice Manages full-range liquidity positions across multiple pools
 * @dev Phase 1: POL-only, restricted deposits/withdrawals. Core logic kept for Phase 2.
 */
contract FullRangeLiquidityManager is Owned, ReentrancyGuard, IFullRangeLiquidityManager {
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

    /// @dev Pool keys for lookups
    mapping(PoolId => PoolKey) private _poolKeys;

    /// @dev Address authorized to store pool keys (typically the associated hook contract)
    /// Set by the owner via setAuthorizedHookAddress.
    address public authorizedHookAddress_;

    /// @dev NFT id per pool
    mapping(PoolId => uint256) public positionTokenId;

    /// @dev Tracks whether unlimited Permit2 allowance has been set for a token.
    mapping(address => bool) private _permit2Approved;

    /// @notice Expose getter expected by interface
    function authorizedHookAddress() external view override returns (address) {
        return authorizedHookAddress_;
    }

    /* ────────── Modifiers ────────── */

    /**
     * @dev Governance gate.
     *
     *  - Deployer/owner (traditional governance) **or**
     *  - `authorizedHookAddress` (Spot hook) may call the guarded function.
     */
    modifier onlyGovernance() {
        address gov = address(policyManager) != address(0) ? policyManager.getSoloGovernance() : owner;
        if (msg.sender != gov && msg.sender != authorizedHookAddress_) {
            revert Errors.AccessOnlyGovernance(msg.sender);
        }
        _;
    }

    /// @dev Restrict to the hook once its address is set.
    modifier onlyHook() {
        if (msg.sender != authorizedHookAddress_) revert Errors.AccessNotAuthorized(msg.sender);
        _;
    }

    // ────────────────────────── CONSTANTS ──────────────────────────
    uint128 private constant MIN_LOCKED_SHARES = 1_000;           // seed-liquidity shares
    uint128 private constant MAX_SHARES        = type(uint128).max - 1e18; // hard cap (≈3e38 wei TVL)

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
    // Note: optional events "PoolStateUpdated" and "Reinvested" have been pruned.

    /* ──────────────  Circuit-breaker  ─────────────── */
    bool public paused;
    event Paused(bool state);

    modifier notPaused() {
        require(!paused, "FRLM: paused");
        _;
    }

    /// @notice Owner can pause or un-pause critical flows.
    function setPaused(bool _p) external onlyOwner {
        paused = _p;
        emit Paused(_p);
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
        if (authorizedHookAddress_ != address(0)) revert Errors.HookAddressAlreadySet();
        if (_hookAddress == address(0)) revert Errors.InvalidHookAddress();
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
        if (_poolKeys[poolId].tickSpacing != 0) {
            revert Errors.ValidationInvalidInput("PoolKey already stored");
        }
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
    // getPositionsContract() removed – callers should use the `positions()` public getter instead.

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
        notPaused
        onlyGovernance
        returns (uint256 usableShares, uint256 amount0, uint256 amount1)
    {
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
        if (amount0Desired == 0 && amount1Desired == 0) revert Errors.ZeroAmount(); // Must desire some amount

        PoolKey memory key = _poolKeys[poolId];
        uint160 sqrtPriceX96;
        {
            (, sqrtPriceX96,) = getPositionData(poolId);
            if (sqrtPriceX96 == 0) {
                (sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, poolId);
            }
        }
        uint256 _tokenIdTmp = PoolTokenIdUtils.toTokenId(poolId);
        uint128 totalSharesInternal = uint128(positions.totalSupply(bytes32(_tokenIdTmp)));

        if (sqrtPriceX96 == 0 && totalSharesInternal == 0) {
            revert Errors.ValidationInvalidInput("Pool price is zero");
        }

        // ——— 3) single‐read slot0 and reuse it to compute pool reserves (inlined)
        uint256 reserve0;
        uint256 reserve1;
        {
            // Inline of former getPoolReservesWithPrice()
            PoolKey memory k = key;
            // Compute position key & bail early if no liquidity
            bytes32 posKey = Position.calculatePositionKey(
                address(this),
                TickMath.minUsableTick(k.tickSpacing),
                TickMath.maxUsableTick(k.tickSpacing),
                bytes32(0)
            );
            uint128 liq = StateLibrary.getPositionLiquidity(manager, poolId, posKey);
            if (liq == 0) {
                reserve0 = 0;
                reserve1 = 0;
            } else {
                int24 lower = TickMath.minUsableTick(k.tickSpacing);
                int24 upper = TickMath.maxUsableTick(k.tickSpacing);
                uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
                uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);

                if (sqrtPriceX96 <= sqrtA) {
                    reserve0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liq, false);
                    reserve1 = 0;
                } else if (sqrtPriceX96 >= sqrtB) {
                    reserve0 = 0;
                    reserve1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liq, false);
                } else {
                    reserve0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtB, liq, false);
                    reserve1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, liq, false);
                }
            }
        }

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

        bool created;
        uint256 nftId;
        (nftId, created) = _getOrCreatePosition(key, poolId, v4LiquidityForPM, ethNeeded);

        // If the NFT already existed, simply increase liquidity; otherwise the mint already added it.
        if (!created) {
            posManager.increaseLiquidity{value: ethNeeded}(
                nftId,
                v4LiquidityForPM,
                type(uint128).max,
                type(uint128).max,
                ""
            );
        }

        // Refund excess ETH
        if (msg.value > ethNeeded) {
            uint256 refund = msg.value - ethNeeded;
            if (refund > 0) SafeTransferLib.safeTransferETH(msg.sender, refund);
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
            require(uint256(totalSharesInternal) + shares <= MAX_SHARES, "FRLM: share cap");

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
        // Cap shares to MAX_SHARES to ensure bounded supply
        require(minLiq128 + usableV2Shares <= MAX_SHARES, "FRLM: share cap");

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
        notPaused
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

        uint256 _tokenIdTmp = PoolTokenIdUtils.toTokenId(poolId);
        uint128 totalShares = uint128(positions.totalSupply(bytes32(_tokenIdTmp)));

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
     * @dev legacy unlockCallback removed – PositionManager now handles liquidity changes.
     */

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
        notPaused
        returns (uint128 mintedShares)
    {
        // ─── validations ───
        if (liq == 0) revert Errors.ZeroAmount();
        PoolKey memory key = _poolKeys[poolId];
        if (key.tickSpacing == 0) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));

        // ─── pull tokens from caller → this contract ───
        _takeTokens(key.currency0, use0);
        _takeTokens(key.currency1, use1);

        // ─── ensure Permit2 approvals for ERC20 tokens ───
        if (!key.currency0.isAddressZero()) _ensurePermit2Approval(Currency.unwrap(key.currency0));
        if (!key.currency1.isAddressZero()) _ensurePermit2Approval(Currency.unwrap(key.currency1));

        // ─── mint or fetch the pool-wide NFT ───
        (uint256 nftId,) = _getOrCreatePosition(key, poolId, 0, 0);

        // ─── increase liquidity on the PositionManager ───
        posManager.increaseLiquidity(
            nftId,
            liq,
            type(uint128).max,
            type(uint128).max,
            ""
        );

        // ─── mint ERC-6909 shares to POL treasury (this contract) ───
        _mintShares(poolId, liq);

        return liq;
    }

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
        if (sharesToBurn > usableShares) revert Errors.InsufficientShares(sharesToBurn, usableShares);
        if (usableShares == 0) revert Errors.InsufficientShares(sharesToBurn, 0);

        v4LiquidityToWithdraw = FullMath.mulDivRoundingUp(totalV4Liquidity, sharesToBurn, usableShares).toUint128();

        amount0 = FullMath.mulDiv(reserve0, v4LiquidityToWithdraw, totalV4Liquidity);
        amount1 = FullMath.mulDiv(reserve1, v4LiquidityToWithdraw, totalV4Liquidity);
    }

    /*────────────────────────── Configuration ──────────────────────────*/

    /// @notice ERC-6909 total shares issued for a pool-wide tokenId
    function getShares(PoolId poolId) external view override returns (uint256) {
        return positions.totalSupply(PoolId.unwrap(poolId));
    }

    /// @notice Compatibility getter replacing the old public mapping.
    ///         Returns the total ERC-6909 shares issued for the pool-wide tokenId.
    function positionTotalShares(PoolId poolId) external view override returns (uint128) {
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        return uint128(positions.totalSupply(bytes32(tokenId)));
    }

    /**
     * @dev Lazily creates a full-range position NFT if not existent, optionally
     *      minting `liquidityDesired` in the same transaction to save gas.
     *      Returns the tokenId **and** whether it was freshly minted.
     *      Safe – we grant Permit2 approvals beforehand.
     */
    function _getOrCreatePosition(
        PoolKey memory key,
        PoolId      pid,
        uint128     liquidityDesired,
        uint256     ethNeeded
    ) internal returns (uint256 id, bool created) {
        id = positionTokenId[pid];
        if (id != 0) {
            // already exists – nothing to mint
            created = false;
            return (id, created);
        }

        created = true; // we will mint now

        // ------------------------------------------------------------------
        // Encode router call: single MINT_POSITION with full-range bounds
        // ------------------------------------------------------------------
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        // params[0] – MINT_POSITION arguments (matches IPositionManager spec)
        // Note: `liquidityDesired` is already a uint128, so we pass it **without**
        // widening to uint256. This avoids ABI-decoder truncation that triggered
        // a SafeCastOverflow revert when v4-core attempted to down-cast the
        // value back to uint128. (why safe: value ≤ type(uint128).max)
        params[0] = abi.encode(
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            liquidityDesired,
            type(uint128).max, // amount0Max (slippage handled in PM)
            type(uint128).max, // amount1Max
            address(this),
            bytes("")
        );

        // params[1] – settle any resulting deltas for the pair
        params[1] = abi.encode(key.currency0, key.currency1);

        // Approve tokens via Permit2 (no-op when allowance already max)
        _ensurePermit2Approval(Currency.unwrap(key.currency0));
        _ensurePermit2Approval(Currency.unwrap(key.currency1));

        bytes memory unlockData = abi.encode(actions, params);
        posManager.modifyLiquidities{value: ethNeeded}(unlockData, block.timestamp + 300);

        id = posManager.nextTokenId() - 1; // PositionManager auto-increments
        positionTokenId[pid] = id; // cache for future calls
        return (id, created);
    }

    /// @dev Grant unlimited Permit2 allowance for a token if not already set.
    ///      Safe to call multiple times; cheap when allowance is already maxed.
    /// @param token The ERC20 token address (Currency.unwrap(...))
    function _ensurePermit2Approval(address token) internal {
        if (token == address(0)) return;
        if (_permit2Approved[token]) return;                       // SLOAD ≈ 100 gas

        // First, give Permit2 unlimited allowance on the ERC20 itself so it can pull funds
        // Safe: one-time max approval, identical to Uniswap v4 PositionManager pattern
        SafeTransferLib.safeApprove(ERC20(token), address(posManager.permit2()), type(uint256).max);

        // Then, inside Permit2 allow the PositionManager to spend on our behalf (also unlimited)
        IAllowanceTransfer permit = posManager.permit2();
        permit.approve(token, address(posManager), type(uint160).max, type(uint48).max);

        _permit2Approved[token] = true;                            // mark approved
    }

    /// @dev Pull `amount` of `currency` from the caller into this contract. Supports native ETH.
    function _takeTokens(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            require(msg.value >= amount, "FRLM: insufficient ETH sent");
            uint256 refund = msg.value - amount;
            if (refund > 0) SafeTransferLib.safeTransferETH(msg.sender, refund);
        } else {
            SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(currency)), msg.sender, address(this), amount);
        }
    }

    /// @dev Internal mint of ERC-6909 shares to `this` & update accounting.
    function _mintShares(PoolId pid, uint128 shares) internal {
        if (shares == 0) return;
        uint256 tokenId = PoolTokenIdUtils.toTokenId(pid);
        unchecked {
            require(
                positions.totalSupply(bytes32(tokenId)) + shares <= MAX_SHARES,
                "FRLM: share cap"
            );
        }
        FullRangePositions(address(positions)).mint(address(this), tokenId, shares);
    }

    /// @notice Emergency escape hatch – owner can pull the NFT out of the manager.
    function emergencyPullNFT(PoolId pid, address to) external onlyOwner {
        if (to == address(0)) revert Errors.ZeroDestination();
        uint256 nftId = positionTokenId[pid];
        require(nftId != 0, "not-minted");
        posManager.safeTransferFrom(address(this), to, nftId);
    }

    /// @notice Uniswap V4 liquidity currently held by the pool-wide position

    uint256[50] private __gap;
}
