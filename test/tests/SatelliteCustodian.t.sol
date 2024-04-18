// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

// oz imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// local files
import {BaseSetup} from "../BaseSetup.sol";
import {SatelliteCustodian} from "../../src/SatelliteCustodian.sol";

// helpers
import "../utils/Constants.sol";

/**
 * @title SatelliteCustodianTest
 * @notice Unit Tests for SatelliteCustodian contract interactions
 */
contract SatelliteCustodianTest is BaseSetup {
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");
    IERC20 public unrealUSTB = IERC20(UNREAL_USTB);

    function setUp() public override {
        vm.createSelectFork(UNREAL_RPC_URL);
        super.setUp();
    }

    /// @dev local deal to take into account unrealUSTB's unique storage layout
    function _deal(address token, address give, uint256 amount) internal {
        // deal doesn't work with unrealUSTB since the storage layout is different
        if (token == address(unrealUSTB)) {
            // if address is opted out, update normal balance (basket is opted out of rebasing)
            if (give == address(djUsdMinter)) {
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
        assertEq(address(custodian.djUsdMinter()), address(djUsdMinter));
        assertEq(custodian.dstChainId(), uint16(1));
        assertEq(custodian.gelato(), gelato);
        assertEq(custodian.dstCustodian(), mainCustodian);
    }

    function test_custodian_isUpgradeable() public {
        SatelliteCustodian newImplementation = new SatelliteCustodian(address(djUsdMinter), uint16(1));

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
        SatelliteCustodian newImplementation = new SatelliteCustodian(address(djUsdMinter), uint16(1));

        vm.prank(bob);
        vm.expectRevert();
        custodian.upgradeToAndCall(address(newImplementation), "");

        vm.prank(owner);
        custodian.upgradeToAndCall(address(newImplementation), "");
    }

    function test_custodian_withdrawFunds() public {
        // ~ Config ~

        uint256 amount = 1_000 * 1e18;

        vm.prank(address(djUsdMinter));
        djUsdToken.mint(address(custodian), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(address(custodian)), amount);
        assertEq(djUsdToken.balanceOf(owner), 0);

        // ~ Execute withdrawFunds ~

        vm.prank(owner);
        custodian.withdrawFunds(address(djUsdToken), amount);

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(address(custodian)), 0);
        assertEq(djUsdToken.balanceOf(owner), amount);
    }

    function test_custodian_withdrawFunds_USTB() public {
        // ~ Config ~

        uint256 amount = 1_000 * 1e18;
        _deal(address(unrealUSTB), address(custodian), amount);
        uint256 preBal = unrealUSTB.balanceOf(address(custodian));

        // ~ Pre-state check ~

        assertApproxEqAbs(unrealUSTB.balanceOf(address(custodian)), preBal, 1);
        assertEq(unrealUSTB.balanceOf(owner), 0);

        // ~ Execute withdrawFunds ~

        vm.prank(owner);
        custodian.withdrawFunds(address(unrealUSTB), amount);

        // ~ Post-state check ~

        assertEq(unrealUSTB.balanceOf(address(custodian)), preBal - amount);
        assertApproxEqAbs(unrealUSTB.balanceOf(owner), amount, 1);
    }

    function test_custodian_withdrawFunds_restrictions() public {
        // ~ Config ~

        uint256 amount = 1_000 * 1e18;
        vm.prank(address(djUsdMinter));
        djUsdToken.mint(address(custodian), amount);

        // only owner can call withdrawFunds
        vm.prank(bob);
        vm.expectRevert();
        custodian.withdrawFunds(address(djUsdToken), amount);

        // can't withdraw more than what is in contract's balance
        vm.prank(owner);
        vm.expectRevert();
        custodian.withdrawFunds(address(djUsdToken), amount + 1);
    }

    function test_custodian_bridgeFunds() public {
        // ~ Config ~

        uint256 amount = 1_000 * 1e18;
        vm.prank(address(djUsdMinter));
        djUsdToken.mint(address(custodian), amount);

        bytes memory adapterParams = abi.encodePacked(uint16(1), uint256(200000));

        (uint256 fee,) = djUsdToken.estimateSendFee(1, abi.encodePacked(mainCustodian), amount, false, adapterParams);

        vm.deal(address(owner), fee);

        vm.prank(owner);
        custodian.bridgeFunds{value: fee}(address(djUsdToken), owner, address(0), adapterParams);
    }

    function test_custodian_bridgeFunds_restrictions() public {}
}
