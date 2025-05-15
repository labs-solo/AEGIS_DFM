// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// - - - Permit2 Deps - - -

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

// - - - V4 Core Deps - - -

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

import {ERC6909Claims} from "v4-core/src/ERC6909Claims.sol";

// - - - V4 Periphery Deps - - -

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

// - - - Project Interfaces - - -

import {Errors} from "./errors/Errors.sol";
import {IFullRangeLiquidityManager} from "./interfaces/IFullRangeLiquidityManager.sol";

// - - - Project Contracts - - -

import {PoolPolicyManager} from "./PoolPolicyManager.sol";

/**
 * @title FullRangeLiquidityManager
 * @notice Manages hook fees and liquidity for Spot pools
 * @dev Handles fee collection, reinvestment, and allows users to contribute liquidity
 */
contract FullRangeLiquidityManager is IFullRangeLiquidityManager, ERC6909Claims {
    using PoolIdLibrary for PoolKey;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    /// @dev Constant for the minimum locked liquidity per position
    uint256 private constant MIN_LOCKED_LIQUIDITY = 1000;

    /// @notice Cooldown period between reinvestments (default: 1 day)
    uint256 public constant REINVEST_COOLDOWN = 1 days;

    /// @notice Minimum amount to reinvest to avoid dust
    uint256 public constant MIN_REINVEST_AMOUNT = 1e4;

    /// @notice The "constant" Spot hook contract address that can notify fees
    address public immutable override authorizedHookAddress;

    /// @notice The Uniswap V4 PoolManager
    IPoolManager public immutable poolManager;

    /// @notice The Uniswap V4 PositionManager for adding liquidity
    PositionManager public immutable positionManager;

    /// @notice The policy manager contract that determines ownership
    PoolPolicyManager public immutable policyManager;

    struct PendingFees {
        uint256 amount0;
        uint256 amount1;
    }

    /// @notice Pending fees per pool
    mapping(PoolId => PendingFees) public pendingFees;

    /// @notice Last reinvestment timestamp per pool
    mapping(PoolId => uint256) public lastReinvestment;

    /// @notice NFT token IDs for full range positions
    mapping(PoolId => uint256) public positionIds;

    /**
     * @notice Constructs the FullRangeLiquidityManager
     * @param _poolManager The Uniswap V4 PoolManager
     * @param _positionManager The Uniswap V4 PositionManager
     * @param _policyManager The policy manager contract
     * @param _authorizedHookAddress The hook address that can notify fees
     */
    constructor(
        IPoolManager _poolManager,
        PositionManager _positionManager,
        PoolPolicyManager _policyManager,
        address _authorizedHookAddress
    ) {
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();
        if (address(_positionManager) == address(0)) revert Errors.ZeroAddress();
        if (address(_policyManager) == address(0)) revert Errors.ZeroAddress();
        if (_authorizedHookAddress == address(0)) revert Errors.ZeroAddress();

        if (_positionManager.poolManager() != _poolManager) revert Errors.PoolPositionManagerMismatch();

        poolManager = _poolManager;
        positionManager = _positionManager;
        policyManager = _policyManager;
        authorizedHookAddress = _authorizedHookAddress;
    }

    /**
     * @notice Modifier to check if the caller is the policy manager owner
     */
    modifier onlyPolicyOwner() {
        if (msg.sender != policyManager.owner()) revert Errors.UnauthorizedCaller(msg.sender);
        _;
    }

    /**
     * @notice Modifier to ensure only the Spot hook can call
     */
    modifier onlyAuthorizedHook() {
        if (msg.sender != authorizedHookAddress) revert Errors.UnauthorizedCaller(msg.sender);
        _;
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function notifyFee(PoolKey calldata poolKey, uint256 fee0, uint256 fee1) external override onlyAuthorizedHook {
        PoolId poolId = poolKey.toId();
        // Update pending fees
        if (fee0 > 0) {
            pendingFees[poolId].amount0 += fee0;
        }

        if (fee1 > 0) {
            pendingFees[poolId].amount1 += fee1;
        }
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function reinvest(PoolKey calldata key) external override returns (bool success) {
        PoolId poolId = key.toId();

        // Check cooldown and thresholds
        if (block.timestamp < lastReinvestment[poolId] + REINVEST_COOLDOWN) {
            return false;
        }

        // Get pending fees
        uint256 amount0 = pendingFees[poolId].amount0;
        uint256 amount1 = pendingFees[poolId].amount1;

        // Check minimum thresholds
        if (amount0 < MIN_REINVEST_AMOUNT || amount1 < MIN_REINVEST_AMOUNT) {
            return false;
        }

        // Store old values and clear pending fees first (to prevent reentrancy)
        uint256 oldAmount0 = pendingFees[poolId].amount0;
        uint256 oldAmount1 = pendingFees[poolId].amount1;
        pendingFees[poolId].amount0 = 0;
        pendingFees[poolId].amount1 = 0;

        // Redeem tokens from PoolManager
        poolManager.take(key.currency0, address(this), amount0);
        poolManager.take(key.currency1, address(this), amount1);

        // Approve tokens for position operations
        _approveTokensForPosition(key.currency0, key.currency1, amount0, amount1);

        // Add liquidity to position
        (uint256 liquidityAdded, uint256 amount0Used, uint256 amount1Used) =
            _addLiquidityToPosition(key, amount0, amount1, MIN_REINVEST_AMOUNT, MIN_REINVEST_AMOUNT);

        // Restore any unused amounts to pendingFees
        pendingFees[poolId].amount0 = oldAmount0 - amount0Used;
        pendingFees[poolId].amount1 = oldAmount1 - amount1Used;

        // Mint ERC6909 shares to this contract (protocol-owned)
        _mint(address(this), uint256(PoolId.unwrap(poolId)), liquidityAdded);

        // Update last reinvestment time
        lastReinvestment[poolId] = block.timestamp;

        emit FeesReinvested(poolId, amount0Used, amount1Used, liquidityAdded);

        return true;
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function getPendingFees(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = (pendingFees[poolId].amount0, pendingFees[poolId].amount1);
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function getNextReinvestmentTime(PoolId poolId) external view override returns (uint256 timestamp) {
        uint256 last = lastReinvestment[poolId];
        if (last == 0) return block.timestamp;
        return last + REINVEST_COOLDOWN;
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function getPositionInfo(PoolId poolId)
        external
        view
        override
        returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        positionId = positionIds[poolId];

        // If no position exists, return zeros
        if (positionId == 0) {
            return (0, 0, 0, 0);
        }

        // Get pool key from poolId
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(positionId);

        // Get the liquidity in the position from PositionManager
        liquidity = positionManager.getPositionLiquidity(positionId);

        // Get the current pool price
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Get tick range for full range position
        int24 minTick = TickMath.minUsableTick(key.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(key.tickSpacing);

        // Get sqrtPrice at tick bounds
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(minTick);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(maxTick);

        // Convert liquidity to token amounts
        (amount0, amount1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity);

        return (positionId, liquidity, amount0, amount1);
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function getLiquidityForShares(PoolId poolId, uint256 shares)
        public
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 positionId = positionIds[poolId];
        // If no shares, return zeros
        if (positionId == 0 || shares == 0) {
            return (0, 0);
        }

        // Get pool key from poolId
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(positionId);

        // Get the current pool price
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Get tick range for full range position
        int24 minTick = TickMath.minUsableTick(key.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(key.tickSpacing);

        // Get sqrtPrice at tick bounds
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(minTick);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(maxTick);

        // Since shares correspond 1:1 with liquidity, we can directly convert the
        // shares amount to token amounts using the LiquidityAmounts library
        (amount0, amount1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, uint128(shares));

        return (amount0, amount1);
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function getProtocolOwnedLiquidity(PoolId poolId)
        external
        view
        override
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        // Protocol-owned shares are those held by this contract
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        shares = balanceOf[address(this)][poolIdUint];

        if (shares == 0) {
            return (0, 0, 0);
        }

        // Get token amounts from shares
        (amount0, amount1) = getLiquidityForShares(poolId, shares);

        return (shares, amount0, amount1);
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function deposit(
        PoolKey calldata key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external payable override onlyPolicyOwner returns (uint256 liquidityAdded, uint256 amount0, uint256 amount1) {
        PoolId poolId = key.toId();
        // Handle transfers - this will ensure FRLM has tokens to spend
        _handleTokenTransfers(key.currency0, key.currency1, amount0Desired, amount1Desired);

        // Approve tokens for position operations
        _approveTokensForPosition(key.currency0, key.currency1, amount0Desired, amount1Desired);

        // Add liquidity to position
        (liquidityAdded, amount0, amount1) =
            _addLiquidityToPosition(key, amount0Desired, amount1Desired, amount0Min, amount1Min);

        // shares correspond 1:1 with liquidity

        // Mint ERC6909 shares to recipient
        _mint(recipient, uint256(PoolId.unwrap(poolId)), liquidityAdded);

        // Refund any excess ETH after all operations are complete
        uint256 ethNeeded = 0;
        if (key.currency0.isAddressZero()) ethNeeded += amount0;
        if (key.currency1.isAddressZero()) ethNeeded += amount1;

        if (msg.value > ethNeeded) {
            (bool success,) = payable(msg.sender).call{value: msg.value - ethNeeded}("");
            if (!success) revert Errors.ETHRefundFailed();
        }

        emit Deposit(poolId, recipient, liquidityAdded, amount0, amount1);

        return (liquidityAdded, amount0, amount1);
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function withdraw(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external override onlyPolicyOwner returns (uint256 amount0, uint256 amount1) {
        // Use the shared withdrawal logic with the caller as the shares owner
        (amount0, amount1) = _withdrawLiquidity(key, sharesToBurn, amount0Min, amount1Min, msg.sender, recipient);

        emit Withdraw(key.toId(), msg.sender, recipient, amount0, amount1, sharesToBurn);

        return (amount0, amount1);
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function emergencyWithdraw(Currency token, address to, uint256 amount) external override onlyPolicyOwner {
        poolManager.take(token, to, amount);
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function withdrawProtocolLiquidity(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external override onlyPolicyOwner returns (uint256 amount0, uint256 amount1) {
        // Use the shared withdrawal logic with this contract as the shares owner
        (amount0, amount1) = _withdrawLiquidity(
            key,
            sharesToBurn,
            amount0Min,
            amount1Min,
            address(this), // Burn shares from this contract (protocol-owned)
            recipient
        );

        emit WithdrawProtocolLiquidity(key.toId(), recipient, sharesToBurn, amount0, amount1);

        return (amount0, amount1);
    }

    function _approveTokensForPosition(Currency currency0, Currency currency1, uint256 amount0, uint256 amount1)
        internal
    {
        // Approve tokens to Permit2 with infinite allowance
        _approveToPermit2(currency0);
        _approveToPermit2(currency1);

        // Create infinite Permit2 allowance for PositionManager
        _createPermit2Allowance(currency0);
        _createPermit2Allowance(currency1);
    }

    function _approveToPermit2(Currency currency) internal {
        if (!currency.isAddressZero()) {
            address permit2 = address(positionManager.permit2());
            address token = Currency.unwrap(currency);
            uint256 currentAllowance = IERC20Minimal(token).allowance(address(this), permit2);
            if (currentAllowance < type(uint256).max) {
                // NOTE: typically ERC20s with infinite allowances are not decreased
                // however in the atypical case we always force the allowance to max
                IERC20Minimal(token).approve(permit2, type(uint256).max);
            }
        }
    }

    function _createPermit2Allowance(Currency currency) internal {
        if (!currency.isAddressZero()) {
            IAllowanceTransfer permit2 = positionManager.permit2();
            address token = Currency.unwrap(currency);

            // Use max uint160 for amount and far future timestamp for expiration
            uint160 maxAmount = type(uint160).max;
            uint48 farFuture = type(uint48).max;

            // Check current allowance in the Permit2 contract
            (uint160 currentAmount, uint48 expiration,) =
                permit2.allowance(address(this), token, address(positionManager));

            // Only update if not already maximum
            if (currentAmount < maxAmount) {
                permit2.approve(token, address(positionManager), maxAmount, farFuture);
            }
        }
    }

    function _addLiquidityToPosition(
        PoolKey calldata key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 liquidityAdded, uint256 amount0, uint256 amount1) {
        // Check if position exists
        uint256 positionId = positionIds[key.toId()];

        if (positionId == 0) {
            // Create new position
            (positionId, liquidityAdded, amount0, amount1) =
                _mintNewPosition(key, amount0Desired, amount1Desired, amount0Min, amount1Min);
        } else {
            // Increase existing position
            (liquidityAdded, amount0, amount1) =
                _increaseLiquidity(key, positionId, amount0Desired, amount1Desired, amount0Min, amount1Min);
        }
    }

    function _mintNewPosition(
        PoolKey calldata key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 positionId, uint256 liquidityAdded, uint256 amount0, uint256 amount1) {
        PoolId poolId = key.toId();
        // Calculate optimal liquidity for full range position
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 minTick = TickMath.minUsableTick(key.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(key.tickSpacing);

        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(minTick);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(maxTick);

        uint128 liquidity = uint128(
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, amount0Desired, amount1Desired
            )
        );

        // Define actions and parameters
        bytes memory actions = abi.encodePacked(Actions.MINT_POSITION, Actions.SETTLE_PAIR);

        bytes[] memory params = new bytes[](2);

        // Parameters for MINT_POSITION
        params[0] = abi.encode(
            key,
            minTick,
            maxTick,
            liquidity,
            amount0Desired, // Maximum token0 to use
            amount1Desired, // Maximum token1 to use
            address(this), // FRLM owns the NFT
            "" // No hook data
        );

        // Parameters for SETTLE_PAIR
        params[1] = abi.encode(key.currency0, key.currency1);

        // Execute the mint operation
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 60 // 60 second deadline
        );

        // Get the position ID (will be the last minted token)
        positionId = positionManager.nextTokenId() - 1;

        // Store the position ID
        positionIds[poolId] = positionId;

        // Calculate actual amounts used based on the liquidity minted
        (amount0, amount1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity);

        // Validate minimum amounts
        if (amount0 < amount0Min) revert Errors.TooLittleAmount0(amount0Min, amount0);
        if (amount1 < amount1Min) revert Errors.TooLittleAmount1(amount1Min, amount1);

        // Subtract MIN_LOCKED_LIQUIDITY from the shares to be minted
        // This effectively locks MIN_LOCKED_LIQUIDITY in the position
        liquidityAdded = uint256(liquidity) - MIN_LOCKED_LIQUIDITY;

        return (positionId, liquidityAdded, amount0, amount1);
    }

    function _increaseLiquidity(
        PoolKey calldata key,
        uint256 positionId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 liquidityAdded, uint256 amount0, uint256 amount1) {
        // Calculate optimal liquidity increase
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        int24 minTick = TickMath.minUsableTick(key.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(key.tickSpacing);

        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(minTick);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(maxTick);

        uint128 liquidity = uint128(
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, amount0Desired, amount1Desired
            )
        );

        // Define actions and parameters
        bytes memory actions = abi.encodePacked(Actions.INCREASE_LIQUIDITY, Actions.SETTLE_PAIR);

        bytes[] memory params = new bytes[](2);

        // Parameters for INCREASE_LIQUIDITY
        params[0] = abi.encode(
            positionId,
            liquidity,
            amount0Desired,
            amount1Desired,
            "" // No hook data
        );

        // Parameters for SETTLE_PAIR
        params[1] = abi.encode(key.currency0, key.currency1);

        // Execute the increase operation
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 60 // 60 second deadline
        );

        // Calculate actual amounts used
        (amount0, amount1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity);

        // Validate minimum amounts
        if (amount0 < amount0Min) revert Errors.TooLittleAmount0(amount0Min, amount0);
        if (amount1 < amount1Min) revert Errors.TooLittleAmount1(amount1Min, amount1);

        liquidityAdded = uint256(liquidity);

        return (liquidityAdded, amount0, amount1);
    }

    /**
     * @notice Internal function to handle withdrawal of liquidity
     * @param key The pool key
     * @param sharesToBurn Number of shares to burn
     * @param amount0Min Minimum amount of token0 to receive
     * @param amount1Min Minimum amount of token1 to receive
     * @param sharesOwner Address that owns the shares to be burned
     * @param recipient Address to receive the withdrawn tokens
     * @return amount0 Amount of token0 withdrawn
     * @return amount1 Amount of token1 withdrawn
     */
    function _withdrawLiquidity(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address sharesOwner,
        address recipient
    ) internal returns (uint256 amount0, uint256 amount1) {
        // Get the pool ID
        PoolId poolId = key.toId();

        // Convert poolId to uint256 for ERC6909 operations
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));

        // Get the position ID (revert if position doesn't exist)
        uint256 positionId = positionIds[poolId];
        if (positionId == 0) revert Errors.PositionNotFound(poolId);

        // Ensure recipient is not zero address
        if (recipient == address(0)) revert Errors.ZeroAddress();

        // Prepare the actions for position manager
        bytes memory actions = abi.encodePacked(
            Actions.DECREASE_LIQUIDITY, // Decrease liquidity from the position
            Actions.TAKE_PAIR // Take tokens to this contract
        );

        // Prepare the parameters
        bytes[] memory params = new bytes[](2);

        // Parameters for DECREASE_LIQUIDITY
        // Since shares correspond 1:1 with liquidity, we pass sharesToBurn as the liquidity amount
        params[0] = abi.encode(
            positionId, // Position NFT ID
            uint128(sharesToBurn), // Amount of liquidity to remove
            amount0Min, // Minimum amount of token0 to receive
            amount1Min, // Minimum amount of token1 to receive
            "" // No hook data
        );

        // Parameters for TAKE_PAIR - receive tokens at this contract first
        params[1] = abi.encode(
            key.currency0, // Token0
            key.currency1, // Token1
            address(this) // Receiver (this contract)
        );

        // Execute the position modification
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 60 // 60 second deadline
        );

        // Calculate how much we received
        // For token0
        uint256 balance0Before = key.currency0.balanceOfSelf();
        // For token1
        uint256 balance1Before = key.currency1.balanceOfSelf();

        // Burn shares from the specified owner
        if (sharesOwner == address(this)) {
            _burn(sharesOwner, poolIdUint, sharesToBurn);
        } else {
            _burnFrom(sharesOwner, poolIdUint, sharesToBurn);
        }

        // Transfer tokens to recipient
        key.currency0.transfer(recipient, balance0Before);
        key.currency1.transfer(recipient, balance1Before);

        amount0 = balance0Before;
        amount1 = balance1Before;

        return (amount0, amount1);
    }

    function _handleTokenTransfers(Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) internal {
        // Handle native ETH if applicable
        if (currency0.isAddressZero()) {
            if (msg.value < amount0) revert Errors.InsufficientETH(amount0, msg.value);
        } else {
            IERC20Minimal(Currency.unwrap(currency0)).transferFrom(msg.sender, address(this), amount0);
        }

        if (currency1.isAddressZero()) {
            if (msg.value < amount1) revert Errors.InsufficientETH(amount1, msg.value);
        } else if (!currency0.isAddressZero() || !(currency0 == currency1)) {
            // Only transfer token1 if it's not the same native ETH as token0
            IERC20Minimal(Currency.unwrap(currency1)).transferFrom(msg.sender, address(this), amount1);
        }
    }
}
