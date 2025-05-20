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
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

import {ERC6909Claims} from "v4-core/src/ERC6909Claims.sol";

// - - - V4 Periphery Deps - - -

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {ISubscriber} from "v4-periphery/src/interfaces/ISubscriber.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

// - - - Project Interfaces - - -

import {Errors} from "./errors/Errors.sol";
import {IFullRangeLiquidityManager} from "./interfaces/IFullRangeLiquidityManager.sol";
import {Math} from "./libraries/Math.sol";

// - - - Project Contracts - - -

import {PoolPolicyManager} from "./PoolPolicyManager.sol";

/// @title FullRangeLiquidityManager
/// @notice Manages hook fees and liquidity for Spot pools
/// @dev Handles fee collection, reinvestment, and allows users to contribute liquidity
contract FullRangeLiquidityManager is IFullRangeLiquidityManager, ISubscriber, ERC6909Claims {
    using PoolIdLibrary for PoolKey;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    /// @dev Constant for the minimum locked liquidity per position
    uint256 private constant MIN_LOCKED_LIQUIDITY = 1000;

    /// @notice Cooldown period between reinvestments (default: 1 day)
    uint256 public constant REINVEST_COOLDOWN = 1 days;

    /// @notice Minimum amount to reinvest to avoid dust
    uint256 private constant MIN_REINVEST_AMOUNT = 1e4;

    /// @notice The "constant" Spot hook contract address that can notify fees
    address public immutable override authorizedHookAddress;

    /// @notice The Uniswap V4 PoolManager
    IPoolManager public immutable override poolManager;

    /// @notice The Uniswap V4 PositionManager for adding liquidity
    PositionManager public immutable override positionManager;

    /// @notice The policy manager contract that determines ownership
    PoolPolicyManager public immutable override policyManager;

    struct PendingFees {
        uint256 erc6909_0;
        uint256 erc6909_1;
        uint256 erc20_0;
        uint256 erc20_1;
    }

    /// @notice Pending fees per pool
    mapping(PoolId => PendingFees) private pendingFees;

    /// @notice Last reinvestment timestamp per pool
    mapping(PoolId => uint256) private lastReinvestment;

    /// @notice NFT token IDs for full range positions
    mapping(PoolId => uint256) private positionIds;

    /// @notice Tracks accounted balances of tokens per currency
    mapping(Currency => uint256) public override accountedBalances;

    /// @notice Tracks accounted balances of ERC6909 tokens per currency ID
    mapping(Currency => uint256) public override accountedERC6909Balances;

    /// @notice Constructs the FullRangeLiquidityManager
    /// @param _poolManager The Uniswap V4 PoolManager
    /// @param _positionManager The Uniswap V4 PositionManager
    /// @param _policyManager The policy manager contract
    /// @param _authorizedHookAddress The hook address that can notify fees
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

    modifier onlyPolicyOwner() {
        if (msg.sender != policyManager.owner()) revert Errors.UnauthorizedCaller(msg.sender);
        _;
    }

    modifier onlySpot() {
        if (msg.sender != authorizedHookAddress) revert Errors.UnauthorizedCaller(msg.sender);
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert Errors.NotPoolManager();
        _;
    }

    modifier onlyPositionManager() {
        if (msg.sender != address(positionManager)) revert Errors.UnauthorizedCaller(msg.sender);
        _;
    }

    receive() external payable {
        // Accept ETH transfers silently
        // This is needed when redeeming native ETH through poolManager.take()
        // or when receiving ETH from PositionManager operations
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        if (data.length > 0) {
            // Decode the action type
            (CallbackAction action) = abi.decode(data[:32], (CallbackAction));

            if (action == CallbackAction.TAKE_TOKENS) {
                // Decode token currencies and amounts
                (
                    , // Skip the action we already decoded
                    Currency currency0,
                    Currency currency1,
                    uint256 amount0,
                    uint256 amount1
                ) = abi.decode(data, (CallbackAction, Currency, Currency, uint256, uint256));

                // Take tokens from PoolManager to this contract
                if (amount0 > 0) {
                    poolManager.take(currency0, address(this), amount0);
                    // Burn ERC6909 tokens to balance the delta
                    poolManager.burn(address(this), currency0.toId(), amount0);

                    // Track token balances when converting from ERC6909
                    accountedERC6909Balances[currency0] -= amount0;
                    accountedBalances[currency0] += amount0;
                }

                if (amount1 > 0) {
                    poolManager.take(currency1, address(this), amount1);
                    // Burn ERC6909 tokens to balance the delta
                    poolManager.burn(address(this), currency1.toId(), amount1);

                    // Track token balances when converting from ERC6909
                    accountedERC6909Balances[currency1] -= amount1;
                    accountedBalances[currency1] += amount1;
                }
            } else if (action == CallbackAction.SWEEP_TOKEN) {
                // Decode sweep parameters
                (
                    , // Skip the action we already decoded
                    Currency token,
                    address to,
                    uint256 amount
                ) = abi.decode(data, (CallbackAction, Currency, address, uint256));

                // Take tokens directly to the specified recipient
                poolManager.take(token, to, amount);
                // Burn ERC6909 tokens to balance the delta
                poolManager.burn(address(this), token.toId(), amount);

                // Update ERC6909 balance tracking
                accountedERC6909Balances[token] -= amount;
            }
        }

        return "";
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function notifyFee(PoolKey calldata poolKey, uint256 fee0, uint256 fee1) external override onlySpot {
        PoolId poolId = poolKey.toId();
        // Update pending fees
        if (fee0 > 0) {
            pendingFees[poolId].erc6909_0 += fee0;
            // Track ERC6909 balance
            accountedERC6909Balances[poolKey.currency0] += fee0;
        }

        if (fee1 > 0) {
            pendingFees[poolId].erc6909_1 += fee1;
            // Track ERC6909 balance
            accountedERC6909Balances[poolKey.currency1] += fee1;
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
        PendingFees memory _pendingFees = pendingFees[poolId];

        uint256 erc6909_0 = _pendingFees.erc6909_0;
        uint256 erc6909_1 = _pendingFees.erc6909_1;

        uint256 erc20_0 = _pendingFees.erc20_0;
        uint256 erc20_1 = _pendingFees.erc20_1;

        uint256 total0 = erc6909_0 + erc20_0;
        uint256 total1 = erc6909_1 + erc20_1;

        // Check minimum thresholds
        if (total0 < MIN_REINVEST_AMOUNT || total1 < MIN_REINVEST_AMOUNT) {
            return false;
        }

        // Redeem ERC20 tokens from PoolManager
        // NOTE: We have to first redeem the ERC20 tokens to the FRLM since the Actions.BURN_6909 code has not yet supported
        // and so the PositionManager does not yet have the ability to settle from PoolManager 6909 allowances that the user
        // would have granted to the PositionManager

        if (!TransientStateLibrary.isUnlocked(poolManager)) {
            bytes memory callbackData =
                abi.encode(CallbackAction.TAKE_TOKENS, key.currency0, key.currency1, erc6909_0, erc6909_1);

            // The unlockCallback function will update the accounted balances
            poolManager.unlock(callbackData);
        } else {
            // NOTE: this pathway is possible when reinvest is called in afterSwap
            poolManager.take(key.currency0, address(this), erc6909_0);
            poolManager.burn(address(this), key.currency0.toId(), erc6909_0);

            // Track token balances when converting from ERC6909
            accountedERC6909Balances[key.currency0] -= erc6909_0;
            accountedBalances[key.currency0] += erc6909_0;

            poolManager.take(key.currency1, address(this), erc6909_1);
            poolManager.burn(address(this), key.currency1.toId(), erc6909_1);

            // Track token balances when converting from ERC6909
            accountedERC6909Balances[key.currency1] -= erc6909_1;
            accountedBalances[key.currency1] += erc6909_1;
        }

        // Approve tokens for position operations
        _approveTokensForPosition(key.currency0, key.currency1);

        // Add liquidity to position
        (uint256 liquidityAdded, uint256 amount0Used, uint256 amount1Used) =
            _addLiquidityToPosition(key, total0, total1, MIN_REINVEST_AMOUNT, MIN_REINVEST_AMOUNT);

        // Restore any unused amounts and accrued NFT fees to pendingFees
        // Update accountedBalances for tokens used in position
        accountedBalances[key.currency0] -= amount0Used;
        accountedBalances[key.currency1] -= amount1Used;

        // NOTE: at this point pendingFees could've been updated in notifyModifyLiquidity so we reload into memory
        PendingFees memory _finalPendingFees = pendingFees[poolId];

        pendingFees[poolId] = PendingFees({
            erc20_0: (_finalPendingFees.erc20_0 + total0) - amount0Used - _pendingFees.erc20_0,
            erc20_1: (_finalPendingFees.erc20_1 + total1) - amount1Used - _pendingFees.erc20_1,
            erc6909_0: 0,
            erc6909_1: 0
        });

        // Mint ERC6909 shares to this contract (protocol-owned)
        _mint(address(this), uint256(PoolId.unwrap(poolId)), liquidityAdded);

        // Update last reinvestment time
        lastReinvestment[poolId] = block.timestamp;

        emit FeesReinvested(poolId, amount0Used, amount1Used, liquidityAdded);

        return true;
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function getPendingFees(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        PendingFees memory _pendingFees = pendingFees[poolId];
        (amount0, amount1) =
            (_pendingFees.erc20_0 + _pendingFees.erc6909_0, _pendingFees.erc20_1 + _pendingFees.erc6909_1);
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
        address recipient,
        address payer
    )
        external
        payable
        override
        onlySpot
        returns (
            uint256 liquidityAdded,
            uint256 amount0Used,
            uint256 amount1Used,
            uint256 unusedAmount0,
            uint256 unusedAmount1
        )
    {
        PoolId poolId = key.toId();

        // Pull tokens directly from the payer
        _handleTokenTransfersFromPayer(key.currency0, key.currency1, amount0Desired, amount1Desired, payer);

        // Track received tokens
        accountedBalances[key.currency0] += amount0Desired;
        accountedBalances[key.currency1] += amount1Desired;

        // Approve tokens for position operations
        _approveTokensForPosition(key.currency0, key.currency1);

        // Add liquidity to position
        (liquidityAdded, amount0Used, amount1Used) =
            _addLiquidityToPosition(key, amount0Desired, amount1Desired, amount0Min, amount1Min);

        // Calculate unused amounts
        unusedAmount0 = amount0Desired - amount0Used;
        unusedAmount1 = amount1Desired - amount1Used;

        // Refund any unused tokens to the payer, not the caller
        if (unusedAmount0 > 0) {
            uint256 balance0 = key.currency0.balanceOfSelf();
            // NOTE: we do Math.min as it's possible that there's a unit loss in the LiquidityAmounts math
            uint256 transfer0 = Math.min(unusedAmount0, balance0);
            accountedBalances[key.currency0] -= transfer0;
            key.currency0.transfer(payer, transfer0);
        }

        if (unusedAmount1 > 0) {
            uint256 balance1 = key.currency1.balanceOfSelf();
            uint256 transfer1 = Math.min(unusedAmount1, balance1);
            accountedBalances[key.currency1] -= transfer1;
            key.currency1.transfer(payer, transfer1);
        }

        // shares correspond 1:1 with liquidity
        // Mint ERC6909 shares to recipient
        _mint(recipient, uint256(PoolId.unwrap(poolId)), liquidityAdded);

        emit Deposit(poolId, recipient, liquidityAdded, amount0Used, amount1Used);

        return (liquidityAdded, amount0Used, amount1Used, unusedAmount0, unusedAmount1);
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function withdraw(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        address sharesOwner
    ) external override onlySpot returns (uint256 amount0, uint256 amount1) {
        // Use the shared withdrawal logic with the specified sharesOwner
        (amount0, amount1) = _withdrawLiquidity(key, sharesToBurn, amount0Min, amount1Min, sharesOwner, recipient);

        emit Withdraw(key.toId(), sharesOwner, recipient, amount0, amount1, sharesToBurn);

        return (amount0, amount1);
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

    /// @inheritdoc IFullRangeLiquidityManager
    function sweepExcessTokens(Currency currency, address recipient)
        external
        onlyPolicyOwner
        returns (uint256 amountSwept)
    {
        if (recipient == address(0)) revert Errors.ZeroAddress();

        uint256 balance;
        if (currency.isAddressZero()) {
            // Native ETH
            balance = address(this).balance;
        } else {
            // ERC20 token
            balance = IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
        }

        uint256 accounted = accountedBalances[currency];

        // Only sweep excess tokens
        if (balance > accounted) {
            amountSwept = balance - accounted;

            // Transfer the tokens
            currency.transfer(recipient, amountSwept);

            emit ExcessTokensSwept(currency, recipient, amountSwept);
        }

        return amountSwept;
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function sweepExcessERC6909(Currency currency, address recipient)
        external
        override
        onlyPolicyOwner
        returns (uint256 amountSwept)
    {
        if (recipient == address(0)) revert Errors.ZeroAddress();

        uint256 currencyId = currency.toId();
        uint256 balance = poolManager.balanceOf(address(this), currencyId);
        uint256 accounted = accountedERC6909Balances[currency];

        // Only sweep excess tokens
        if (balance > accounted) {
            amountSwept = balance - accounted;

            // Use unlock callback to take the tokens
            bytes memory callbackData = abi.encode(CallbackAction.SWEEP_TOKEN, currency, recipient, amountSwept);

            poolManager.unlock(callbackData);

            emit ExcessTokensSwept(currency, recipient, amountSwept);
        }

        return amountSwept;
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function donate(PoolKey calldata key, uint256 amount0, uint256 amount1)
        external
        payable
        override
        returns (uint256 donated0, uint256 donated1)
    {
        // Validate that the currencies match the pool
        PoolId poolId = key.toId();

        Currency currency0 = key.currency0;
        Currency currency1 = key.currency1;

        // Pull tokens from the donor
        if (amount0 > 0) {
            // Handle ETH donation if currency0 is native
            if (currency0.isAddressZero()) {
                if (msg.value < amount0) {
                    revert Errors.InsufficientETH(amount0, msg.value);
                }
                donated0 = amount0;
            } else {
                // Handle ERC20 donation
                uint256 balanceBefore = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
                IERC20Minimal(Currency.unwrap(currency0)).transferFrom(msg.sender, address(this), amount0);
                uint256 balanceAfter = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
                donated0 = balanceAfter - balanceBefore; // Account for potential transfer fees
            }

            // Update pending fees and accounting
            pendingFees[poolId].erc20_0 += donated0;
            accountedBalances[currency0] += donated0;
        }

        if (amount1 > 0) {
            // Handle ETH donation if currency1 is native (unlikely but possible)
            if (currency1.isAddressZero()) {
                if (msg.value < amount1 || (amount0 > 0 && currency0.isAddressZero() && msg.value < amount0 + amount1))
                {
                    revert Errors.InsufficientETH(amount0 + amount1, msg.value);
                }
                donated1 = amount1;
            } else {
                // Handle ERC20 donation
                uint256 balanceBefore = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));
                IERC20Minimal(Currency.unwrap(currency1)).transferFrom(msg.sender, address(this), amount1);
                uint256 balanceAfter = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));
                donated1 = balanceAfter - balanceBefore; // Account for potential transfer fees
            }

            // Update pending fees and accounting
            pendingFees[poolId].erc20_1 += donated1;
            accountedBalances[currency1] += donated1;
        }

        // Return any excess ETH
        if (msg.value > 0) {
            uint256 ethUsed = 0;
            if (currency0.isAddressZero()) ethUsed += donated0;
            if (currency1.isAddressZero()) ethUsed += donated1;

            if (msg.value > ethUsed) {
                (bool success,) = msg.sender.call{value: msg.value - ethUsed}("");
                if (!success) revert Errors.ETHTransferFailed();
            }
        }

        emit Donation(poolId, msg.sender, donated0, donated1);

        return (donated0, donated1);
    }

    // - - - internals - - -

    function _approveTokensForPosition(Currency currency0, Currency currency1) internal {
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
            (uint160 currentAmount,,) = permit2.allowance(address(this), token, address(positionManager));

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
    ) internal returns (uint256 liquidityAdded, uint256 amount0Used, uint256 amount1Used) {
        // Check if position exists
        uint256 positionId = positionIds[key.toId()];

        if (positionId == 0) {
            // Create new position
            (liquidityAdded, amount0Used, amount1Used) =
                _mintNewPosition(key, amount0Desired, amount1Desired, amount0Min, amount1Min);
        } else {
            // Increase existing position
            (liquidityAdded, amount0Used, amount1Used) =
                _increaseLiquidity(key, positionId, amount0Desired, amount1Desired, amount0Min, amount1Min);
        }
    }

    function _mintNewPosition(
        PoolKey calldata key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 liquidityAdded, uint256 amount0Used, uint256 amount1Used) {
        uint256 positionId;
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

        if (liquidity <= MIN_LOCKED_LIQUIDITY || TransientStateLibrary.isUnlocked(poolManager)) {
            // NOTE: we early return if not much liquidity would be minted
            // Also if the PoolManager is unlocked we cannot PositionManager.subscribe to the NFT
            return (0, 0, 0);
        }

        // Define actions and parameters
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

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

        // Calculate native ETH value to forward
        uint256 ethValue = 0;
        if (key.currency0.isAddressZero()) ethValue = amount0Desired;

        // Execute the mint operation - forward ETH if needed
        positionManager.modifyLiquidities{value: ethValue}(
            abi.encode(actions, params),
            block.timestamp + 60 // 60 second deadline
        );

        // Get the position ID (will be the last minted token)
        positionId = positionManager.nextTokenId() - 1;

        // Store the position ID
        positionIds[poolId] = positionId;
        positionManager.subscribe(positionId, address(this), "");

        // Calculate actual amounts used based on the liquidity minted
        (amount0Used, amount1Used) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity);

        // Validate minimum amounts
        if (amount0Used < amount0Min) revert Errors.TooLittleAmount0(amount0Min, amount0Used);
        if (amount1Used < amount1Min) revert Errors.TooLittleAmount1(amount1Min, amount1Used);

        // Subtract MIN_LOCKED_LIQUIDITY from the shares to be minted
        // This effectively locks MIN_LOCKED_LIQUIDITY in the position
        liquidityAdded = uint256(liquidity) - MIN_LOCKED_LIQUIDITY;

        // NOTE: for v1 we want 1:1 share liquidity correspondence
        _mint(address(0), uint256(PoolId.unwrap(poolId)), MIN_LOCKED_LIQUIDITY);

        // round up just to be pessimistic regarding the amount taken
        return (liquidityAdded, Math.min(amount0Used + 1, amount0Desired), Math.min(amount1Used + 1, amount1Desired));
    }

    function _increaseLiquidity(
        PoolKey calldata key,
        uint256 positionId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 liquidityAdded, uint256 amount0Used, uint256 amount1Used) {
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

        if (liquidity < MIN_LOCKED_LIQUIDITY) {
            // NOTE: we early return if not much liquidity would be added
            return (0, 0, 0);
        }

        // Define actions and parameters
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));

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

        // Calculate native ETH value to forward
        uint256 ethValue = 0;
        if (key.currency0.isAddressZero()) ethValue = amount0Desired;

        // Execute the increase operation - forward ETH if needed
        if (TransientStateLibrary.isUnlocked(poolManager)) {
            positionManager.modifyLiquiditiesWithoutUnlock{value: ethValue}(actions, params);
        } else {
            positionManager.modifyLiquidities{value: ethValue}(
                abi.encode(actions, params),
                block.timestamp + 60 // 60 second deadline
            );
        }

        // Calculate actual amounts used
        (amount0Used, amount1Used) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity);

        // Validate minimum amounts
        if (amount0Used < amount0Min) revert Errors.TooLittleAmount0(amount0Min, amount0Used);
        if (amount1Used < amount1Min) revert Errors.TooLittleAmount1(amount1Min, amount1Used);

        liquidityAdded = uint256(liquidity);

        return (liquidityAdded, Math.min(amount0Used + 1, amount0Desired), Math.min(amount1Used + 1, amount1Desired));
    }

    /// @notice Internal function to handle withdrawal of liquidity
    /// @param key The pool key
    /// @param sharesToBurn Number of shares to burn
    /// @param amount0Min Minimum amount of token0 to receive
    /// @param amount1Min Minimum amount of token1 to receive
    /// @param sharesOwner Address that owns the shares to be burned
    /// @param recipient Address to receive the withdrawn tokens
    /// @return amount0 Amount of token0 withdrawn
    /// @return amount1 Amount of token1 withdrawn
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
            uint8(Actions.DECREASE_LIQUIDITY), // Decrease liquidity from the position
            uint8(Actions.TAKE_PAIR) // Take tokens to this contract
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

        uint256 balance0Before = key.currency0.balanceOfSelf();
        uint256 balance1Before = key.currency1.balanceOfSelf();

        // Execute the position modification
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 60 // 60 second deadline
        );

        // Calculate how much we received
        uint256 received0 = key.currency0.balanceOfSelf() - balance0Before;
        uint256 received1 = key.currency1.balanceOfSelf() - balance1Before;

        // Get the current pool price and tick range to calculate expected principal amount
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 minTick = TickMath.minUsableTick(key.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(key.tickSpacing);

        // Get sqrtPrice at tick bounds
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(minTick);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(maxTick);

        // Calculate the expected principal amounts based on the liquidity being withdrawn
        (uint256 principal0, uint256 principal1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, uint128(sharesToBurn)
        );

        // Calculate the fee component (difference between received and principal)
        uint256 fee0 = 0;
        uint256 fee1 = 0;

        if (received0 > principal0) {
            fee0 = received0 - principal0;
            received0 = principal0;
        }

        if (received1 > principal1) {
            fee1 = received1 - principal1;
            received1 = principal1;
        }

        // NOTE: we don't need to notify NFT fees as this was already done in notifyModifyLiquidity

        // Burn shares from the specified owner
        if (sharesOwner == address(this)) {
            _burn(sharesOwner, poolIdUint, sharesToBurn);
        } else {
            _burnFrom(sharesOwner, poolIdUint, sharesToBurn);
        }

        // Transfer only the principal tokens to recipient (not the fees)
        key.currency0.transfer(recipient, received0);
        key.currency1.transfer(recipient, received1);

        amount0 = received0;
        amount1 = received1;

        return (amount0, amount1);
    }

    function _handleTokenTransfersFromPayer(
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        address payer
    ) internal {
        // Handle native ETH if applicable
        if (currency0.isAddressZero()) {
            if (msg.value < amount0) {
                revert Errors.InsufficientETH(amount0, msg.value);
            } else if (msg.value > amount0) {
                uint256 excessNative = msg.value - amount0;
                currency0.transfer(payer, excessNative);
            }
        } else {
            if (amount0 > 0) {
                IERC20Minimal(Currency.unwrap(currency0)).transferFrom(payer, address(this), amount0);
            }
        }

        if (amount1 > 0) {
            // Given ordering currency1 is guaranteed to NOT be address(0)
            IERC20Minimal(Currency.unwrap(currency1)).transferFrom(payer, address(this), amount1);
        }
    }

    // - - - Subscriber Public - - -

    /// @inheritdoc ISubscriber
    function notifySubscribe(uint256 tokenId, bytes memory data) external override {
        // NOTE: not needed
    }

    /// @inheritdoc ISubscriber
    function notifyUnsubscribe(uint256 tokenId) external override {
        // NOTE: not needed
    }

    /// @inheritdoc ISubscriber
    function notifyBurn(uint256 tokenId, address owner, PositionInfo info, uint256 liquidity, BalanceDelta feesAccrued)
        external
        override
    {
        // NOTE: not needed
    }

    /// @inheritdoc ISubscriber
    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta feesAccrued)
        external
        override
        onlyPositionManager
    {
        // Only process if there are fees
        if (feesAccrued.amount0() == 0 && feesAccrued.amount1() == 0) return;

        // Get position info to determine pool key
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);
        PoolId poolId = key.toId();

        // Process fees accrued
        _processFeeNotification(poolId, key.currency0, key.currency1, feesAccrued);

        emit PositionFeeAccrued(tokenId, poolId, feesAccrued.amount0(), feesAccrued.amount1());
    }

    // - - - Subscriber Internal - - -

    function _processFeeNotification(PoolId poolId, Currency currency0, Currency currency1, BalanceDelta feesAccrued)
        internal
    {
        // Extract fee amounts
        int128 amount0 = feesAccrued.amount0();
        int128 amount1 = feesAccrued.amount1();

        // Only process positive amounts
        if (amount0 > 0) {
            uint256 fee0 = uint256(uint128(amount0));
            pendingFees[poolId].erc20_0 += fee0;
            accountedBalances[currency0] += fee0;
        }

        if (amount1 > 0) {
            uint256 fee1 = uint256(uint128(amount1));
            pendingFees[poolId].erc20_1 += fee1;
            accountedBalances[currency1] += fee1;
        }
    }
}
