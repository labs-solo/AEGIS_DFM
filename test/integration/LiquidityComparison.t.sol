// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ForkSetup} from "./ForkSetup.t.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts}       from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IFullRangeLiquidityManager} from "src/interfaces/IFullRangeLiquidityManager.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IAllowanceTransfer}     from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ExtendedPositionManager} from "src/ExtendedPositionManager.sol";
import {Actions}                from "v4-periphery/src/libraries/Actions.sol";
import {IPositionManager}       from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

contract LiquidityComparisonTest is ForkSetup {
    using PoolIdLibrary for PoolKey;
    using SafeTransferLib for ERC20;
    using CurrencyLibrary for Currency;

    // lpProvider inherited from ForkSetup
    uint128 public constant MIN_LIQUIDITY = 1_000;

    // ──────────────────────────────────────────────
    //  scratch-vars populated inside the callbacks
    // ──────────────────────────────────────────────
    uint256 private used0Direct_;
    uint256 private used1Direct_;

    // handy aliases to the objects ForkSetup already deploys
    IPoolManager internal manager_;
    IFullRangeLiquidityManager internal frlm_;
    IERC20Minimal internal token0; // USDC in this test-pool
    IERC20Minimal internal token1; // WETH in this test-pool
    ExtendedPositionManager internal posManager;

    function setUp() public override {
        super.setUp();

        // wire-up the live contracts from ForkSetup
        manager_ = poolManager;
        frlm_ = liquidityManager;
        token0 = usdc;
        token1 = weth;
        posManager = frlm_.posManager();          // exposed as public immutable

        // Fund test account
        vm.startPrank(deployerEOA);
        uint256 amount0 = 29_999_999_973; // 29 999 999 .973  USDC (6 dec)
        uint256 amount1 = 10 ether; // 10 WETH
        deal(address(token0), lpProvider, amount0);
        deal(address(token1), lpProvider, amount1);
        // also give the test-contract its own funds (for the "direct" path)
        deal(address(token0), address(this), amount0);
        deal(address(token1), address(this), amount1);
        vm.stopPrank();

        // Setup approvals
        _dealAndApprove(token0, lpProvider, amount0);
        _dealAndApprove(token1, lpProvider, amount1);
        // Governance (deployerEOA) is the sender for the FullRangeLiquidityManager deposit – ensure it holds
        // tokens and has the necessary allowances to avoid TRANSFER_FROM_FAILED.
        _dealAndApprove(token0, deployerEOA, amount0);
        _dealAndApprove(token1, deployerEOA, amount1);
        token0.approve(address(manager_), amount0);
        token1.approve(address(manager_), amount1);

        // bootstrap not needed – oracle will learn MTB via CAP events
    }

    function test_compareDirectVsFRLM() public {
        // Test constants
        uint256 amount0 = 29_999_999_973; // 29 999 999 .973  USDC (6 dec)
        uint256 amount1 = 10 ether; // 10 WETH

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
        // ① Direct *NFT-based* full-range mint via ExtendedPositionManager
        // ───────────────────────────────────────────────────────────
        //  Allow Permit2 (used internally by PositionManager) to pull our tokens
        address permit2 = address(posManager.permit2());
        token0.approve(permit2, amount0);
        token1.approve(permit2, amount1);

        // Also grant PositionManager unlimited allowance inside Permit2
        IAllowanceTransfer(permit2).approve(address(token0), address(posManager), type(uint160).max, type(uint48).max);
        IAllowanceTransfer(permit2).approve(address(token1), address(posManager), type(uint160).max, type(uint48).max);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,          // uint128
            type(uint128).max,  // slippage guards – amount0Max
            type(uint128).max,  // amount1Max
            address(this),      // owner of the NFT
            bytes("")          // hook data
        );
        params[1] = abi.encode(
            poolKey.currency0,
            poolKey.currency1
        );

        // Snapshot balances to measure exact token usage
        uint256 bal0Before = ERC20(address(token0)).balanceOf(address(this));
        uint256 bal1Before = ERC20(address(token1)).balanceOf(address(this));

        // No ETH needed – both tokens are ERC-20
        posManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);

        // Compute token amounts spent by the direct path
        used0Direct_ = bal0Before - ERC20(address(token0)).balanceOf(address(this));
        used1Direct_ = bal1Before - ERC20(address(token1)).balanceOf(address(this));

        uint256 tokenIdDirect = posManager.nextTokenId() - 1;

        // ───────────────────────────────────────────────────────────
        // ② Same deposit through FullRangeLiquidityManager (lpProvider)
        // ───────────────────────────────────────────────────────────
        uint256 shares;

        // Snapshot balances to measure exact token usage
        uint256 bal0BeforeFrlm = ERC20(address(token0)).balanceOf(deployerEOA);
        uint256 bal1BeforeFrlm = ERC20(address(token1)).balanceOf(deployerEOA);

        vm.startPrank(deployerEOA); // deposit must be executed by governance
        (shares,,) = liquidityManager.deposit(
            poolKey.toId(), amount0, amount1, 0, 0, lpProvider
        );
        vm.stopPrank();

        // Calculate actual tokens used by FRLM path
        uint256 used0Frlm = bal0BeforeFrlm - ERC20(address(token0)).balanceOf(deployerEOA);
        uint256 used1Frlm = bal1BeforeFrlm - ERC20(address(token1)).balanceOf(deployerEOA);

        // ───────────────────────────────────────────────────────────
        // ③ Compare NFT liquidities via PositionManager helper
        // ───────────────────────────────────────────────────────────
        uint256 tokenIdFrlm = frlm_.positionTokenId(poolKey.toId());

        (PoolKey memory poolKeyDir, PositionInfo pDir)  = posManager.getPoolAndPositionInfo(tokenIdDirect);
        (PoolKey memory poolKeyFrlm, PositionInfo pFrlm) = posManager.getPoolAndPositionInfo(tokenIdFrlm);

        // Get actual liquidity from each position
        uint128 liqDirect = posManager.getPositionLiquidity(tokenIdDirect);
        uint128 liqFrlm = posManager.getPositionLiquidity(tokenIdFrlm);

        // Both NFTs must hold the *same* v4-liquidity (+/-1 wei tolerance)
        assertApproxEqAbs(liqDirect, liqFrlm, 1, "liquidity mismatch");

        // Bonus sanity-check: each path consumed (almost) identical token amounts
        // (differences ≤ 1 wei are tolerated due to rounding)
        assertLe(SignedMath.abs(int256(used0Direct_) - int256(used0Frlm)), 1, "token0 diff >1");
        assertLe(SignedMath.abs(int256(used1Direct_) - int256(used1Frlm)), 1, "token1 diff >1");
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
