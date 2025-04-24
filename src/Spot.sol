// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/* ───────────────────────────────────────────────────────────
 *                     Core & Periphery
 * ─────────────────────────────────────────────────────────── */
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {LibTransient} from "./libraries/LibTransient.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

/* ───────────────────────────────────────────────────────────
 *                          Project
 * ─────────────────────────────────────────────────────────── */
import {IFullRangeLiquidityManager} from "./interfaces/IFullRangeLiquidityManager.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {ISpot, DepositParams, WithdrawParams} from "./interfaces/ISpot.sol";
import {ISpotHooks} from "./interfaces/ISpotHooks.sol";
import {ITruncGeoOracleMulti} from "./interfaces/ITruncGeoOracleMulti.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {IDynamicFeeManager} from "./interfaces/IDynamicFeeManager.sol";
import {DynamicFeeManager} from "./DynamicFeeManager.sol";
import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";
import {TruncGeoOracleMulti} from "./TruncGeoOracleMulti.sol";
import {MathUtils} from "./libraries/MathUtils.sol";
import {TickMoveGuard} from "./libraries/TickMoveGuard.sol";
import {Errors} from "./errors/Errors.sol";
import {CurrencySettlerExtension} from "./utils/CurrencySettlerExtension.sol";

/* ───────────────────────────────────────────────────────────
 *                    Solmate / OpenZeppelin
 * ─────────────────────────────────────────────────────────── */
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

/* ───────────────────────────────────────────────────────────
 *                       Contract: Spot
 * ─────────────────────────────────────────────────────────── */
