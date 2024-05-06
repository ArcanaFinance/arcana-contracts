// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

// oz imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// local files
import {BaseSetup} from "../BaseSetup.sol";
import {USDaFeeCollector} from "../../src/USDaFeeCollector.sol";

/**
 * @title USDaFeeCollectorTest
 * @notice Unit Tests for USDaFeeCollector contract interactions
 */
contract USDaFeeCollectorTest is BaseSetup {
    address public constant REVENUE_DISTRIBUTOR = address(bytes20(bytes("REVENUE_DISTRIBUTOR")));
    address public constant ARCANA_ESCROW = address(bytes20(bytes("ARCANA_ESCROW")));

    function setUp() public override {
        super.setUp();

        address[] memory distributors = new address[](2);
        distributors[0] = REVENUE_DISTRIBUTOR;
        distributors[1] = ARCANA_ESCROW;

        uint256[] memory ratios = new uint256[](2);
        ratios[0] = 1;
        ratios[1] = 1;

        vm.prank(owner);
        feeCollector.updateRewardDistribution(distributors, ratios);
    }

    function test_feeColector_init_state() public {
        assertEq(feeCollector.USDa(), address(usdaToken));
        assertEq(feeCollector.distributors(0), REVENUE_DISTRIBUTOR);
        assertEq(feeCollector.distributors(1), ARCANA_ESCROW);
    }

    function test_feeCollector_distributeUSDa() public {
        // ~ Config ~

        uint256 amount = 1 ether;
        vm.prank(address(usdaMinter));
        usdaToken.mint(address(feeCollector), amount);

        // ~ Pre-State check ~

        assertEq(usdaToken.balanceOf(address(feeCollector)), amount);
        assertEq(usdaToken.balanceOf(REVENUE_DISTRIBUTOR), 0);
        assertEq(usdaToken.balanceOf(ARCANA_ESCROW), 0);

        // ~ Execute distributeUSDa ~

        feeCollector.distributeUSDa();

        // ~ Pre-State check ~

        assertEq(usdaToken.balanceOf(address(feeCollector)), 0);
        assertEq(usdaToken.balanceOf(REVENUE_DISTRIBUTOR), amount / 2);
        assertEq(usdaToken.balanceOf(ARCANA_ESCROW), amount / 2);
    }

    function test_feeCollector_distributeUSDa_fuzzing(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);

        // ~ Config ~

        vm.prank(address(usdaMinter));
        usdaToken.mint(address(feeCollector), amount);

        // ~ Pre-State check ~

        assertEq(usdaToken.balanceOf(address(feeCollector)), amount);
        assertEq(usdaToken.balanceOf(REVENUE_DISTRIBUTOR), 0);
        assertEq(usdaToken.balanceOf(ARCANA_ESCROW), 0);

        // ~ Execute distributeUSDa ~

        feeCollector.distributeUSDa();

        // ~ Pre-State check ~

        assertApproxEqAbs(usdaToken.balanceOf(address(feeCollector)), 0, 1);
        assertEq(usdaToken.balanceOf(REVENUE_DISTRIBUTOR), amount / 2);
        assertEq(usdaToken.balanceOf(ARCANA_ESCROW), amount / 2);
    }
}
