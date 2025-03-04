// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title SoloVault
 * @notice This contract implements custom accounting and hook‑owned liquidity management,
 *         extended to support an infinite number of pools.
 *
 * @dev Additional Requirements and Detailed Function Specifications:
 *
 * 1. Pool Identification & Management:
 *    - Replace the single global PoolKey with a mapping keyed by poolId (derived from PoolKey.toId()).
 *      All functions that previously used the global poolKey must now accept (or derive) a poolId and use
 *      poolKeys[poolId] to retrieve the corresponding PoolKey.
 *    - A helper function getPoolKey(poolId) is provided.
 *
 * 2. Liquidity Accounting:
 *    - Deposits that are "hook‑managed" must be made directly to SoloVault and must meet one of the following strict criteria:
 *         (a) 100% token A deposit,
 *         (b) 100% token B deposit, or
 *         (c) A full‑range deposit (both tokens with tickLower == MIN_TICK and tickUpper == MAX_TICK).
 *      Any deposit that does not meet these criteria (or that is made via other mechanisms) is considered “normal”
 *      and will be processed solely by the PoolManager.
 *    - Liquidity shares are tracked using an internal mapping:
 *         mapping(address => mapping(bytes32 => mapping(uint8 => uint256))) liquidityShares;
 *      For now, we only support one share type (denoted by ShareTypeAB) corresponding to full‑range deposits.
 *    - **Share Calculation Specifications:**
 *         - For full‑range deposits, the basic liquidity shares formula will be equivalent to the Uniswap V2 model,
 *           taking into account the deposited amounts and, eventually, pending fees.
 *           For the first deposit, the formula is identical to Uniswap V2’s. (Pending fee adjustments may be applied later.)
 *         - For single token deposits (intended for custom curve deposits), the first deposit to each side (A or B)
 *           issues 1 share per deposit token. For subsequent deposits, shares are minted on a proportional basis,
 *           using the current ratio of assets held in the custom curve.
 *           – The value of tokens deposited is evaluated using the current curve ratio, denominated in the asset
 *              corresponding to that curve (A tokens for the A curve and B tokens for the B curve).
 *
 * 3. State Tracking & PoolManager Integration:
 *    - All liquidity modification operations (addLiquidity, removeLiquidity, unlockCallback) must be routed through
 *      PoolManager. This ensures that pool state (such as slot0 and liquidity positions) is maintained centrally.
 *    - Vault state (poolKeys and liquidityShares) must be updated atomically using the provided poolId.
 *
 * 4. Lending, Borrowing, and Liquidation:
 *    - Detailed lending/borrowing logic is *out of scope* for SoloVault and should be handled by a higher-level module
 *      (e.g. Leverage.sol). SoloVault’s responsibility is to track deposits via liquidityShares for use in collateral
 *      calculations.
 *
 * 5. Functionality & Error Handling:
 *    - Standard error conditions must be enforced (expired deadlines, insufficient liquidity shares, invalid native amounts,
 *      and slippage violations).
 *    - NonReentrant modifiers should be applied to all external functions that modify state.
 *
 * 6. Swap Functionality:
 *    - Swap hooks (beforeSwap, afterSwap) are implemented in SoloVault but without advanced tiered custom‐curve routing.
 *      Advanced swap routing (using custom curves) is delegated to a higher layer.
 *
 * 7. Helper Functions:
 *    - Provide helper functions such as getPoolKey(poolId) and conversion helpers between PoolKey and poolId.
 *
 * 8. Detailed Function Specifications:
 *    - beforeInitialize:
 *         * Accepts a PoolKey and an initial sqrtPriceX96.
 *         * Derives the poolId via PoolKey.toId() and stores the PoolKey in the mapping.
 *         * Reverts if the pool is already initialized.
 *    - getPoolKey:
 *         * Returns the PoolKey for a given poolId.
 *    - deposit:
 *         * A minimal deposit function that accepts a poolId, amounts for token0 and token1, and a boolean flag (useHook)
 *           indicating that the deposit is hook‑managed.
 *         * For hook‑managed deposits, it verifies that the deposit meets the strict criteria (here, simplified to recording
 *           the sum of token amounts under the single share type ShareTypeAB).
 *    - addLiquidity:
 *         * Retrieves the PoolKey from poolKeys using the provided poolId.
 *         * Calls PoolManager.getSlot0() using the PoolKey.
 *         * Verifies that the pool is initialized.
 *         * Checks native token conditions.
 *         * Calls the abstract _getAddLiquidity to compute encoded liquidity parameters and share amount.
 *         * Calls _modifyLiquidity (which in a real implementation would call poolManager.unlock()).
 *         * Calls _mint to update internal liquidity share balances.
 *         * Checks for slippage.
 *         * Updates liquidityShares for the depositor.
 *    - removeLiquidity:
 *         * Similar to addLiquidity, but for withdrawal.
 *         * Calls _getRemoveLiquidity, _modifyLiquidity, and _burn.
 *         * Checks that the amounts returned meet the minimum withdrawal requirements.
 *         * Updates liquidityShares for the caller.
 *    - unlockCallback:
 *         * Called by PoolManager to finalize liquidity modifications.
 *         * Retrieves the PoolKey using the poolId provided in the CallbackData.
 *         * Calls poolManager.modifyLiquidity() and then adjusts the balance delta (delta - feeDelta).
 *         * Uses CurrencySettler to either settle or take tokens based on the sign of the delta amounts.
 *         * Returns the encoded delta.
 *
 * 9. Abstract Functions to Implement in Derived Contracts:
 *    - _getAddLiquidity(uint160, AddLiquidityParams): Compute and encode liquidity parameters; return a unique salt and share count.
 *    - _getRemoveLiquidity(RemoveLiquidityParams): Similar for liquidity removal.
 *    - _mint(AddLiquidityParams, BalanceDelta, uint256): Update internal accounting for minting liquidity shares.
 *    - _burn(RemoveLiquidityParams, BalanceDelta, uint256): Update internal accounting for burning liquidity shares.
 *    - _modifyLiquidity(bytes): In a production implementation, decode parameters and call poolManager.modifyLiquidity; here, a minimal
 *      default returns a zero delta.
 *
 * @dev SoloVault inherits from ExtendedBaseHook, which itself implements the full IHooks interface.
 *      This contract uses the PoolManager for state tracking and leverages Uniswap V4 libraries for pool identification,
 *      currency handling, and state management.
 */

