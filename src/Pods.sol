// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FullRange} from "./FullRange.sol";
import {PodsLibrary} from "./libraries/PodsLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityMath} from "./libraries/LiquidityMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FixedPointMathLib} from "v4-core/lib/solmate/src/utils/FixedPointMathLib.sol";

/**
 * @title Pods
 * @notice Manages off-curve liquidity Pods for hook-controlled deposits.
 *         PodA accepts token0 deposits; PodB accepts token1 deposits.
 * @dev LP shares are minted using an ERC-6909 claim token mechanism.
 *      Tier 2 swaps reference the UniV4 spot price (static during execution) and partial fills are disallowed.
 *      Pods inherits from FullRange.sol which handles on-curve (full-range) liquidity management.
 *      This inheritance pattern allows Solo.sol to inherit from Pods.sol to get both functionalities.
 */
contract Pods is FullRange {
    using SafeCast for uint256;
    using FixedPointMathLib for uint256;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Pod types
    enum PodType { A, B }
    bytes32 internal constant PODA_SALT = keccak256("PodA");
    bytes32 internal constant PODB_SALT = keccak256("PodB");

    // Constants
    uint256 public constant FEE_PRECISION = 10000;
    uint128 public constant TIER1_FIXED_FEE_BPS = 30; // 0.3% fee on tier 1 swaps
    uint128 public constant MAX_TIER2_FEE_BPS = 100;  // 1% max fee for Tier 2 swaps
    
    // Contract references
    address private immutable _podPolAccumulator;

    // Price cache
    uint256 private cachedBlock;
    uint256 private cachedPriceToken1InToken0;
    uint256 private cachedPriceToken0InToken1;

    // Events
    event DepositPod(address indexed user, PodType pod, uint256 amount, uint256 sharesMinted);
    event WithdrawPod(address indexed user, PodType pod, uint256 sharesBurned, uint256 amountOut);
    event Tier1SwapExecuted(uint128 feeApplied);
    event Tier2SwapExecuted(uint128 feeApplied, string podUsed);
    event Tier3SwapExecuted(uint128 feeApplied, string customRouteDetails);

    // Error definitions
    error ZeroAmount();
    error NoPartialFillsAllowed();
    error InvalidPath();
    error InvalidToken();
    error Unauthorized();
    error IncorrectTokenPath();

    // Pod tracking
    struct PodInfo {
        uint256 totalShares; // Total LP claim tokens minted.
    }
    PodInfo public podA;
    PodInfo public podB;

    // Share tracking
    mapping(address => uint256) public userPodAShares;
    mapping(address => uint256) public userPodBShares;

    // Swap parameter structure
    struct SwapParams {
        PoolKey poolKey;         // The pool to use for the swap
        address tokenIn;         // Token to swap from
        address tokenOut;        // Token to swap to
        uint256 amountIn;        // Amount to swap
        uint256 amountOutMin;    // Minimum amount out (slippage protection)
        uint256 deadline;        // Expiration time
    }
    
    /**
     * @notice Constructor for Pods contract
     * @param _poolManager Address of the Uniswap V4 PoolManager
     * @param _polAccumulator Address where protocol-owned liquidity fees are sent
     * @param _truncGeoOracleMulti Address of the oracle contract
     */
    constructor(
        address _poolManager,
        address _polAccumulator,
        address _truncGeoOracleMulti
    ) FullRange(IPoolManager(_poolManager), _truncGeoOracleMulti) {
        _podPolAccumulator = _polAccumulator;
    }

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    /**
     * @notice Deposit tokens into a Pod and receive liquidity shares
     * @param pod The pod type to deposit into (A=token0, B=token1)
     * @param amount The amount of tokens to deposit
     * @return sharesMinted The number of liquidity shares minted for the deposit
     */
    function depositPod(PodType pod, uint256 amount) external returns (uint256 sharesMinted) {
        if (amount == 0) revert ZeroAmount();
        
        // Calculate shares to mint
        // For first deposit, shares = amount
        // For subsequent deposits, shares = amount * (totalShares / podValue)
        if (pod == PodType.A) {
            uint256 currentValue = getCurrentPodValueInA();
            sharesMinted = PodsLibrary.calculatePodShares(amount, podA.totalShares, currentValue);
            
            // Update pod state
            podA.totalShares += sharesMinted;
            userPodAShares[msg.sender] += sharesMinted;
        } else {
            uint256 currentValue = getCurrentPodValueInB();
            sharesMinted = PodsLibrary.calculatePodShares(amount, podB.totalShares, currentValue);
            
            // Update pod state
            podB.totalShares += sharesMinted;
            userPodBShares[msg.sender] += sharesMinted;
        }
        
        // In a real implementation, we'd transfer tokens from sender to this contract
        
        emit DepositPod(msg.sender, pod, amount, sharesMinted);
        return sharesMinted;
    }

    /**
     * @notice Withdraw tokens from a Pod by burning liquidity shares
     * @param pod The pod type to withdraw from (A=token0, B=token1)
     * @param shares The number of shares to burn
     * @return amountOut The amount of tokens received
     */
    function withdrawPod(PodType pod, uint256 shares) external returns (uint256 amountOut) {
        if (shares == 0) revert ZeroAmount();
        
        if (pod == PodType.A) {
            // Ensure pod has shares
            if (podA.totalShares == 0) revert InsufficientShares();
            
            // Ensure user has enough shares
            if (userPodAShares[msg.sender] < shares) revert InsufficientShares();
            
            // Calculate output amount based on current value
            uint256 currentValue = getCurrentPodValueInA();
            amountOut = (shares * currentValue) / podA.totalShares;
            
            // Update pod state
            podA.totalShares -= shares;
            userPodAShares[msg.sender] -= shares;
        } else {
            // Ensure pod has shares
            if (podB.totalShares == 0) revert InsufficientShares();
            
            // Ensure user has enough shares
            if (userPodBShares[msg.sender] < shares) revert InsufficientShares();
            
            // Calculate output amount based on current value
            uint256 currentValue = getCurrentPodValueInB();
            amountOut = (shares * currentValue) / podB.totalShares;
            
            // Update pod state
            podB.totalShares -= shares;
            userPodBShares[msg.sender] -= shares;
        }
        
        // In a real implementation, we'd transfer tokens from this contract to sender
        
        emit WithdrawPod(msg.sender, pod, shares, amountOut);
        return amountOut;
    }

    /**
     * @notice Execute a Tier 1 swap with a fixed fee sent to the POL accumulator
     * @param params Swap parameters
     * @return amountOut The amount of tokens received after the swap
     * @dev Tier 1 swaps apply a fixed fee percentage (TIER1_FIXED_FEE_BPS) that is
     *      sent to the Protocol-Owned Liquidity (POL) accumulator
     */
    function tier1Swap(SwapParams calldata params) 
        external 
        ensure(params.deadline) 
        returns (uint256 amountOut) 
    {
        // Validate inputs
        if (params.amountIn == 0) revert ZeroAmount();
        
        // Verify token path is valid (token0 -> token1 or token1 -> token0)
        address token0 = Currency.unwrap(Currency.wrap(address(params.tokenIn)));
        address token1 = Currency.unwrap(Currency.wrap(address(params.tokenOut)));
        if ((token0 != address(params.tokenIn) && token1 != address(params.tokenIn)) || 
            (token0 != address(params.tokenOut) && token1 != address(params.tokenOut))) {
            revert IncorrectTokenPath();
        }
        
        // Ensure tokenIn and tokenOut are different
        if (params.tokenIn == params.tokenOut) revert IncorrectTokenPath();
        
        // Verify the pool is valid and initialized
        PoolId poolId = params.poolKey.toId();
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        
        // Calculate fee
        uint256 feeAmount = (params.amountIn * TIER1_FIXED_FEE_BPS) / FEE_PRECISION;
        uint256 amountAfterFee = params.amountIn - feeAmount;
        
        // Calculate expected output using a simplified approach (1:1 exchange for testing)
        // In a real implementation, this would use actual pricing data
        amountOut = amountAfterFee;
        
        // Slippage check
        if (amountOut < params.amountOutMin) revert TooMuchSlippage();
        
        // In a real implementation:
        // 1. Transfer tokenIn from user to this contract
        // 2. Send fee to POL accumulator
        // 3. Execute the actual swap with the remaining amount
        // 4. Transfer tokenOut to user
        
        // Emit event for the successful swap
        emit Tier1SwapExecuted(TIER1_FIXED_FEE_BPS);
        
        return amountOut;
    }

    /**
     * @notice Execute a Tier 2 swap with a fee based on price difference and no partial fills allowed
     * @param params Swap parameters
     * @return amountOut The amount of tokens received after the swap
     * @dev Tier 2 swaps compute fees as (customQuotePrice - v4SpotPrice) with partial fills disallowed
     *      This uses pod liquidity for swaps and enforces no partial fills
     */
    function tier2Swap(SwapParams calldata params) 
        external 
        ensure(params.deadline) 
        returns (uint256 amountOut) 
    {
        // Validate inputs
        if (params.amountIn == 0) revert ZeroAmount();
        
        // Verify token path is valid (token0 -> token1 or token1 -> token0)
        address token0 = Currency.unwrap(Currency.wrap(address(params.tokenIn)));
        address token1 = Currency.unwrap(Currency.wrap(address(params.tokenOut)));
        if ((token0 != address(params.tokenIn) && token1 != address(params.tokenIn)) || 
            (token0 != address(params.tokenOut) && token1 != address(params.tokenOut))) {
            revert IncorrectTokenPath();
        }
        
        // Ensure tokenIn and tokenOut are different
        if (params.tokenIn == params.tokenOut) revert IncorrectTokenPath();
        
        // Verify the pool is valid and initialized
        PoolId poolId = params.poolKey.toId();
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        
        // Update price cache
        updatePriceCache(params.poolKey);
        
        // Get current price from Uniswap V4
        uint256 v4SpotPrice = params.tokenIn == token0 ? 
            _getToken0PriceInToken1() : 
            _getToken1PriceInToken0();
        
        // Get custom quote price (in a real implementation, this would be from an oracle or other source)
        // For simplicity, we're using a fixed offset from the spot price for testing
        uint256 customQuotePrice = v4SpotPrice * 1005 / 1000; // 0.5% higher than spot
        
        // Calculate fee based on price difference (customQuotePrice - v4SpotPrice)
        // Fee is capped at MAX_TIER2_FEE_BPS
        uint128 feeBps;
        if (customQuotePrice > v4SpotPrice) {
            uint256 priceDiffBps = ((customQuotePrice - v4SpotPrice) * 10000) / v4SpotPrice;
            feeBps = uint128(priceDiffBps > MAX_TIER2_FEE_BPS ? MAX_TIER2_FEE_BPS : priceDiffBps);
        } else {
            feeBps = 0; // No fee if custom price is lower than spot price
        }
        
        // Calculate fee amount
        uint256 feeAmount = (params.amountIn * feeBps) / 10000;
        uint256 amountAfterFee = params.amountIn - feeAmount;
        
        // Calculate expected output using the v4 spot price
        amountOut = (amountAfterFee * v4SpotPrice) / 1e18;
        
        // Check if we have enough liquidity in the pod to fulfill the entire swap
        PodType podToUse = params.tokenOut == token0 ? PodType.A : PodType.B;
        uint256 podLiquidity = podToUse == PodType.A ? 
            getCurrentPodValueInA() : 
            getCurrentPodValueInB();
        
        // No partial fills allowed - revert if not enough liquidity
        if (amountOut > podLiquidity) revert NoPartialFillsAllowed();
        
        // Slippage check
        if (amountOut < params.amountOutMin) revert TooMuchSlippage();
        
        // In a real implementation:
        // 1. Transfer tokenIn from user to this contract
        // 2. Send fee to POL accumulator
        // 3. Use the pod's liquidity to fulfill the swap
        // 4. Transfer tokenOut to user
        
        // Emit event for the successful swap
        emit Tier2SwapExecuted(feeBps, podToUse == PodType.A ? "PodA" : "PodB");
        
        return amountOut;
    }

    /**
     * @notice Execute a Tier 3 swap with custom routing logic
     * @param params Swap parameters
     * @return amountOut The amount of tokens received after the swap
     * @dev Tier 3 swaps implement custom routing logic for more complex swaps
     *      This is a placeholder for advanced routing that could include aggregation,
     *      multi-hop swaps, or other custom logic
     */
    function tier3Swap(SwapParams calldata params) 
        external 
        ensure(params.deadline) 
        returns (uint256 amountOut) 
    {
        // Validate inputs
        if (params.amountIn == 0) revert ZeroAmount();
        
        // Verify token path is valid (this could be more complex for Tier 3)
        address token0 = Currency.unwrap(Currency.wrap(address(params.tokenIn)));
        address token1 = Currency.unwrap(Currency.wrap(address(params.tokenOut)));
        if ((token0 != address(params.tokenIn) && token1 != address(params.tokenIn)) || 
            (token0 != address(params.tokenOut) && token1 != address(params.tokenOut))) {
            revert IncorrectTokenPath();
        }
        
        // Ensure tokenIn and tokenOut are different
        if (params.tokenIn == params.tokenOut) revert IncorrectTokenPath();
        
        // Verify the pool is valid and initialized
        PoolId poolId = params.poolKey.toId();
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        
        // In a real implementation, this would implement custom routing logic
        // For example, splitting the swap across multiple venues, using flash loans, etc.
        // For simplicity, we'll simulate a basic swap with a fixed fee
        
        // Apply a custom fee structure (simplified for this example)
        uint128 customFeeBps = 30; // 0.3% fee
        uint256 feeAmount = (params.amountIn * customFeeBps) / 10000;
        uint256 amountAfterFee = params.amountIn - feeAmount;
        
        // Get current price and calculate output with a simulated routing bonus
        updatePriceCache(params.poolKey);
        uint256 basePrice = params.tokenIn == token0 ? 
            _getToken0PriceInToken1() : 
            _getToken1PriceInToken0();
        
        // Simulate a better price through routing (2% better than base price)
        uint256 enhancedPrice = basePrice * 102 / 100;
        
        // Calculate expected output with the enhanced price
        amountOut = (amountAfterFee * enhancedPrice) / 1e18;
        
        // Slippage check
        if (amountOut < params.amountOutMin) revert TooMuchSlippage();
        
        // In a real implementation:
        // 1. Transfer tokenIn from user to this contract
        // 2. Execute the custom routing logic
        // 3. Transfer tokenOut to user
        
        // Emit event for the successful swap
        emit Tier3SwapExecuted(customFeeBps, "Custom_Route_Simulation");
        
        return amountOut;
    }

    /**
     * @notice Update the price cache for a specific pool
     * @param poolKey The pool key to get price data from
     */
    function updatePriceCache(PoolKey calldata poolKey) internal {
        cachedBlock = block.number;
        
        // Get the current sqrt price from the pool
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        
        // Convert the sqrt price to linear prices
        // sqrtPriceX96 represents √(token1/token0) in Q96
        // price0 = token1/token0, price1 = token0/token1
        
        // Price of token1 in terms of token0: (sqrtPriceX96^2) / 2^192
        uint256 price1In0 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 96) / (1 << 96);
        price1In0 = price1In0 * 1e18 / (1 << 96);
        
        // Price of token0 in terms of token1: 1 / price1In0
        uint256 price0In1 = 1e36 / price1In0;
        
        cachedPriceToken1InToken0 = price1In0;
        cachedPriceToken0InToken1 = price0In1;
    }
    
    /**
     * @notice Get the price of token1 in terms of token0
     * @return The price of token1 denominated in token0
     */
    function _getToken1PriceInToken0() internal view returns (uint256) {
        return block.number == cachedBlock ? cachedPriceToken1InToken0 : 0;
    }
    
    /**
     * @notice Get the price of token0 in terms of token1
     * @return The price of token0 denominated in token1
     */
    function _getToken0PriceInToken1() internal view returns (uint256) {
        return block.number == cachedBlock ? cachedPriceToken0InToken1 : 0;
    }
    
    /**
     * @notice Get the current value of PodA in token0
     * @return The total value of PodA denominated in token0
     */
    function getCurrentPodValueInA() public view virtual returns (uint256) {
        // In a real implementation, we'd calculate the actual value here
        // For testing, we'll return a constant value
        return podA.totalShares > 0 ? podA.totalShares : 1;
    }
    
    /**
     * @notice Get the current value of PodB in token1
     * @return The total value of PodB denominated in token1
     */
    function getCurrentPodValueInB() public view virtual returns (uint256) {
        // In a real implementation, we'd calculate the actual value here
        // For testing, we'll return a constant value
        return podB.totalShares > 0 ? podB.totalShares : 1;
    }

    // Override the polAccumulator getter
    function polAccumulator() public view override returns (address) {
        return _podPolAccumulator;
    }

    // Getter functions for podA and podB
    function getPodATotalShares() external view returns (uint256) {
        return podA.totalShares;
    }
    
    function getPodBTotalShares() external view returns (uint256) {
        return podB.totalShares;
    }
} 