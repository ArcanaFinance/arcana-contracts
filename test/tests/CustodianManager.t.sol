// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

// oz imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// local files
import {BaseSetup} from "../BaseSetup.sol";
import {CustodianManager} from "../../src/CustodianManager.sol";

// helpers
import "../utils/Constants.sol";

/**
 * @title SatelliteCustodianTest
 * @notice Unit Tests for CustodianManager contract interactions
 */
contract CustodianManagerTest is BaseSetup {
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");
    IERC20 public unrealUSTB = IERC20(UNREAL_USTB);

    function setUp() public override {
        vm.createSelectFork(UNREAL_RPC_URL);
        super.setUp();

        vm.startPrank(owner);
        arcMinter.removeSupportedAsset(address(USTB));
        arcMinter.removeSupportedAsset(address(USDCToken));
        arcMinter.removeSupportedAsset(address(USDTToken));

        arcMinter.addSupportedAsset(address(unrealUSTB), address(USTBOracle));
        vm.stopPrank();
    }

    /// @dev local deal to take into account unrealUSTB's unique storage layout
    function _deal(address token, address give, uint256 amount) internal {
        // deal doesn't work with unrealUSTB since the storage layout is different
        if (token == address(unrealUSTB)) {
            // if address is opted out, update normal balance (basket is opted out of rebasing)
            if (give == address(arcMinter)) {
                bytes32 USTBStorageLocation = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;
                uint256 mapSlot = 0;
                bytes32 slot = keccak256(abi.encode(give, uint256(USTBStorageLocation) + mapSlot));
                vm.store(address(unrealUSTB), slot, bytes32(amount));
            }
            // else, update shares balance
            else {
                bytes32 USTBStorageLocation = 0x8a0c9d8ec1d9f8b365393c36404b40a33f47675e34246a2e186fbefd5ecd3b00;
                uint256 mapSlot = 2;
                bytes32 slot = keccak256(abi.encode(give, uint256(USTBStorageLocation) + mapSlot));
                vm.store(address(unrealUSTB), slot, bytes32(amount));
            }
        }
        // If not rebase token, use normal deal
        else {
            deal(token, give, amount);
        }
    }

    function test_custodian_init_state() public {
        assertEq(address(custodian.arcMinter()), address(arcMinter));
        assertEq(custodian.custodian(), mainCustodian);
        assertEq(custodian.owner(), owner);
    }

    function test_custodian_isUpgradeable() public {
        CustodianManager newImplementation = new CustodianManager(address(arcMinter));

        bytes32 implementationSlot =
            vm.load(address(custodian), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertNotEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));

        vm.prank(owner);
        custodian.upgradeToAndCall(address(newImplementation), "");

        implementationSlot =
            vm.load(address(custodian), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));
    }

    function test_custodian_isUpgradeable_onlyOwner() public {
        CustodianManager newImplementation = new CustodianManager(address(arcMinter));

        vm.prank(bob);
        vm.expectRevert();
        custodian.upgradeToAndCall(address(newImplementation), "");

        vm.prank(owner);
        custodian.upgradeToAndCall(address(newImplementation), "");
    }

    function test_custodian_withdrawFunds() public {
        // ~ Config ~

        uint256 amount = 1_000 * 1e18;

        vm.prank(address(arcMinter));
        arcUSDToken.mint(address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(address(mainCustodian)), 0);
        assertEq(arcUSDToken.balanceOf(address(arcMinter)), amount);

        // ~ Execute withdrawFunds ~

        vm.prank(owner);
        custodian.withdrawFunds(address(arcUSDToken), 0);

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(address(mainCustodian)), amount);
        assertEq(arcUSDToken.balanceOf(address(arcMinter)), 0);
    }

    function test_custodian_withdrawFunds_minAmountOut() public {
        // ~ Config ~

        uint256 amount = 1_000 * 1e18;

        // bob goes to mint then request tokens
        vm.prank(address(arcMinter));
        arcUSDToken.mint(bob, amount);
        vm.startPrank(bob);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(unrealUSTB), amount);
        vm.stopPrank();
        assertEq(arcMinter.requiredTokens(address(unrealUSTB)), amount);

        _deal(address(unrealUSTB), address(arcMinter), arcMinter.requiredTokens(address(unrealUSTB)) + amount);
        //uint256 preBal = unrealUSTB.balanceOf(address(arcMinter));

        // ~ Pre-state check ~

        assertApproxEqAbs(unrealUSTB.balanceOf(address(mainCustodian)), 0, 1);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(arcMinter)), amount * 2, 1);
        assertApproxEqAbs(custodian.withdrawable(address(unrealUSTB)), amount, 1);

        // ~ Execute withdrawFunds ~

        // force revert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CustodianManager.MinAmountOutExceedsWithdrawable.selector, amount+1, amount));
        custodian.withdrawFunds(address(unrealUSTB), amount+1);

        vm.prank(owner);
        custodian.withdrawFunds(address(unrealUSTB), amount);

        // ~ Post-state check ~

        assertApproxEqAbs(unrealUSTB.balanceOf(address(mainCustodian)), amount, 1);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(arcMinter)), amount, 1);
        assertApproxEqAbs(custodian.withdrawable(address(unrealUSTB)), 0, 1);
    }

    function test_custodian_withdrawFunds_USTB() public {
        // ~ Config ~

        uint256 amount = 1_000 * 1e18;
        _deal(address(unrealUSTB), address(arcMinter), amount);
        uint256 preBal = unrealUSTB.balanceOf(address(arcMinter));

        // ~ Pre-state check ~

        assertEq(unrealUSTB.balanceOf(address(mainCustodian)), 0);
        assertEq(unrealUSTB.balanceOf(address(arcMinter)), preBal);

        // ~ Execute withdrawFunds ~

        vm.prank(owner);
        custodian.withdrawFunds(address(unrealUSTB), amount);

        // ~ Post-state check ~

        assertApproxEqAbs(unrealUSTB.balanceOf(address(mainCustodian)), preBal, 1);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(arcMinter)), 0, 1);
    }

    function test_custodian_withdrawFunds_restrictions() public {
        // ~ Config ~

        uint256 amount = 1_000 * 1e18;
        vm.prank(address(arcMinter));
        arcUSDToken.mint(address(custodian), amount);

        // only owner can call withdrawFunds
        vm.prank(bob);
        vm.expectRevert();
        custodian.withdrawFunds(address(arcUSDToken), amount);

        // can't withdraw more than what is in contract's balance
        vm.prank(owner);
        vm.expectRevert();
        custodian.withdrawFunds(address(arcUSDToken), amount + 1);
    }
}
