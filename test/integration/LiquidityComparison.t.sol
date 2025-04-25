// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ForkSetup} from "./ForkSetup.t.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {FullRangeLiquidityManager} from "src/FullRangeLiquidityManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {MathUtils} from "src/libraries/MathUtils.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {CurrencySettler} from "uniswap-hooks/utils/CurrencySettler.sol";

contract LiquidityComparisonTest is ForkSetup, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeTransferLib for ERC20;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencySettler for Currency;

    address public lpProvider;
    uint128 public constant MIN_LIQUIDITY = 1_000;

    // ──────────────────────────────────────────────
    //  scratch-vars populated inside the callbacks
    // ──────────────────────────────────────────────
    uint256 private used0Direct_;
    uint256 private used1Direct_;

    // handy aliases to the objects ForkSetup already deploys
    IPoolManager internal manager_;
    FullRangeLiquidityManager internal frlm_;
    IERC20Minimal internal token0;   // USDC in this test-pool
    IERC20Minimal internal token1;   // WETH in this test-pool

    // Callback data for direct minting
    struct CallbackData {
        PoolKey poolKey;
        int24  tickLower;
        int24  tickUpper;
        uint128 liquidity;   // precalculated
    }

    function setUp() public override {
        super.setUp();
        lpProvider = makeAddr("lpProvider");

        // wire-up the live contracts from ForkSetup
        manager_ = poolManager;
        frlm_    = liquidityManager;
        token0   = usdc;
        token1   = weth;

        // Fund test account
        vm.startPrank(deployerEOA);
        uint256 amount0 = 29_999_999_973;   // 29 999 999 .973  USDC (6 dec)
        uint256 amount1 = 10 ether;         // 10 WETH
        deal(address(token0), lpProvider, amount0);
        deal(address(token1), lpProvider, amount1);
        // also give the test-contract its own funds (for the "direct" path)
        deal(address(token0), address(this), amount0);
        deal(address(token1), address(this), amount1);
        vm.stopPrank();

        // Setup approvals
        _dealAndApprove(token0, lpProvider, amount0);
        _dealAndApprove(token1, lpProvider, amount1);
        token0.approve(address(manager_), amount0);
        token1.approve(address(manager_), amount1);
    }

    function test_compareDirectVsFRLM() public {
        // Test constants
        uint256 amount0 = 29_999_999_973;   // 29 999 999 .973  USDC (6 dec)
        uint256 amount1 = 10 ether;         // 10 WETH

        // Get current pool price
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager_, poolKey.toId());
        require(sqrtPriceX96 > 0, "Invalid pool price");

        // Calculate liquidity for the full range
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        // ───────────────────────────────────────────────────────────
        // ① Direct PoolManager liquidity addition through unlock callback
        // ───────────────────────────────────────────────────────────
        CallbackData memory cbData = CallbackData({
            poolKey:   poolKey,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity
        });

        manager_.unlock(abi.encode(cbData));
        uint256 used0Direct = used0Direct_;
        uint256 used1Direct = used1Direct_;

        // ───────────────────────────────────────────────────────────
        // ② Same deposit through FullRangeLiquidityManager (lpProvider)
        // ───────────────────────────────────────────────────────────
        vm.startPrank(lpProvider);
        (uint256 shares, uint256 used0Frlm, uint256 used1Frlm) = frlm_.deposit(
            poolKey.toId(),
            amount0,
            amount1,
            0, // min amount0
            0, // min amount1
            lpProvider
        );

        // Get the actual liquidity from both positions
        bytes32 posKeyDirect = Position.calculatePositionKey(
            address(this), tickLower, tickUpper, bytes32(0)
        );
        uint128 liqDirect = StateLibrary.getPositionLiquidity(manager_, poolKey.toId(), posKeyDirect);
        
        (uint128 liqFrlm,,) = frlm_.getPositionData(poolKey.toId());
        
        // Account for MIN_LIQUIDITY if this is first deposit
        uint128 totalShares = frlm_.positionTotalShares(poolKey.toId());
        if (totalShares == shares) {
            // First deposit: discount the permanently-locked liquidity
            liqFrlm -= MIN_LIQUIDITY; // types now match (uint128)
        }

        // Compare liquidity values (should match exactly)
        assertEq(liqDirect, liqFrlm, "liquidity mismatch");
        
        // Compare token amounts used (allow ±1 wei difference due to FRLM rounding)
        assertLe(
            MathUtils.abs(int256(used0Direct) - int256(used0Frlm)),
            1,
            "token0 diff exceeds 1 wei"
        );
        assertLe(
            MathUtils.abs(int256(used1Direct) - int256(used1Frlm)),
            1,
            "token1 diff exceeds 1 wei"
        );

        vm.stopPrank();
    }

    // settles the owed tokens
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager_), "only manager");
        CallbackData memory d = abi.decode(data, (CallbackData));

        IPoolManager.ModifyLiquidityParams memory p = IPoolManager.ModifyLiquidityParams({
            tickLower: d.tickLower,
            tickUpper: d.tickUpper,
            liquidityDelta: int256(uint256(d.liquidity)),
            salt: bytes32(0)
        });

        (BalanceDelta delta,) = manager_.modifyLiquidity(d.poolKey, p, "");

        used0Direct_ = uint256(uint128(-delta.amount0()));
        used1Direct_ = uint256(uint128(-delta.amount1()));

        // ─── settle the two ERC-20 debts so PoolManager's books balance ───
        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));

        if (used0Direct_ > 0) {
            // CurrencySettler: sync → transfer → settle
            currency0.settle(manager_, address(this), used0Direct_, /*burn*/ false);
        }
        if (used1Direct_ > 0) {
            currency1.settle(manager_, address(this), used1Direct_, /*burn*/ false);
        }

        // Return zero delta to indicate all debts are settled
        BalanceDelta zeroDelta;
        return abi.encode(zeroDelta);
    }

    // Helper to deal and approve tokens
    function _dealAndApprove(IERC20Minimal token, address recipient, uint256 amount) internal {
        address tokenAddr = address(token);
        deal(tokenAddr, recipient, amount);
        vm.startPrank(recipient);
        token.approve(address(manager_), amount);
        token.approve(address(frlm_), amount);
        vm.stopPrank();
    }
} 