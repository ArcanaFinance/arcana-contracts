// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

// oz imports
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// local files
import { BaseSetup } from "../BaseSetup.sol";
import { DJUSDPointsBoostVault } from "../../src/DJUSDPointsBoostingVault.sol";

/**
 * @title DJUSDVaultTest
 * @notice Unit Tests for DJUSDMinting contract interactions
 */
contract DJUSDVaultTest is BaseSetup {

    function setUp() public override {
        super.setUp();
    }

    function test_vault_init_state() public {
        assertEq(djUsdVault.DJUSD(), address(djUsdToken));
    }

    function test_vault_deposit() public {

        // ~ Config ~

        uint256 amount = 10 ether;
        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(bob, amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(bob), amount);
        assertEq(djUsdToken.balanceOf(address(djUsdVault)), 0);
        assertEq(djUsdVault.balanceOf(bob), 0);
        assertEq(djUsdVault.totalSupply(), 0);

        // ~ Bob deposits into Vault ~

        vm.startPrank(bob);
        djUsdToken.approve(address(djUsdVault), amount);
        djUsdVault.deposit(amount, bob);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(bob), 0);
        assertEq(djUsdToken.balanceOf(address(djUsdVault)), amount);
        assertEq(djUsdVault.balanceOf(bob), amount);
        assertEq(djUsdVault.totalSupply(), amount);
    }

    function test_vault_deposit_fuzzing(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);

        // ~ Config ~

        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(bob, amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(bob), amount);
        assertEq(djUsdToken.balanceOf(address(djUsdVault)), 0);
        assertEq(djUsdVault.balanceOf(bob), 0);
        assertEq(djUsdVault.totalSupply(), 0);

        // ~ Bob deposits into Vault ~

        vm.startPrank(bob);
        djUsdToken.approve(address(djUsdVault), amount);
        djUsdVault.deposit(amount, bob);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(bob), 0);
        assertEq(djUsdToken.balanceOf(address(djUsdVault)), amount);
        assertEq(djUsdVault.balanceOf(bob), amount);
        assertEq(djUsdVault.totalSupply(), amount);
    }

    function test_vault_redeem() public {

        // ~ Config ~

        uint256 amount = 10 ether;
        deal(address(djUsdVault), bob, amount);
        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(address(djUsdVault), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(bob), 0);
        assertEq(djUsdToken.balanceOf(address(djUsdVault)), amount);
        assertEq(djUsdVault.balanceOf(bob), amount);

        uint256 preview = djUsdVault.previewRedeem(bob, amount);

        // ~ Bob deposits into Vault ~

        vm.startPrank(bob);
        djUsdVault.approve(address(djUsdVault), amount);
        djUsdVault.redeem(amount, bob);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(bob), amount);
        assertEq(djUsdToken.balanceOf(bob), preview);
        assertEq(djUsdToken.balanceOf(address(djUsdVault)), 0);
        assertEq(djUsdVault.balanceOf(bob), 0);
    }

    function test_vault_redeem_fuzzing(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);

        // ~ Config ~

        deal(address(djUsdVault), bob, amount);
        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(address(djUsdVault), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(bob), 0);
        assertEq(djUsdToken.balanceOf(address(djUsdVault)), amount);
        assertEq(djUsdVault.balanceOf(bob), amount);

        uint256 preview = djUsdVault.previewRedeem(bob, amount);

        // ~ Bob deposits into Vault ~

        vm.startPrank(bob);
        djUsdVault.approve(address(djUsdVault), amount);
        djUsdVault.redeem(amount, bob);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(bob), amount);
        assertEq(djUsdToken.balanceOf(bob), preview);
        assertEq(djUsdToken.balanceOf(address(djUsdVault)), 0);
        assertEq(djUsdVault.balanceOf(bob), 0);
    }

    function test_vault_redeem_postRebase_fuzzing(uint256 rebaseIndex) public {
        rebaseIndex = bound(rebaseIndex, 1.00001e18, 2e18);

        // ~ Config ~

        uint256 amount = 10 ether;
        deal(address(djUsdVault), bob, amount);
        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(address(djUsdVault), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(bob), 0);
        assertEq(djUsdToken.balanceOf(address(djUsdVault)), amount);
        assertEq(djUsdVault.balanceOf(bob), amount);

        // ~ set rebaseIndex ~

        vm.prank(djUsdToken.rebaseManager());
        djUsdToken.setRebaseIndex(rebaseIndex, 1);

        // ~ Bob deposits into Vault ~

        uint256 preview = djUsdVault.previewRedeem(bob, amount);

        vm.startPrank(bob);
        djUsdVault.approve(address(djUsdVault), amount);
        djUsdVault.redeem(amount, bob);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(bob), preview);
        assertApproxEqAbs(djUsdToken.balanceOf(address(djUsdVault)), 0, 2);
        assertEq(djUsdVault.balanceOf(bob), 0);
    }
}