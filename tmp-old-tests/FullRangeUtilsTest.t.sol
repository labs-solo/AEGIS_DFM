// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/*
 * This test file has been moved to old-tests and commented out.
 * It is kept for reference but is no longer used in the project.
 * The new testing approach uses LocalUniswapV4TestBase.t.sol for local deployments.
 */

/*

/**
 * @title SpotUtilsTest
 * @notice Unit tests for the SpotUtils library introduced in Phase 6,
 *         ensuring 90%+ coverage across ratio-based deposit logic, partial withdrawal,
 *         and leftover token pulling.
 */

import "forge-std/Test.sol";
import "../src/utils/FullRangeUtils.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/**
 * @dev Minimal mock for an ERC20 token implementing IERC20Minimal
 */
contract MockERC20 is IERC20Minimal {
    string public name = "MockToken";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    
    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;
    
    function transfer(address to, uint256 amount) external returns (bool) {
        revert("not used in test, only transferFrom");
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balances[from] >= amount, "InsufficientBalance");
        require(allowances[from][msg.sender] >= amount, "InsufficientAllowance");
        balances[from] -= amount;
        allowances[from][msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }
    
    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }
    
    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }
    
    function mint(address to, uint256 amount) external {
        balances[to] += amount;
        totalSupply += amount;
    }
}

/**
 * @dev Helper contract to use the library functions
 */
contract FullRangeUtilsHelper {
    using FullRangeUtils for uint128;

    function computeDepositAmountsAndShares(
        uint128 oldLiquidity,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) public pure returns (uint256 actual0, uint256 actual1, uint256 sharesMinted) {
        return FullRangeUtils.computeDepositAmountsAndShares(
            oldLiquidity, 
            amount0Desired, 
            amount1Desired
        );
    }

    function computeWithdrawAmounts(
        uint128 oldLiquidity,
        uint256 sharesToBurn,
        uint256 reserve0,
        uint256 reserve1
    ) public pure returns (uint256 amount0Out, uint256 amount1Out) {
        return FullRangeUtils.computeWithdrawAmounts(
            oldLiquidity,
            sharesToBurn,
            reserve0,
            reserve1
        );
    }

    function pullTokensFromUser(
        address token0,
        address token1,
        address user,
        uint256 actual0,
        uint256 actual1
    ) public {
        FullRangeUtils.pullTokensFromUser(
            token0,
            token1,
            user,
            actual0,
            actual1
        );
    }
}

/**
 * @dev Test harness
 */