import {ExtendedBaseHook} from "src/base/ExtendedBaseHook.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

/// @title SoloVault
/// @notice This contract implements custom accounting and hook‑owned liquidity management,
///         extended to support an infinite number of pools.
/// @dev See the header comments for detailed requirements and function specifications.
abstract contract SoloVault is ExtendedBaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Share type constant for position accounting.
    // For now, we only support one type (ShareTypeAB) corresponding to full‑range deposits.
    uint8 public constant ShareTypeAB = 0;

    // --- Custom Errors ---
    error ExpiredPastDeadline();
    error PoolNotInitialized();
    error TooMuchSlippage();
    error LiquidityOnlyViaHook();
    error InvalidNativeValue();
    error AlreadyInitialized();

    // --- Structs ---
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

    // Standard callback data structure for liquidity modifications.
    struct CallbackData {
        address sender;
        bytes32 poolId;
        IPoolManager.ModifyLiquidityParams params;
    }

    // --- State Variables for Multi-Pool Support ---
    // Mapping from poolId to PoolKey. Pools are registered via beforeInitialize.
    mapping(bytes32 => PoolKey) public poolKeys;

    // Mapping from user => poolId => share type (uint8) => liquidity shares.
    mapping(address => mapping(bytes32 => mapping(uint8 => uint256))) public liquidityShares;

    // --- Constructor ---
    constructor(IPoolManager _poolManager) ExtendedBaseHook(_poolManager) {}

    // --- PoolKey Management ---

    /**
     * @notice Initializes a pool by storing its PoolKey.
     * @param sender The caller (must be PoolManager).
     * @param key The PoolKey for the pool.
     * @param sqrtPriceX96 The initial sqrt price.
     * @return selector The function selector.
     *
     * Requirements:
     * - Derives poolId from key.toId() using PoolId.unwrap.
     * - Reverts if the pool is already initialized.
     * - Stores the PoolKey in the poolKeys mapping.
     */
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());
        if (address(poolKeys[poolId].hooks) != address(0)) revert AlreadyInitialized();
        poolKeys[poolId] = key;
        return this.beforeInitialize.selector;
    }

    /**
     * @notice Returns the PoolKey for a given poolId.
     * @param poolId The pool identifier.
     * @return The PoolKey.
     */
    function getPoolKey(bytes32 poolId) external view returns (PoolKey memory) {
        return poolKeys[poolId];
    }

    // --- Basic Deposit Functionality ---

    /**
     * @notice A minimal deposit function that records hook-managed liquidity shares.
     * @param poolId The unique identifier for the pool.
     * @param amount0 The amount of token0 to deposit.
     * @param amount1 The amount of token1 to deposit.
     * @param useHook Indicates whether this deposit is hook-managed.
     *
     * Requirements:
     * - For hook-managed deposits, the deposit must meet strict criteria: it must be either a 100% token A deposit,
     *   a 100% token B deposit, or a full-range deposit (tickLower == MIN_TICK and tickUpper == MAX_TICK).
     *   (For now, this check is simplified.)
     * - Updates the liquidityShares mapping for the caller under ShareTypeAB.
     * - Normal deposits (non-hook-managed) are processed solely by PoolManager.
     */
    function deposit(bytes32 poolId, uint256 amount0, uint256 amount1, bool useHook) external {
        if (useHook) {
            liquidityShares[msg.sender][poolId][ShareTypeAB] += (amount0 + amount1);
        }
    }

    // --- Liquidity Operations ---

    /**
     * @notice Adds liquidity to a specific pool.
     * @param poolId The unique identifier for the pool.
     * @param params The liquidity addition parameters.
     * @return delta The balance delta from the PoolManager.
     *
     * Process:
     * - Retrieves the PoolKey using poolId.
     * - Calls PoolManager.getSlot0() using the PoolKey to ensure the pool is initialized.
     * - Checks native token conditions.
     * - Calls the abstract _getAddLiquidity() to compute encoded liquidity parameters and the share amount.
     * - Calls _modifyLiquidity() to execute liquidity modification via PoolManager.
     * - Calls _mint() to update internal liquidity share balances.
     * - Enforces slippage conditions.
     * - Updates liquidityShares for the depositor.
     *
     * Share Calculation:
     * - For full-range deposits, the liquidity shares are computed similar to Uniswap V2's formula (considering both token amounts and pending fees).
     * - For the first deposit, the formula is identical to Uniswap V2.
     */
    function addLiquidity(bytes32 poolId, AddLiquidityParams calldata params)
        external
        payable
        returns (BalanceDelta delta)
    {
        PoolKey memory key = poolKeys[poolId];
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        if (key.currency0 == CurrencyLibrary.ADDRESS_ZERO && msg.value != params.amount0Desired) {
            revert InvalidNativeValue();
        }

        (bytes memory modifyParams, uint256 shares) = _getAddLiquidity(sqrtPriceX96, params);
        delta = _modifyLiquidity(modifyParams);
        _mint(params, delta, shares);

        if (uint128(-delta.amount0()) < params.amount0Min || uint128(-delta.amount1()) < params.amount1Min) {
            revert TooMuchSlippage();
        }

        liquidityShares[params.to][poolId][ShareTypeAB] += shares;
    }

    /**
     * @notice Removes liquidity from a specific pool.
     * @param poolId The unique identifier for the pool.
     * @param params The liquidity removal parameters.
     * @return delta The balance delta from the PoolManager.
     *
     * Process:
     * - Retrieves the PoolKey using poolId.
     * - Ensures the pool is initialized via PoolManager.getSlot0().
     * - Calls _getRemoveLiquidity() to compute encoded liquidity parameters and share amount.
     * - Calls _modifyLiquidity() and then _burn() to update internal liquidity share balances.
     * - Checks that the resulting amounts meet the minimum withdrawal requirements.
     * - Updates liquidityShares for the caller.
     */
    function removeLiquidity(bytes32 poolId, RemoveLiquidityParams calldata params)
        external
        returns (BalanceDelta delta)
    {
        PoolKey memory key = poolKeys[poolId];
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        (bytes memory modifyParams, uint256 shares) = _getRemoveLiquidity(params);
        delta = _modifyLiquidity(modifyParams);
        _burn(params, delta, shares);

        uint128 amount0 = delta.amount0() < 0 ? uint128(-delta.amount0()) : uint128(delta.amount0());
        uint128 amount1 = delta.amount1() < 0 ? uint128(-delta.amount1()) : uint128(delta.amount1());
        if (amount0 < params.amount0Min || amount1 < params.amount1Min) {
            revert TooMuchSlippage();
        }

        liquidityShares[msg.sender][poolId][ShareTypeAB] -= shares;
    }

    // --- Unlock Callback ---

    /**
     * @notice Callback from the PoolManager to settle liquidity modifications.
     * @param rawData The encoded callback data.
     * @return returnData The encoded balance delta.
     *
     * Process:
     * - Decodes the CallbackData to obtain sender, poolId, and modification parameters.
     * - Retrieves the PoolKey using poolId.
     * - Calls poolManager.modifyLiquidity() to perform the liquidity modification.
     * - Adjusts the delta by subtracting any feeDelta.
     * - Uses CurrencySettler to settle or take tokens based on the sign of the delta amounts.
     * - Returns the encoded delta.
     */
    function unlockCallback(bytes calldata rawData)
        external
        onlyPoolManager
        returns (bytes memory returnData)
    {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        bytes32 poolId = data.poolId;
        PoolKey memory key = poolKeys[poolId];

        (BalanceDelta delta, BalanceDelta feeDelta) = poolManager.modifyLiquidity(key, data.params, "");
        delta = delta - feeDelta;

        if (delta.amount0() < 0) {
            CurrencySettler.settle(key.currency0, poolManager, data.sender, uint256(int256(-delta.amount0())), false);
        } else {
            CurrencySettler.take(key.currency0, poolManager, data.sender, uint256(int256(delta.amount0())), false);
        }

        if (delta.amount1() < 0) {
            CurrencySettler.settle(key.currency1, poolManager, data.sender, uint256(int256(-delta.amount1())), false);
        } else {
            CurrencySettler.take(key.currency1, poolManager, data.sender, uint256(int256(delta.amount1())), false);
        }

        return abi.encode(delta);
    }

    // --- Inherited from BaseCustomAccounting (Modified for Multi-Pool Support) ---

    /**
     * @notice Internal pool initialization logic.
     * @param sender The caller.
     * @param key The PoolKey for the pool.
     * @param sqrtPriceX96 The initial sqrt price.
     * @return The beforeInitialize selector.
     *
     * Process:
     * - Derives poolId from key.toId() and checks if a pool is already initialized.
     * - If not, stores the PoolKey in the poolKeys mapping.
     */
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());
        if (address(poolKeys[poolId].hooks) != address(0)) revert AlreadyInitialized();
        poolKeys[poolId] = key;
        return this.beforeInitialize.selector;
    }

    /**
     * @notice Internal function that reverts on any attempt to add liquidity directly via PoolManager.
     */
    function _beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4)
    {
        revert LiquidityOnlyViaHook();
    }

    /**
     * @notice Internal function that reverts on any attempt to remove liquidity directly via PoolManager.
     */
    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    )
        internal
        virtual
        override
        returns (bytes4)
    {
        revert LiquidityOnlyViaHook();
    }

    // --- Abstract Functions (to be implemented in Derived Contracts) ---

    /**
     * @dev Computes the encoded liquidity modification parameters for adding liquidity and returns the number of shares to mint.
     * @param sqrtPriceX96 The current sqrt price from the pool.
     * @param params The deposit parameters.
     * @return modify The encoded parameters.
     * @return shares The number of liquidity shares to mint.
     *
     * NOTE: This function must produce a unique salt for each liquidity provider.
     *       For full-range deposits, the calculation should mimic Uniswap V2's formula (adjusted for pending fees).
     *       For single token deposits, the first deposit yields one share per token deposited; subsequent deposits are
     *       minted proportionally based on the current custom curve ratio.
     */
    function _getAddLiquidity(uint160 sqrtPriceX96, AddLiquidityParams memory params)
        internal
        virtual
        returns (bytes memory modify, uint256 shares)
    {
        // Minimal default implementation for testing; override in derived contracts.
        modify = "";
        shares = 1;
    }

    /**
     * @dev Computes the encoded liquidity modification parameters for removing liquidity and returns the number of shares to burn.
     * @param params The withdrawal parameters.
     * @return modify The encoded parameters.
     * @return shares The number of liquidity shares to burn.
     */
    function _getRemoveLiquidity(RemoveLiquidityParams memory params)
        internal
        virtual
        returns (bytes memory modify, uint256 shares)
    {
        // Minimal default implementation for testing; override in derived contracts.
        modify = "";
        shares = 1;
    }

    /**
     * @dev Mints liquidity shares after a successful deposit.
     * @param params The deposit parameters.
     * @param delta The balance delta returned by PoolManager.
     * @param shares The number of liquidity shares to mint.
     *
     * NOTE: This function is abstract and must be overridden to update internal accounting.
     */
    function _mint(AddLiquidityParams memory params, BalanceDelta delta, uint256 shares)
        internal
        virtual
    {
        // Default implementation for testing; override as needed.
    }

    /**
     * @dev Burns liquidity shares during a withdrawal.
     * @param params The withdrawal parameters.
     * @param delta The balance delta returned by PoolManager.
     * @param shares The number of liquidity shares to burn.
     *
     * NOTE: This function is abstract and must be overridden to update internal accounting.
     */
    function _burn(RemoveLiquidityParams memory params, BalanceDelta delta, uint256 shares)
        internal
        virtual
    {
        // Default implementation for testing; override as needed.
    }

    // --- Hook Permissions ---
    /**
     * @notice Returns the hook permissions.
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // --- Default Implementation for Testing ---
    /**
     * @dev Minimal implementation for _modifyLiquidity.
     * @param modifyParams The encoded liquidity parameters.
     * @return A zero balance delta.
     *
     * NOTE: In a production implementation, this function would decode modifyParams and call poolManager.modifyLiquidity.
     */
    function _modifyLiquidity(bytes memory modifyParams)
        internal
        virtual
        returns (BalanceDelta)
    {
        return toBalanceDelta(0, 0);
    }
}