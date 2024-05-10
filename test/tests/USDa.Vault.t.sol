// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

// oz imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// local files
import {BaseSetup} from "../BaseSetup.sol";
import {USDaPointsBoostVault} from "../../src/USDaPointsBoostingVault.sol";

/**
 * @title USDaVaultTest
 * @notice Unit Tests for USDaPointsBoostVault contract interactions
 */
contract USDaVaultTest is BaseSetup {
    function setUp() public override {
        super.setUp();
    }

    function test_vault_init_state() public {
        assertEq(usdaVault.USDa(), address(usdaToken));
        assertEq(usdaVault.totalSupply(), type(uint256).max);
    }

    function test_vault_deposit() public {
        // ~ Config ~

        uint256 amount = 10 ether;
        vm.prank(address(usdaMinter));
        usdaToken.mint(bob, amount);

        // ~ Pre-state check ~

        assertEq(usdaToken.balanceOf(bob), amount);
        assertEq(usdaToken.balanceOf(address(usdaVault)), 0);
        assertEq(usdaVault.balanceOf(bob), 0);

        uint256 preview = usdaVault.previewDeposit(bob, amount);

        // ~ Bob deposits into Vault ~

        vm.startPrank(bob);
        usdaToken.approve(address(usdaVault), amount);
        usdaVault.deposit(amount, bob);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(usdaToken.balanceOf(bob), 0);
        assertEq(usdaToken.balanceOf(address(usdaVault)), amount);
        assertEq(usdaToken.balanceOf(address(usdaVault)), preview);
        assertEq(usdaVault.balanceOf(bob), amount);
    }

    function test_vault_deposit_NotEnabled() public {
        // ~ Config ~

        uint256 amount = 10 ether;
        vm.prank(address(usdaMinter));
        usdaToken.mint(bob, amount);

        vm.prank(owner);
        usdaVault.setStakingEnabled(false);
        assertEq(usdaVault.stakingEnabled(), false);

        // bob cannot deposit when staking is disabled
        vm.startPrank(bob);
        usdaToken.approve(address(usdaVault), amount);
        vm.expectRevert(abi.encodeWithSelector(USDaPointsBoostVault.StakingDisabled.selector));
        usdaVault.deposit(amount, bob);
        vm.stopPrank();
    }

    function test_vault_deposit_fuzzing(uint256 amount, bool disableRebase) public {
        amount = bound(amount, 1, 1_000_000 ether);

        // ~ Config ~

        vm.prank(address(usdaMinter));
        usdaToken.mint(bob, amount);

        if (disableRebase) {
            vm.prank(bob);
            usdaToken.disableRebase(bob, disableRebase);
        }

        // ~ Pre-state check ~

        assertEq(usdaToken.balanceOf(bob), amount);
        assertEq(usdaToken.balanceOf(address(usdaVault)), 0);
        assertEq(usdaVault.balanceOf(bob), 0);

        // ~ Bob deposits into Vault ~

        vm.startPrank(bob);
        usdaToken.approve(address(usdaVault), amount);
        usdaVault.deposit(amount, bob);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(usdaToken.balanceOf(bob), 0);
        assertEq(usdaToken.balanceOf(address(usdaVault)), amount);
        assertEq(usdaVault.balanceOf(bob), amount);
    }

    function test_vault_redeem() public {
        // ~ Config ~

        uint256 amount = 10 ether;
        deal(address(usdaVault), bob, amount);
        vm.prank(address(usdaMinter));
        usdaToken.mint(address(usdaVault), amount);

        // ~ Pre-state check ~

        assertEq(usdaToken.balanceOf(bob), 0);
        assertEq(usdaToken.balanceOf(address(usdaVault)), amount);
        assertEq(usdaVault.balanceOf(bob), amount);

        uint256 preview = usdaVault.previewRedeem(bob, amount);

        // ~ Bob deposits into Vault ~

        vm.startPrank(bob);
        usdaVault.redeem(amount, bob);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(usdaToken.balanceOf(bob), amount);
        assertEq(usdaToken.balanceOf(bob), preview);
        assertEq(usdaToken.balanceOf(address(usdaVault)), 0);
        assertEq(usdaVault.balanceOf(bob), 0);
    }

    function test_vault_redeem_NotEnabled() public {
        // ~ Config ~

        uint256 amount = 10 ether;
        deal(address(usdaVault), bob, amount);
        vm.prank(address(usdaMinter));
        usdaToken.mint(address(usdaVault), amount);

        vm.prank(owner);
        usdaVault.setStakingEnabled(false);
        assertEq(usdaVault.stakingEnabled(), false);

        // bob cannot unstake when staking is disabled
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(USDaPointsBoostVault.StakingDisabled.selector));
        usdaVault.redeem(amount, bob);
        vm.stopPrank();
    }

    function test_vault_redeem_fuzzing(uint256 amount, bool disableRebase) public {
        amount = bound(amount, 1, 1_000_000 ether);

        // ~ Config ~

        deal(address(usdaVault), bob, amount);
        vm.prank(address(usdaMinter));
        usdaToken.mint(address(usdaVault), amount);

        if (disableRebase) {
            vm.prank(bob);
            usdaToken.disableRebase(bob, disableRebase);
        }

        // ~ Pre-state check ~

        assertEq(usdaToken.balanceOf(bob), 0);
        assertEq(usdaToken.balanceOf(address(usdaVault)), amount);
        assertEq(usdaVault.balanceOf(bob), amount);

        uint256 preview = usdaVault.previewRedeem(bob, amount);

        // ~ Bob deposits into Vault ~

        vm.startPrank(bob);
        usdaVault.redeem(amount, bob);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(usdaToken.balanceOf(bob), amount);
        assertEq(usdaToken.balanceOf(bob), preview);
        assertEq(usdaToken.balanceOf(address(usdaVault)), 0);
        assertEq(usdaVault.balanceOf(bob), 0);
    }

    function test_vault_redeem_postRebase_fuzzing(uint256 rebaseIndex) public {
        rebaseIndex = bound(rebaseIndex, 1.00001e18, 2e18);

        // ~ Config ~

        uint256 amount = 10 ether;
        deal(address(usdaVault), bob, amount);
        vm.prank(address(usdaMinter));
        usdaToken.mint(address(usdaVault), amount);

        // ~ Pre-state check ~

        assertEq(usdaToken.balanceOf(bob), 0);
        assertEq(usdaToken.balanceOf(address(usdaVault)), amount);
        assertEq(usdaVault.balanceOf(bob), amount);

        // ~ set rebaseIndex ~

        vm.prank(usdaToken.rebaseManager());
        usdaToken.setRebaseIndex(rebaseIndex, 1);

        // ~ Bob deposits into Vault ~

        uint256 preview = usdaVault.previewRedeem(bob, amount);

        vm.startPrank(bob);
        usdaVault.redeem(amount, bob);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(usdaToken.balanceOf(bob), preview);
        assertApproxEqAbs(usdaToken.balanceOf(address(usdaVault)), 0, 2);
        assertEq(usdaVault.balanceOf(bob), 0);
    }
}