contract Spot is BaseHook, ISpot, ISpotHooks, IUnlockCallback, ReentrancyGuard, Owned {
    using PoolIdLibrary for PoolKey;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    /* ───────────── Custom errors for gas optimization ───────────── */
    error ImmutableDependencyDeprecated(string dependency);
    error CustomZeroAddress();

    /* ───────────────────────── State ───────────────────────── */
    IPoolPolicy public immutable policyManager;
    IFullRangeLiquidityManager public immutable liquidityManager;
    
    TruncGeoOracleMulti public immutable truncGeoOracle;
    IDynamicFeeManager public immutable feeManager;

    // Gas stipend for external calls to prevent re-entrancy
    uint256 private constant GAS_STIPEND = 100000;

    struct PoolData {
        bool initialized;
        bool emergencyState;
        uint64 lastSwapTs; // last swap timestamp
    }

    mapping(bytes32 => PoolData) public poolData; // pid → data
    mapping(bytes32 => PoolKey) public poolKeys; // pid → key

    /*  reinvest settings         */
    struct ReinvestConfig {
        uint256 minToken0;
        uint256 minToken1;
        uint64 last; // last execution ts
        uint64 cooldown; // seconds
    }

    mapping(bytes32 => ReinvestConfig) public reinvestCfg; // pid → cfg

    /// @notice Global pause for protocol‑fee reinvest
    bool public reinvestmentPaused;

    event ReinvestmentPauseToggled(bool paused);
    
    // Add a deprecation event
    event DependencySetterDeprecated(string name);

    // Skip‑reason constants
    string private constant REASON_GLOBAL_PAUSED = "globalPaused";
    string private constant REASON_COOLDOWN = "cooldown";
    string private constant REASON_THRESHOLD = "threshold";
    string private constant REASON_PRICE_ZERO = "price=0";
    string private constant REASON_LIQUIDITY_ZERO = "liquidity=0";
    string private constant REASON_MINTED_ZERO = "minted=0";

    // --- ADDED EVENT DECLARATIONS ---
    event ReinvestmentSuccess(bytes32 indexed poolId, uint256 used0, uint256 used1);
    event ReinvestSkipped(bytes32 indexed poolId, string reason, uint256 balance0, uint256 balance1);
    event PoolEmergencyStateChanged(bytes32 indexed poolId, bool isEmergency);
    event Deposit(address indexed sender, bytes32 indexed poolId, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdraw(address indexed sender, bytes32 indexed poolId, uint256 amount0, uint256 amount1, uint256 shares);
    event OracleInitialized(bytes32 indexed poolId, int24 initialTick, int24 maxAbsTickMove);
    event OracleInitializationFailed(bytes32 indexed poolId, bytes reason);
    event PolicyInitializationFailed(bytes32 indexed poolId, string reason);
    // --- END ADDED EVENT DECLARATIONS ---

    /* ──────────────────────── Constructor ───────────────────── */
    constructor(
        IPoolManager _manager,
        IPoolPolicy _policyManager,
        IFullRangeLiquidityManager _liquidityManager,
        TruncGeoOracleMulti _oracle,
        IDynamicFeeManager _feeManager,
        address _initialOwner
    ) BaseHook(_manager) Owned(_initialOwner) {
        if (address(_manager) == address(0)) revert CustomZeroAddress();
        if (address(_policyManager) == address(0)) revert CustomZeroAddress();
        if (address(_liquidityManager) == address(0)) revert CustomZeroAddress();
        if (address(_oracle) == address(0)) revert CustomZeroAddress();
        if (address(_feeManager) == address(0)) revert CustomZeroAddress();

        policyManager = _policyManager;
        liquidityManager = _liquidityManager;
        truncGeoOracle = _oracle;
        feeManager = _feeManager;
    }

    receive() external payable {}

    /* ───────────────────── Hook Permissions ─────────────────── */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /* ──────────────────── Interface Impl ───────────────────── */
    // Required by ISpot
    function getHookAddress() external view override returns (address) {
        return address(this);
    }

    /* ──────────────────────── Internals ─────────────────────── */

    function _processFees(bytes32 _poolId, BalanceDelta feesAccrued) internal {
        if ((feesAccrued.amount0() <= 0 && feesAccrued.amount1() <= 0) || address(policyManager) == address(0)) {
            return;
        }
        // Directly attempt reinvestment if fees were accrued
        // No need to check for policyManager or emit ReinvestmentSuccess here,
        // _tryReinvestInternal handles its own emissions.
        PoolKey memory key = poolKeys[_poolId]; // Get the key needed for _tryReinvestInternal
        if (key.tickSpacing != 0) {
            // Ensure the key is valid
            _tryReinvestInternal(key, _poolId);
        }
    }

    function _processSwapFees(bytes32 pid, BalanceDelta feesAccrued) internal {
        _processFees(pid, feesAccrued);
    }

    function _processRemoveLiquidityFees(bytes32 _poolId, BalanceDelta feesAccrued) internal {
        _processFees(_poolId, feesAccrued);
    }

    /* ─────────────────── Hook: beforeSwap ───────────────────── */
    function _beforeSwap(
        address, /* sender */
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata /* hookData */
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (address(feeManager) == address(0)) {
            revert Errors.NotInitialized("DynamicFeeManager");
        }

        // ------------------------------------------------------------
        // 1. Fee that WILL apply (oracle decides capping internally)
        // ------------------------------------------------------------
        (uint256 baseRaw, uint256 surgeRaw) = feeManager.getFeeState(key.toId());
        uint24 base = uint24(baseRaw);
        uint24 surge = uint24(surgeRaw);
        uint24 fee = base + surge;

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    /* ─────────────────── Hook: afterSwap ────────────────────── */
    /**
     * @notice Processes the post-swap operations including oracle update and fee management
     * @dev Critical path that forwards the CAP flag from oracle to DynamicFeeManager, 
     *      ensuring dynamic fee adjustments work properly
     * @param key The pool key identifying which pool is being interacted with
     * @param params The swap parameters including direction (zeroForOne)
     * @param delta The balance delta resulting from the swap
     */
    function _afterSwap(
        address, /* sender */
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata /* hookData */
    ) internal override returns (bytes4, int128) {
        // 1) Push tick to oracle, also get the CAP flag
        (int24 tick, bool capped) =
            truncGeoOracle.pushObservationAndCheckCap(key.toId(), params.zeroForOne);

        // 2) Feed the DynamicFeeManager - using gas stipend to prevent re-entrancy
        //    - `Spot` itself is the authorised hook
        feeManager.notifyOracleUpdate{gas: GAS_STIPEND}(key.toId(), capped);

        // 3) accrue any LP/PROTOCOL fees
        _processSwapFees(PoolId.unwrap(key.toId()), delta);

        return (BaseHook.afterSwap.selector, 0);
    }

    /// -------- helpers ----------------------------------------------------

    /* ───────────────── afterAddLiquidity hook ───────────────── */
    function _afterAddLiquidity(
        address, /* sender */
        PoolKey calldata, /* key */
        IPoolManager.ModifyLiquidityParams calldata, /* params */
        BalanceDelta, /* delta */
        BalanceDelta, /* feesAccrued */ // Likely zero on initial add
        bytes calldata /* hookData */
    ) internal override returns (bytes4, BalanceDelta) {
        // Optional: Process fees accrued during add liquidity (uncommon for standard full-range add)
        // bytes32 _poolId = PoolId.unwrap(key.toId());
        // _processFees(_poolId, IFeeReinvestmentManager.OperationType.DEPOSIT, feesAccrued);
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /* ──────────────── afterRemoveLiquidity hook ─────────────── */
    function _afterRemoveLiquidity(
        address, /* sender */
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata, /* params */
        BalanceDelta, /* delta */
        BalanceDelta feesAccrued,
        bytes calldata /* hookData */
    ) internal override returns (bytes4, BalanceDelta) {
        _processRemoveLiquidityFees(PoolId.unwrap(key.toId()), feesAccrued);
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /* ────────── External "return-delta" wrappers ────────────── */
    function beforeSwapReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta) {
        if (msg.sender != address(poolManager)) {
            revert Errors.CallerNotPoolManager(msg.sender);
        }

        (, BeforeSwapDelta d,) = _beforeSwap(sender, key, params, hookData);
        return (ISpotHooks.beforeSwapReturnDelta.selector, d);
    }

    function afterSwapReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
        if (msg.sender != address(poolManager)) {
            revert Errors.CallerNotPoolManager(msg.sender);
        }

        _afterSwap(sender, key, params, delta, hookData);
        return (ISpotHooks.afterSwapReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterAddLiquidityReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
        if (msg.sender != address(poolManager)) {
            revert Errors.CallerNotPoolManager(msg.sender);
        }

        _afterAddLiquidity(sender, key, params, delta, BalanceDeltaLibrary.ZERO_DELTA, hookData);

        return (ISpotHooks.afterAddLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidityReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
        if (msg.sender != address(poolManager)) {
            revert Errors.CallerNotPoolManager(msg.sender);
        }

        _afterRemoveLiquidity(sender, key, params, delta, feesAccrued, hookData);

        return (ISpotHooks.afterRemoveLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /* ───────────────── Other Functions (Omitted for Brevity) ─────────────── */
    // ... deposit(), withdraw(), unlockCallback(), _afterInitialize(), getters, setters, reinvest logic ...

    // Adding placeholders for the omitted functions to satisfy the contract structure
    // These should be replaced with the actual implementations from the previous version

    modifier onlyGovernance() {
        address currentOwner = (address(policyManager) != address(0)) ? policyManager.getSoloGovernance() : owner;
        if (msg.sender != currentOwner) {
            revert Errors.AccessOnlyGovernance(msg.sender);
        }
        _;
    }

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) {
            revert Errors.DeadlinePassed(uint32(deadline), uint32(block.timestamp));
        }
        _;
    }

    function deposit(DepositParams calldata params)
        external
        payable
        virtual
        nonReentrant
        ensure(params.deadline)
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        bytes32 _poolId = PoolId.unwrap(params.poolId);
        PoolData storage data = poolData[_poolId];
        if (!data.initialized) revert Errors.PoolNotInitialized(_poolId);
        if (data.emergencyState) revert Errors.PoolInEmergencyState(_poolId);
        PoolKey memory key = poolKeys[_poolId];
        bool hasNative = key.currency0.isAddressZero() || key.currency1.isAddressZero();
        if (msg.value > 0 && !hasNative) revert Errors.NonzeroNativeValue();
        (shares, amount0, amount1) = liquidityManager.deposit{value: msg.value}(
            params.poolId,
            params.amount0Desired,
            params.amount1Desired,
            params.amount0Min,
            params.amount1Min,
            msg.sender
        );
        emit Deposit(msg.sender, _poolId, amount0, amount1, shares);
        return (shares, amount0, amount1);
    }

    function withdraw(WithdrawParams calldata params)
        external
        virtual
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        bytes32 _poolId = PoolId.unwrap(params.poolId);
        PoolData storage data = poolData[_poolId];
        if (!data.initialized) revert Errors.PoolNotInitialized(_poolId);
        (amount0, amount1) = liquidityManager.withdraw(
            params.poolId, params.sharesToBurn, params.amount0Min, params.amount1Min, msg.sender
        );
        emit Withdraw(msg.sender, _poolId, amount0, amount1, params.sharesToBurn);
        return (amount0, amount1);
    }

    struct CallbackData {
        bytes32 poolId;
        uint8 callbackType;
        uint128 shares;
        uint256 amount0;
        uint256 amount1;
        address recipient;
    }

    function unlockCallback(bytes calldata data) external override(IUnlockCallback) returns (bytes memory) {
        CallbackData memory cbData = abi.decode(data, (CallbackData));
        bytes32 _poolId = cbData.poolId;
        if (!poolData[_poolId].initialized) revert Errors.PoolNotInitialized(_poolId);
        PoolKey memory key = poolKeys[_poolId];
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            liquidityDelta: 0,
            salt: bytes32(0)
        });
        if (cbData.callbackType == 1) {
            params.liquidityDelta = int256(uint256(cbData.shares));
        } else if (cbData.callbackType == 2) {
            params.liquidityDelta = -int256(uint256(cbData.shares));
        } else {
            revert("Unknown callback type");
        }
        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, params, "");

        // Handle settlement using CurrencySettlerExtension
        // For reinvest (add liquidity), delta will be negative, triggering settleCurrency
        CurrencySettlerExtension.handlePoolDelta(poolManager, delta, key.currency0, key.currency1, address(this));

        return abi.encode(delta);
    }

    function _afterInitialize(address, /* sender */ PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        virtual
        override
        returns (bytes4)
    {
        bytes32 _poolId = PoolId.unwrap(key.toId());
        if (poolData[_poolId].initialized) revert Errors.PoolAlreadyInitialized(_poolId);
        if (sqrtPriceX96 == 0) revert Errors.InvalidPrice(sqrtPriceX96);
        poolKeys[_poolId] = key;
        poolData[_poolId] = PoolData({initialized: true, emergencyState: false, lastSwapTs: uint64(block.timestamp)});
        if (address(truncGeoOracle) != address(0) && address(key.hooks) == address(this)) {
            int24 maxAbsTickMove = TickMoveGuard.HARD_ABS_CAP;
            try truncGeoOracle.enableOracleForPool(key) {
                emit OracleInitialized(_poolId, tick, maxAbsTickMove);
            } catch (bytes memory reason) {
                emit OracleInitializationFailed(_poolId, reason);
            }
        }
        if (address(policyManager) != address(0)) {
            try policyManager.handlePoolInitialization(PoolId.wrap(_poolId), key, sqrtPriceX96, tick, address(this)) {}
            catch (bytes memory reason) {
                emit PolicyInitializationFailed(_poolId, string(reason));
            }
        }
        if (address(liquidityManager) != address(0)) {
            liquidityManager.storePoolKey(PoolId.wrap(_poolId), key);
        }
        return BaseHook.afterInitialize.selector;
    }

    function getPoolInfo(PoolId poolId)
        external
        view
        virtual
        returns (bool isInitialized, uint256[2] memory reserves, uint128 totalShares, uint256 tokenId)
    {
        bytes32 _poolId = PoolId.unwrap(poolId);
        PoolData storage data = poolData[_poolId];
        isInitialized = data.initialized;
        if (isInitialized) {
            (reserves[0], reserves[1]) = liquidityManager.getPoolReserves(poolId);
            totalShares = liquidityManager.poolTotalShares(poolId);
        }
        tokenId = uint256(_poolId);
        return (isInitialized, reserves, totalShares, tokenId);
    }

    function setPoolEmergencyState(PoolId poolId, bool isEmergency) external virtual onlyGovernance {
        bytes32 _poolId = PoolId.unwrap(poolId);
        if (!poolData[_poolId].initialized) revert Errors.PoolNotInitialized(_poolId);
        poolData[_poolId].emergencyState = isEmergency;
        emit PoolEmergencyStateChanged(_poolId, isEmergency);
    }

    /**
     * @notice DEPRECATED: Oracle address is now immutable and set in constructor
     * @dev This function will always revert but is kept for backwards compatibility
     */
    function setOracleAddress(address _oracleAddress) external onlyGovernance {
        emit DependencySetterDeprecated("oracle");
        revert ImmutableDependencyDeprecated("oracle");
    }
    
    /**
     * @notice DEPRECATED: DynamicFeeManager is now immutable and set in constructor
     * @dev This function will always revert but is kept for backwards compatibility
     */
    function setDynamicFeeManager(address _dynamicFeeManager) external onlyGovernance {
        emit DependencySetterDeprecated("dynamicFeeManager");
        revert ImmutableDependencyDeprecated("dynamicFeeManager");
    }

    function setReinvestConfig(PoolId poolId, uint256 minToken0, uint256 minToken1, uint64 cooldown)
        external
        onlyGovernance
    {
        bytes32 pid = PoolId.unwrap(poolId);
        if (!poolData[pid].initialized) revert Errors.PoolNotInitialized(pid);
        ReinvestConfig storage c = reinvestCfg[pid];
        c.minToken0 = minToken0;
        c.minToken1 = minToken1;
        c.cooldown = cooldown;
    }

    function pokeReinvest(PoolId poolId) external nonReentrant {
        bytes32 pid = PoolId.unwrap(poolId);
        if (!poolData[pid].initialized) revert Errors.PoolNotInitialized(pid);
        _tryReinvestInternal(poolKeys[pid], pid);
    }

    function _tryReinvestInternal(PoolKey memory k, bytes32 pid) internal {
        (uint256 bal0, uint256 bal1) = _internalBalances(k);
        ReinvestConfig storage cfg = reinvestCfg[pid];

        // 0) global pause
        if (reinvestmentPaused) {
            emit ReinvestSkipped(pid, REASON_GLOBAL_PAUSED, bal0, bal1);
            return;
        }
        // 1) cooldown
        if (block.timestamp < cfg.last + cfg.cooldown) {
            emit ReinvestSkipped(pid, REASON_COOLDOWN, bal0, bal1);
            return;
        }
        // 2) threshold
        if (bal0 < cfg.minToken0 && bal1 < cfg.minToken1) {
            emit ReinvestSkipped(pid, REASON_THRESHOLD, bal0, bal1);
            return;
        }
        // 3) price-check
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(pid));
        if (sqrtP == 0) {
            emit ReinvestSkipped(pid, REASON_PRICE_ZERO, bal0, bal1);
            return;
        }
        // 4) maximize full‑range liquidity
        (uint256 use0, uint256 use1, uint128 liq) = MathUtils.getAmountsToMaxFullRangeRoundUp(
            sqrtP,
            k.tickSpacing,
            bal0, // Use current balance 0
            bal1 // Use current balance 1
        );
        if (liq == 0) {
            emit ReinvestSkipped(pid, REASON_LIQUIDITY_ZERO, bal0, bal1);
            return;
        }

        // 5) call LM.reinvest, passing calculated amounts and liquidity
        address token0 = Currency.unwrap(k.currency0);
        address token1 = Currency.unwrap(k.currency1);
        address lmAddress = address(liquidityManager);

        if (use0 > 0) {
            if (token0 == address(0)) {
                // Native ETH
                // Send ETH via call. Ensure Spot has enough ETH balance.
                (bool success,) = lmAddress.call{value: use0}("");
                require(success, "ETH transfer to LM failed");
            } else {
                // ERC20
                // Transfer ERC20 from Spot to LM
                SafeTransferLib.safeTransfer(ERC20(token0), lmAddress, use0);
            }
        }
        if (use1 > 0) {
            if (token1 == address(0)) {
                // Native ETH
                // Send ETH via call. Ensure Spot has enough ETH balance.
                (bool success,) = lmAddress.call{value: use1}("");
                require(success, "ETH transfer to LM failed");
            } else {
                // ERC20
                // Transfer ERC20 from Spot to LM
                SafeTransferLib.safeTransfer(ERC20(token1), lmAddress, use1);
            }
        }

        try liquidityManager.reinvest(PoolId.wrap(pid), use0, use1, liq) returns (uint128 _minted) {
            if (_minted == 0) {
                emit ReinvestSkipped(pid, REASON_MINTED_ZERO, bal0, bal1);
                return;
            }
            // success
            cfg.last = uint64(block.timestamp);
            emit ReinvestmentSuccess(pid, use0, use1);
        } catch (bytes memory reason) {
            // Handle potential reverts from LM (e.g., ZeroAmount error)
            emit ReinvestSkipped(pid, string(abi.encodePacked("LM revert: ", reason)), bal0, bal1);
            return;
        }
    }

    function _internalBalances(PoolKey memory k) internal view returns (uint256 bal0, uint256 bal1) {
        bal0 = CurrencyLibrary.balanceOf(k.currency0, address(this));
        bal1 = CurrencyLibrary.balanceOf(k.currency1, address(this));
    }

    function isValidContract(address _addr) internal view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    function getOracleData(PoolId poolId) external returns (int24 tick, uint32 blockNumber) {
        bytes32 _poolId = PoolId.unwrap(poolId);
        if (address(truncGeoOracle) != address(0) && truncGeoOracle.isOracleEnabled(poolId)) {
            try truncGeoOracle.getLatestObservation(poolId) returns (int24 _tick, uint32 _blockTimestamp) {
                return (_tick, _blockTimestamp);
            } catch {}
        }
        return (0, 0);
    }

    function getPoolKey(PoolId poolId) external view virtual returns (PoolKey memory) {
        bytes32 _poolId = PoolId.unwrap(poolId);
        if (!poolData[_poolId].initialized) revert Errors.PoolNotInitialized(_poolId);
        return poolKeys[_poolId];
    }

    function isPoolInitialized(PoolId poolId) external view virtual returns (bool) {
        return poolData[PoolId.unwrap(poolId)].initialized;
    }

    function getPoolReservesAndShares(PoolId poolId)
        external
        view
        virtual
        returns (uint256 reserve0, uint256 reserve1, uint128 totalShares)
    {
        bytes32 _poolId = PoolId.unwrap(poolId);
        if (poolData[_poolId].initialized) {
            (reserve0, reserve1) = liquidityManager.getPoolReserves(poolId);
            totalShares = liquidityManager.poolTotalShares(poolId);
        }
    }

    function getPoolTokenId(PoolId poolId) external view virtual returns (uint256) {
        return uint256(PoolId.unwrap(poolId));
    }

    /**
     * @notice Pause or resume fee‐reinvestment globally.
     */
    function setReinvestmentPaused(bool paused) external onlyGovernance {
        reinvestmentPaused = paused;
        emit ReinvestmentPauseToggled(paused);
    }
}
