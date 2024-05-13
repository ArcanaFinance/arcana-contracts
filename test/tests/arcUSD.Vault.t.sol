// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

// oz imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// local files
import {BaseSetup} from "../BaseSetup.sol";
import {arcUSDPointsBoostVault} from "../../src/arcUSDPointsBoostingVault.sol";

/**
 * @title arcUSDVaultTest
 * @notice Unit Tests for arcUSDPointsBoostVault contract interactions
 */
contract arcUSDVaultTest is BaseSetup {
    function setUp() public override {
        super.setUp();
    }

    function test_vault_init_state() public {
        assertEq(arcUSDVault.arcUSD(), address(arcUSDToken));
        assertEq(arcUSDVault.totalSupply(), type(uint256).max);
    }

    function test_vault_deposit() public {
        // ~ Config ~

        uint256 amount = 10 ether;
        vm.prank(address(arcMinter));
        arcUSDToken.mint(bob, amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(bob), amount);
        assertEq(arcUSDToken.balanceOf(address(arcUSDVault)), 0);
        assertEq(arcUSDVault.balanceOf(bob), 0);

        uint256 preview = arcUSDVault.previewDeposit(bob, amount);

        // ~ Bob deposits into Vault ~

        vm.startPrank(bob);
        arcUSDToken.approve(address(arcUSDVault), amount);
        arcUSDVault.deposit(amount, bob);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(bob), 0);
        assertEq(arcUSDToken.balanceOf(address(arcUSDVault)), amount);
        assertEq(arcUSDToken.balanceOf(address(arcUSDVault)), preview);
        assertEq(arcUSDVault.balanceOf(bob), amount);
    }

    function test_vault_deposit_NotEnabled() public {
        // ~ Config ~

        uint256 amount = 10 ether;
        vm.prank(address(arcMinter));
        arcUSDToken.mint(bob, amount);

        vm.prank(owner);
        arcUSDVault.setStakingEnabled(false);
        assertEq(arcUSDVault.stakingEnabled(), false);

        // bob cannot deposit when staking is disabled
        vm.startPrank(bob);
        arcUSDToken.approve(address(arcUSDVault), amount);
        vm.expectRevert(abi.encodeWithSelector(arcUSDPointsBoostVault.StakingDisabled.selector));
        arcUSDVault.deposit(amount, bob);
        vm.stopPrank();
    }

    function test_vault_deposit_fuzzing(uint256 amount, bool disableRebase) public {
        amount = bound(amount, 1, 1_000_000 ether);

        // ~ Config ~

        vm.prank(address(arcMinter));
        arcUSDToken.mint(bob, amount);

        if (disableRebase) {
            vm.prank(bob);
            arcUSDToken.disableRebase(bob, disableRebase);
        }

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(bob), amount);
        assertEq(arcUSDToken.balanceOf(address(arcUSDVault)), 0);
        assertEq(arcUSDVault.balanceOf(bob), 0);

        // ~ Bob deposits into Vault ~

        vm.startPrank(bob);
        arcUSDToken.approve(address(arcUSDVault), amount);
        arcUSDVault.deposit(amount, bob);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(bob), 0);
        assertEq(arcUSDToken.balanceOf(address(arcUSDVault)), amount);
        assertEq(arcUSDVault.balanceOf(bob), amount);
    }

    function test_vault_redeem() public {
        // ~ Config ~

        uint256 amount = 10 ether;
        deal(address(arcUSDVault), bob, amount);
        vm.prank(address(arcMinter));
        arcUSDToken.mint(address(arcUSDVault), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(bob), 0);
        assertEq(arcUSDToken.balanceOf(address(arcUSDVault)), amount);
        assertEq(arcUSDVault.balanceOf(bob), amount);

        uint256 preview = arcUSDVault.previewRedeem(bob, amount);

        // ~ Bob deposits into Vault ~

        vm.startPrank(bob);
        arcUSDVault.redeem(amount, bob);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(bob), amount);
        assertEq(arcUSDToken.balanceOf(bob), preview);
        assertEq(arcUSDToken.balanceOf(address(arcUSDVault)), 0);
        assertEq(arcUSDVault.balanceOf(bob), 0);
    }

    function test_vault_redeem_NotEnabled() public {
        // ~ Config ~

        uint256 amount = 10 ether;
        deal(address(arcUSDVault), bob, amount);
        vm.prank(address(arcMinter));
        arcUSDToken.mint(address(arcUSDVault), amount);

        vm.prank(owner);
        arcUSDVault.setStakingEnabled(false);
        assertEq(arcUSDVault.stakingEnabled(), false);

        // bob cannot unstake when staking is disabled
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(arcUSDPointsBoostVault.StakingDisabled.selector));
        arcUSDVault.redeem(amount, bob);
        vm.stopPrank();
    }

    function test_vault_redeem_fuzzing(uint256 amount, bool disableRebase) public {
        amount = bound(amount, 1, 1_000_000 ether);

        // ~ Config ~

        deal(address(arcUSDVault), bob, amount);
        vm.prank(address(arcMinter));
        arcUSDToken.mint(address(arcUSDVault), amount);

        if (disableRebase) {
            vm.prank(bob);
            arcUSDToken.disableRebase(bob, disableRebase);
        }

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(bob), 0);
        assertEq(arcUSDToken.balanceOf(address(arcUSDVault)), amount);
        assertEq(arcUSDVault.balanceOf(bob), amount);

        uint256 preview = arcUSDVault.previewRedeem(bob, amount);

        // ~ Bob deposits into Vault ~

        vm.startPrank(bob);
        arcUSDVault.redeem(amount, bob);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(bob), amount);
        assertEq(arcUSDToken.balanceOf(bob), preview);
        assertEq(arcUSDToken.balanceOf(address(arcUSDVault)), 0);
        assertEq(arcUSDVault.balanceOf(bob), 0);
    }

    function test_vault_redeem_postRebase_fuzzing(uint256 rebaseIndex) public {
        rebaseIndex = bound(rebaseIndex, 1.00001e18, 2e18);

        // ~ Config ~

        uint256 amount = 10 ether;
        deal(address(arcUSDVault), bob, amount);
        vm.prank(address(arcMinter));
        arcUSDToken.mint(address(arcUSDVault), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(bob), 0);
        assertEq(arcUSDToken.balanceOf(address(arcUSDVault)), amount);
        assertEq(arcUSDVault.balanceOf(bob), amount);

        // ~ set rebaseIndex ~

        vm.prank(arcUSDToken.rebaseManager());
        arcUSDToken.setRebaseIndex(rebaseIndex, 1);

        // ~ Bob deposits into Vault ~

        uint256 preview = arcUSDVault.previewRedeem(bob, amount);

        vm.startPrank(bob);
        arcUSDVault.redeem(amount, bob);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(bob), preview);
        assertApproxEqAbs(arcUSDToken.balanceOf(address(arcUSDVault)), 0, 2);
        assertEq(arcUSDVault.balanceOf(bob), 0);
    }
}
