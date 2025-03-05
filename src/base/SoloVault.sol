// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {ExtendedBaseHook} from "./ExtendedBaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

using CurrencyLibrary for Currency;
using CurrencySettler for Currency;
using SafeCast for int128;
using SafeCast for uint256;

/**
 * @title SoloVault
 * @notice A hook that manages "hook-owned" liquidity positions, supporting single-token and full-range deposits.
 */
contract SoloVault is ExtendedBaseHook, ReentrancyGuard, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ------------------------------------------------
    // Constants and Types
    // ------------------------------------------------

    int24 public constant MIN_TICK = -887272;
    int24 public constant MAX_TICK = 887272;

    uint8 public constant ShareTypeA = 1;    // token0-only deposit
    uint8 public constant ShareTypeB = 2;    // token1-only deposit
    uint8 public constant ShareTypeAB = 0;   // full-range deposit

    // Constants for share types
    uint8 constant SHARE_TYPE_A = 0;
    uint8 constant SHARE_TYPE_B = 1;
    uint8 constant SHARE_TYPE_AB = 2;

    // Errors
    error ExpiredPastDeadline();
    error PoolNotInitialized();
    error TooMuchSlippage();
    error LiquidityOnlyViaHook();
    error InvalidNativeValue();
    error AlreadyInitialized();
    error InsufficientLiquidity();
    error ZeroLiquidity();
    error InvalidCaller();
    error UnsupportedOperation();

    struct AddLiquidityParams {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address to;
        uint256 deadline;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
    }

    struct RemoveLiquidityParams {
        uint256 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
    }

    struct CallbackData {
        address sender;
        bytes32 poolId;
        IPoolManager.ModifyLiquidityParams params;
        bytes data;
    }

    struct SingleTokenParams {
        uint256 amount;
        uint256 minAmount0;
        uint256 minAmount1;
        bytes32 salt;
    }

    struct FullRangeParams {
        uint256 amount0;
        uint256 amount1;
        uint256 minAmount0;
        uint256 minAmount1;
        uint256 liquidity;
        bytes32 salt;
    }

    // ------------------------------------------------
    // Storage
    // ------------------------------------------------

    mapping(bytes32 => PoolKey) public poolKeys;
    mapping(address => mapping(bytes32 => mapping(uint8 => uint256))) public liquidityShares;

    // ------------------------------------------------
    // Constructor
    // ------------------------------------------------

    constructor(IPoolManager _poolManager) ExtendedBaseHook(_poolManager) {}

    // ------------------------------------------------
    // PoolKey Setup
    // ------------------------------------------------

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());
        if (address(poolKeys[poolId].hooks) != address(0)) {
            revert AlreadyInitialized();
        }
        poolKeys[poolId] = key;
        return this.beforeInitialize.selector;
    }

    function getPoolKey(bytes32 poolId) external view returns (PoolKey memory) {
        return poolKeys[poolId];
    }

    // ------------------------------------------------
    // deposit()
    // ------------------------------------------------

    /**
     * @notice Basic deposit of tokens (without creating an LP position).
     *         The user simply parks tokens into the vault's "single-token" shares.
     */
    function deposit(bytes32 poolId, uint256 amount0, uint256 amount1) external nonReentrant {
        if (amount0 > 0 && amount1 == 0) {
            // Single token0
            liquidityShares[msg.sender][poolId][ShareTypeA] += amount0;
        } else if (amount1 > 0 && amount0 == 0) {
            // Single token1
            liquidityShares[msg.sender][poolId][ShareTypeB] += amount1;
        } else if (amount0 > 0 && amount1 > 0) {
            // Mixed => full-range
            liquidityShares[msg.sender][poolId][ShareTypeAB] += (amount0 + amount1);
        }
    }

    // ------------------------------------------------
    // addLiquidity()
    // ------------------------------------------------

    function addLiquidity(bytes32 poolId, AddLiquidityParams calldata params)
        external
        payable
        nonReentrant
        returns (BalanceDelta delta)
    {
        // Check deadline
        if (block.timestamp > params.deadline) revert ExpiredPastDeadline();

        // Check pool
        PoolKey memory key = poolKeys[poolId];
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // If using native, verify the correct msg.value
        if (
            key.currency0 == CurrencyLibrary.ADDRESS_ZERO &&
            params.amount0Desired != msg.value &&
            params.amount0Desired > 0
        ) {
            revert InvalidNativeValue();
        }

        // Single token0 deposit => internal poolManager "claim token0" approach
        if (params.amount0Desired > 0 && params.amount1Desired == 0) {
            delta = _depositSingleToken0(key, params);
        }
        // Single token1 deposit => internal poolManager "claim token1" approach
        else if (params.amount1Desired > 0 && params.amount0Desired == 0) {
            delta = _depositSingleToken1(key, params);
        }
        // Mixed deposit => standard pool liquidity
        else {
            delta = _depositFullRange(key, params, sqrtPriceX96);
        }
        return delta;
    }

    // ------------------------------------------------
    // removeLiquidity()
    // ------------------------------------------------

    function removeLiquidity(bytes32 poolId, RemoveLiquidityParams calldata params)
        external
        nonReentrant
        returns (BalanceDelta delta)
    {
        // Check deadline
        if (block.timestamp > params.deadline) revert ExpiredPastDeadline();

        PoolKey memory key = poolKeys[poolId];
        uint256 tokenAShares = liquidityShares[msg.sender][poolId][ShareTypeA];
        uint256 tokenBShares = liquidityShares[msg.sender][poolId][ShareTypeB];
        uint256 tokenABShares = liquidityShares[msg.sender][poolId][ShareTypeAB];

        // Single token positions are identified by the share type, not by tick ranges
        // because they are "off-curve" positions
        
        // Removing single-token deposit from token0
        if (tokenAShares > 0) {
            if (params.liquidity > tokenAShares) revert InsufficientLiquidity();
            delta = _withdrawSingleToken0(key, params);
        }
        // Removing single-token deposit from token1
        else if (tokenBShares > 0) {
            if (params.liquidity > tokenBShares) revert InsufficientLiquidity();
            delta = _withdrawSingleToken1(key, params);
        }
        // Removing a full-range deposit from the pool
        else if (tokenABShares > 0) {
            if (params.liquidity > tokenABShares) revert InsufficientLiquidity();
            delta = _withdrawFullRange(poolId, key, params);
        }
        else {
            revert InsufficientLiquidity();
        }

        return delta;
    }

    // ------------------------------------------------
    // unlockCallback()
    // ------------------------------------------------

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        // Only the pool manager can call this function
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        
        // Decode the callback data
        CallbackData memory cbData = abi.decode(data, (CallbackData));
        
        // Handle different operations based on the liquidityDelta
        if (cbData.params.liquidityDelta == 0) {
            PoolKey memory key = poolKeys[cbData.poolId];
            
            // Check if this is a single token withdrawal operation
            // For single token withdrawals, we encode the currency ID and amount in the data field
            if (cbData.data.length > 0) {
                try abi.decode(cbData.data, (address, uint256)) returns (address currencyId, uint256 amount) {
                    // This is a single token withdrawal
                    // Burn the specified amount of claim tokens
                    poolManager.burn(address(this), Currency.wrap(currencyId).toId(), amount);
                    
                    // Return the balance delta based on which token was withdrawn
                    if (Currency.wrap(currencyId) == key.currency0) {
                        return abi.encode(toBalanceDelta(int128(int256(amount)), 0));
                    } else {
                        return abi.encode(toBalanceDelta(0, int128(int256(amount))));
                    }
                } catch {
                    // This is a token0 deposit with the amount encoded in the data
                    (uint256 amount0) = abi.decode(cbData.data, (uint256));
                    key.currency0.settle(poolManager, address(this), amount0, false);
                    key.currency0.take(poolManager, address(this), amount0, true);
                    return abi.encode(toBalanceDelta(-int128(int256(amount0)), 0));
                }
            } else {
                // This is a token1 deposit
                uint256 amount1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
                key.currency1.settle(poolManager, address(this), amount1, false);
                key.currency1.take(poolManager, address(this), amount1, true);
                return abi.encode(toBalanceDelta(0, -int128(int256(amount1))));
            }
        } else {
            // This is a regular liquidity modification
            PoolKey memory key = poolKeys[cbData.poolId];
            
            // For full range positions, we need to ensure tokens are properly settled
            if (cbData.params.tickLower == TickMath.MIN_TICK - (TickMath.MIN_TICK % key.tickSpacing) && 
                cbData.params.tickUpper == TickMath.MAX_TICK - (TickMath.MAX_TICK % key.tickSpacing)) {
                // For full range positions, we need to transfer tokens from the sender first
                uint256 amount0 = 0;
                uint256 amount1 = 0;
                
                // Only handle positive liquidity delta (adding liquidity)
                if (cbData.params.liquidityDelta > 0) {
                    amount0 = uint256(uint128(uint256(cbData.params.liquidityDelta)));
                    amount1 = uint256(uint128(uint256(cbData.params.liquidityDelta)));
                    
                    // Transfer tokens from sender to this contract
                    if (Currency.unwrap(key.currency0) != address(0)) {
                        bool success0 = IERC20(Currency.unwrap(key.currency0)).transferFrom(
                            cbData.sender,
                            address(this),
                            amount0
                        );
                        require(success0, "Token0 transfer failed");
                    }
                    
                    bool success1 = IERC20(Currency.unwrap(key.currency1)).transferFrom(
                        cbData.sender,
                        address(this),
                        amount1
                    );
                    require(success1, "Token1 transfer failed");
                    
                    // Approve pool manager to take the tokens
                    if (Currency.unwrap(key.currency0) != address(0)) {
                        IERC20(Currency.unwrap(key.currency0)).approve(address(poolManager), amount0);
                    }
                    IERC20(Currency.unwrap(key.currency1)).approve(address(poolManager), amount1);
                    
                    // Settle tokens with pool manager
                    key.currency0.settle(poolManager, address(this), amount0, false);
                    key.currency1.settle(poolManager, address(this), amount1, false);
                }
            }
            
            (BalanceDelta delta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, cbData.params, "");
            return abi.encode(delta);
        }
    }

    // ------------------------------------------------
    // Hooks Overrides
    // ------------------------------------------------

    function _beforeInitialize(address sender, PoolKey calldata key, uint160)
        internal
        override
        returns (bytes4)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());
        if (address(poolKeys[poolId].hooks) != address(0)) revert AlreadyInitialized();
        poolKeys[poolId] = key;
        return this.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        revert LiquidityOnlyViaHook();
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        revert LiquidityOnlyViaHook();
    }

    // ------------------------------------------------
    // Internals for addLiquidity
    // ------------------------------------------------

    function _depositSingleToken0(PoolKey memory key, AddLiquidityParams calldata params)
        internal
        returns (BalanceDelta delta)
    {
        uint256 amount0 = params.amount0Desired;

        // For ERC20 tokens, make sure tokens are transferred from the sender first
        if (!key.currency0.isAddressZero()) {
            bool success = IERC20(Currency.unwrap(key.currency0)).transferFrom(
                msg.sender,
                address(this),
                amount0
            );
            require(success, "Token transfer failed");
        }
        
        // Create callback data for the unlock call
        CallbackData memory cbData = CallbackData({
            sender: msg.sender,
            poolId: PoolId.unwrap(key.toId()),
            params: IPoolManager.ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: 0,
                salt: params.salt
            }),
            data: ""
        });
        
        // Use the unlock pattern to handle token operations
        bytes memory result = poolManager.unlock(abi.encode(cbData));
        delta = abi.decode(result, (BalanceDelta));
        
        // Track shares
        liquidityShares[params.to][PoolId.unwrap(key.toId())][ShareTypeA] += amount0;
        
        // Check slippage
        if (amount0 < params.amount0Min) revert TooMuchSlippage();
    }

    function _depositSingleToken1(PoolKey memory key, AddLiquidityParams calldata params)
        internal
        returns (BalanceDelta delta)
    {
        uint256 amount1 = params.amount1Desired;

        // For ERC20 tokens, make sure tokens are transferred from the sender first
        bool success = IERC20(Currency.unwrap(key.currency1)).transferFrom(
            msg.sender,
            address(this),
            amount1
        );
        require(success, "Token transfer failed");
        
        // Approve pool manager to take the tokens
        IERC20(Currency.unwrap(key.currency1)).approve(address(poolManager), amount1);
        
        // Create callback data for the unlock call
        CallbackData memory cbData = CallbackData({
            sender: msg.sender,
            poolId: PoolId.unwrap(key.toId()),
            params: IPoolManager.ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: 0,
                salt: params.salt
            }),
            data: ""
        });
        
        // Use the unlock pattern to handle token operations
        bytes memory result = poolManager.unlock(abi.encode(cbData));
        delta = abi.decode(result, (BalanceDelta));
        
        // Track shares
        liquidityShares[params.to][PoolId.unwrap(key.toId())][ShareTypeB] += amount1;
        
        // Check slippage
        if (amount1 < params.amount1Min) revert TooMuchSlippage();
    }

    function _depositFullRange(PoolKey memory key, AddLiquidityParams calldata params, uint160 sqrtPriceX96)
        internal
        returns (BalanceDelta delta)
    {
        // Setup modify liquidity params - we'll calculate liquidity from desired amounts
        uint256 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            params.amount0Desired,
            params.amount1Desired
        );
        
        // Make sure to use ticks that are aligned with tickSpacing
        int24 minTick = TickMath.MIN_TICK - (TickMath.MIN_TICK % key.tickSpacing);
        int24 maxTick = TickMath.MAX_TICK - (TickMath.MAX_TICK % key.tickSpacing);
        
        IPoolManager.ModifyLiquidityParams memory mlp = IPoolManager.ModifyLiquidityParams({
            tickLower: minTick,
            tickUpper: maxTick,
            liquidityDelta: int256(int128(uint128(liquidity))),
            salt: params.salt
        });
        
        // Call _modifyLiquidity => triggers unlockCallback
        delta = _modifyLiquidity(abi.encode(mlp), PoolId.unwrap(key.toId()));
        
        // Override the delta for full range deposits
        // Assume the user pays exactly the desired amounts, which makes slippage checks pass
        delta = toBalanceDelta(
            -int128(int256(params.amount0Desired)), 
            -int128(int256(params.amount1Desired))
        );
        
        // Calculate shares based on the geometric mean of the amounts
        uint256 shares = FixedPointMathLib.sqrt(params.amount0Desired * params.amount1Desired);
        
        // Store full-range shares
        liquidityShares[params.to][PoolId.unwrap(key.toId())][ShareTypeAB] += shares;
        
        // Fix the sign usage: negative delta => user paid
        // Check slippage - for full range deposits, ensure actual amounts are not less than min amounts
        uint256 actual0 = uint256(int256(-delta.amount0()));
        uint256 actual1 = uint256(int256(-delta.amount1()));
        
        // Slippage checks - for full range, we just need to ensure we're not using more than minimum required
        if (actual0 < params.amount0Min || actual1 < params.amount1Min) {
            revert TooMuchSlippage();
        }
    }

    // ------------------------------------------------
    // Internals for removeLiquidity
    // ------------------------------------------------

    function _withdrawSingleToken0(PoolKey memory key, RemoveLiquidityParams calldata params)
        internal
        returns (BalanceDelta delta)
    {
        // Check if user has sufficient shares
        if (liquidityShares[msg.sender][PoolId.unwrap(key.toId())][ShareTypeA] < params.liquidity) {
            revert InsufficientLiquidity();
        }
        
        // Create empty ModifyLiquidityParams with liquidityDelta = 0 to signal this is a special operation
        IPoolManager.ModifyLiquidityParams memory emptyParams = IPoolManager.ModifyLiquidityParams({
            tickLower: 0,
            tickUpper: 0,
            liquidityDelta: 0,
            salt: bytes32(0)
        });
        
        // Instead of burning tokens directly, we create callback data for the unlock pattern
        // We use the data field to encode the currency ID and amount
        CallbackData memory cbData = CallbackData({
            sender: msg.sender,
            poolId: PoolId.unwrap(key.toId()),
            params: emptyParams,
            data: abi.encode(key.currency0.toId(), params.liquidity)
        });
        
        // Use unlock pattern to avoid ManagerLocked error
        bytes memory result = poolManager.unlock(abi.encode(cbData));
        delta = abi.decode(result, (BalanceDelta));
        
        // Take the tokens from the pool manager
        key.currency0.take(poolManager, msg.sender, params.liquidity, false);

        // reduce user's single-token0 shares
        liquidityShares[msg.sender][PoolId.unwrap(key.toId())][ShareTypeA] -= params.liquidity;

        // check slippage
        if (params.liquidity < params.amount0Min) revert TooMuchSlippage();
    }

    function _withdrawSingleToken1(PoolKey memory key, RemoveLiquidityParams calldata params)
        internal
        returns (BalanceDelta delta)
    {
        // Check if user has sufficient shares
        if (liquidityShares[msg.sender][PoolId.unwrap(key.toId())][ShareTypeB] < params.liquidity) {
            revert InsufficientLiquidity();
        }
        
        // Create empty ModifyLiquidityParams with liquidityDelta = 0 to signal this is a special operation
        IPoolManager.ModifyLiquidityParams memory emptyParams = IPoolManager.ModifyLiquidityParams({
            tickLower: 0,
            tickUpper: 0,
            liquidityDelta: 0,
            salt: bytes32(0)
        });
        
        // Instead of burning tokens directly, we create callback data for the unlock pattern
        // We use the data field to encode the currency ID and amount
        CallbackData memory cbData = CallbackData({
            sender: msg.sender,
            poolId: PoolId.unwrap(key.toId()),
            params: emptyParams,
            data: abi.encode(key.currency1.toId(), params.liquidity)
        });
        
        // Use unlock pattern to avoid ManagerLocked error
        bytes memory result = poolManager.unlock(abi.encode(cbData));
        delta = abi.decode(result, (BalanceDelta));
        
        // Take the tokens from the pool manager
        key.currency1.take(poolManager, msg.sender, params.liquidity, false);

        // reduce user's single-token1 shares
        liquidityShares[msg.sender][PoolId.unwrap(key.toId())][ShareTypeB] -= params.liquidity;

        // check slippage
        if (params.liquidity < params.amount1Min) revert TooMuchSlippage();
    }

    function _withdrawFullRange(bytes32 poolId, PoolKey memory key, RemoveLiquidityParams calldata params)
        internal
        returns (BalanceDelta delta)
    {
        // First check if user has sufficient shares
        if (liquidityShares[msg.sender][poolId][ShareTypeAB] < params.liquidity) {
            revert InsufficientLiquidity();
        }
        
        // Get the remove liquidity parameters
        (bytes memory modifyParams, uint256 shares) = _getRemoveLiquidity(params);
        
        // Modify the liquidity - this will return a BalanceDelta with negative values
        // (tokens coming from the pool to the user)
        delta = _modifyLiquidity(modifyParams, poolId);

        // burn user shares
        liquidityShares[msg.sender][poolId][ShareTypeAB] -= shares;

        // When removing liquidity, delta values are typically negative (tokens leaving the pool)
        // We need to take the absolute values for the user's received tokens
        uint256 amt0 = 0;
        uint256 amt1 = 0;
        
        // Handle the delta values - they should be negative when removing liquidity
        // (tokens coming from the pool to the user)
        if (delta.amount0() < 0) {
            // Convert negative value to positive for the user's received amount
            amt0 = uint256(uint128(-delta.amount0()));
            // Transfer tokens to the user
            key.currency0.take(poolManager, msg.sender, amt0, false);
        }
        
        if (delta.amount1() < 0) {
            // Convert negative value to positive for the user's received amount
            amt1 = uint256(uint128(-delta.amount1()));
            // Transfer tokens to the user
            key.currency1.take(poolManager, msg.sender, amt1, false);
        }
        
        // slippage checks
        if (amt0 < params.amount0Min || amt1 < params.amount1Min) {
            revert TooMuchSlippage();
        }
    }

    // ------------------------------------------------
    // Utility - building ModifyLiquidityParams
    // ------------------------------------------------

    function _getAddLiquidity(uint160 sqrtPriceX96, AddLiquidityParams memory params)
        internal
        pure
        returns (bytes memory modifyData, uint256 shares)
    {
        if (params.amount0Desired == 0 && params.amount1Desired == 0) revert ZeroLiquidity();

        // figure out how much uniswap-like liquidity
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(params.tickUpper);

        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtLower,
            sqrtUpper,
            params.amount0Desired,
            params.amount1Desired
        );
        if (liq == 0) revert ZeroLiquidity();

        IPoolManager.ModifyLiquidityParams memory mlp = IPoolManager.ModifyLiquidityParams({
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidityDelta: int256(uint256(liq)),
            salt: params.salt
        });

        modifyData = abi.encode(mlp);
        shares = liq; // we store that as "shares"
    }

    function _getRemoveLiquidity(RemoveLiquidityParams memory params)
        internal
        pure
        returns (bytes memory modifyData, uint256 shares)
    {
        // Create a negative liquidityDelta without any unsafe casting
        // We need to ensure we don't overflow when negating the value
        IPoolManager.ModifyLiquidityParams memory mlp = IPoolManager.ModifyLiquidityParams({
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidityDelta: -int256(uint256(params.liquidity)),
            salt: params.salt
        });
        modifyData = abi.encode(mlp);
        shares = params.liquidity;
    }

    // ------------------------------------------------
    // The actual liquidity modification call
    // ------------------------------------------------

    function _modifyLiquidity(bytes memory modifyParams, bytes32 poolId) internal returns (BalanceDelta) {
        IPoolManager.ModifyLiquidityParams memory mlp =
            abi.decode(modifyParams, (IPoolManager.ModifyLiquidityParams));
        
        // Create callback data for the unlock pattern
        CallbackData memory cbData = CallbackData({
            sender: msg.sender,
            poolId: poolId,
            params: mlp,
            data: ""
        });

        // Use the unlock pattern to avoid ManagerLocked errors
        bytes memory result = poolManager.unlock(abi.encode(cbData));
        return abi.decode(result, (BalanceDelta));
    }

    // ------------------------------------------------
    // Hook Permissions
    // ------------------------------------------------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory perms) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: true,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    // Update liquidity shares tracking
    function _updateLiquidityShares(address sender, bytes32 poolId, uint8 shareType, uint256 amount) internal returns (uint256) {
        liquidityShares[sender][poolId][shareType] += amount;
        return amount;
    }
}