contract FullRangeUtilsTest is Test {
    FullRangeUtilsHelper helper;

    function setUp() public {
        helper = new FullRangeUtilsHelper();
    }

    function testComputeDepositAmountsAndSharesNoLiquidity() public {
        // oldLiquidity == 0 => entire user input
        (uint256 act0, uint256 act1, uint256 shares) =
            helper.computeDepositAmountsAndShares(0, 1000, 2000);
        assertEq(act0, 1000, "Should use entire desired 0");
        assertEq(act1, 2000, "Should use entire desired 1");
        // shares ~ sqrt(1000*2000)
        // sqrt(2e6) ~ 1414
        assertEq(shares, 1414, "should be ~1414 for demonstration");
    }

    function testComputeDepositAmountsAndSharesWithLiquidity() public {
        // oldLiquidity != 0 => ratio-based clamp (placeholder)
        (uint256 act0, uint256 act1, uint256 shares) =
            helper.computeDepositAmountsAndShares(2000, 3000, 6000);
        // placeholder => entire amounts
        assertEq(act0, 3000);
        assertEq(act1, 6000);
        // sqrt(3000*6000)= sqrt(18e6) ~4242
        assertEq(shares, 4242);
    }

    function testComputeWithdrawAmountsZeroLiquidity() public {
        (uint256 out0, uint256 out1) = helper.computeWithdrawAmounts(0, 100, 1000, 1000);
        assertEq(out0, 0);
        assertEq(out1, 0);
    }

    function testComputeWithdrawAmountsPartial() public {
        // oldLiquidity=2000 => sharesToBurn=500 => fraction=500/2000=1/4
        (uint256 out0, uint256 out1) = helper.computeWithdrawAmounts(2000, 500, 1000, 2000);
        // out0=1/4 *1000=250, out1=1/4 *2000=500
        assertEq(out0, 250);
        assertEq(out1, 500);
    }

    function testComputeWithdrawAmountsFull() public {
        // Full withdrawal (100%)
        (uint256 out0, uint256 out1) = helper.computeWithdrawAmounts(1000, 1000, 5000, 10000);
        // 100% of reserves
        assertEq(out0, 5000);
        assertEq(out1, 10000);
    }

    function testPullTokensFromUserSuccess() public {
        MockERC20 tk0 = new MockERC20();
        MockERC20 tk1 = new MockERC20();
        // Mint tokens to user
        address user = address(0x9999);
        tk0.mint(user, 5000);
        tk1.mint(user, 10000);

        // user approves
        vm.startPrank(user);
        tk0.approve(address(helper), 3000);
        tk1.approve(address(helper), 3000);
        vm.stopPrank();

        // now call the library function through helper
        helper.pullTokensFromUser(address(tk0), address(tk1), user, 2000, 1000);
        
        // Check balances
        // user should have spent 2000 tk0 + 1000 tk1
        assertEq(tk0.balanceOf(user), 3000, "tk0 leftover is 5000-2000=3000");
        assertEq(tk1.balanceOf(user), 9000, "tk1 leftover is 10000-1000=9000");
        assertEq(tk0.balanceOf(address(helper)), 2000, "contract has 2000 tk0");
        assertEq(tk1.balanceOf(address(helper)), 1000, "contract has 1000 tk1");
    }

    function testPullTokensFromUserZeroAmounts() public {
        MockERC20 tk0 = new MockERC20();
        MockERC20 tk1 = new MockERC20();
        address user = address(0x9999);
        tk0.mint(user, 5000);
        tk1.mint(user, 10000);

        // Test with zero amounts - should not transfer anything
        helper.pullTokensFromUser(address(tk0), address(tk1), user, 0, 0);
        
        // Check balances remain unchanged
        assertEq(tk0.balanceOf(user), 5000);
        assertEq(tk1.balanceOf(user), 10000);
        assertEq(tk0.balanceOf(address(helper)), 0);
        assertEq(tk1.balanceOf(address(helper)), 0);
    }

    function testPullTokensFromUserInsufficientAllowanceToken0() public {
        MockERC20 tk0 = new MockERC20();
        MockERC20 tk1 = new MockERC20();
        address user = address(0x9999);
        tk0.mint(user, 5000);
        tk1.mint(user, 10000);

        vm.startPrank(user);
        // no approvals => 0
        vm.stopPrank();

        vm.expectRevert(FullRangeUtils.InsufficientAllowanceToken0.selector);
        helper.pullTokensFromUser(address(tk0), address(tk1), user, 500, 1000);
    }

    function testPullTokensFromUserInsufficientAllowanceToken1() public {
        MockERC20 tk0 = new MockERC20();
        MockERC20 tk1 = new MockERC20();
        address user = address(0x9999);
        tk0.mint(user, 5000);
        tk1.mint(user, 10000);

        vm.startPrank(user);
        // only approve tk0
        tk0.approve(address(helper), 5000);
        vm.stopPrank();

        vm.expectRevert(FullRangeUtils.InsufficientAllowanceToken1.selector);
        helper.pullTokensFromUser(address(tk0), address(tk1), user, 500, 800);
    }

    function testPullTokensFromUserPartialAllowance() public {
        MockERC20 tk0 = new MockERC20();
        MockERC20 tk1 = new MockERC20();
        address user = address(0x9999);
        tk0.mint(user, 5000);
        tk1.mint(user, 10000);

        vm.startPrank(user);
        // Approve less than balance
        tk0.approve(address(helper), 1000);
        tk1.approve(address(helper), 2000);
        vm.stopPrank();

        // Should work with amounts <= allowance
        helper.pullTokensFromUser(address(tk0), address(tk1), user, 1000, 1500);
        
        // Check balances
        assertEq(tk0.balanceOf(user), 4000);
        assertEq(tk1.balanceOf(user), 8500);
        assertEq(tk0.balanceOf(address(helper)), 1000);
        assertEq(tk1.balanceOf(address(helper)), 1500);
    }
} 
*/
